import Foundation

/// Freezes one model representation. Raw results and external-client responses are untouched.
public nonisolated struct AgentToolOutputProjection: Sendable {
    public var workspace: AgentScratchWorkspace
    public var maximumBytes: Int
    public var maximumLines: Int
    public var audience: AgentOutputAudience

    public init(
        workspace: AgentScratchWorkspace = .shared(),
        maximumBytes: Int = AgentTruncateLimits.maximumBytes,
        maximumLines: Int = AgentTruncateLimits.maximumLines,
        audience: AgentOutputAudience = .model
    ) {
        self.workspace = workspace
        self.maximumBytes = max(1, maximumBytes)
        self.maximumLines = max(1, maximumLines)
        self.audience = audience
    }

    public func project(
        _ result: AgentToolResult, invocation: AgentToolInvocation, strategy: AgentTruncateStrategy = .head
    ) async -> AgentToolResult {
        guard audience == .model, result.modelContent == nil,
            invocation.call.name != "request_user_secret", !result.isProviderNative
        else { return result }
        var projected = result
        let redacted = AgentSensitiveDataRedactor.redactedToolPayload(
            result.content, isUntrusted: result.metadata["untrusted"]?.boolValue == true)
        let clean = redacted.text
        let object = redacted.value?.objectValue
        // A malformed source may become valid JSON after visible-text redaction.
        // Retain its historical archive rendering, without reparsing valid inputs.
        let archiveValue =
            redacted.value
            ?? AgentToolResult.decodeStructuredPayload(redacted.payload, isUntrusted: false)
        let readable =
            object?["output"]?.stringValue ?? archiveValue.map(AgentToolResult.archiveText)
            ?? redacted.payload
        let limits = AgentTruncateLimits(bytes: maximumBytes, lines: maximumLines)
        if strategy == .none || result.metadata["skill_instructions"]?.boolValue == true {
            projected.modelContent = clean
            return projected
        }
        if result.hasBoundedModelContent, let object,
            object["offset"]?.integerValue != nil, object["content"]?.stringValue != nil
        {
            return projectPage(result, object: object)
        }
        if result.hasBoundedModelContent, let object,
            object["message_offset"]?.integerValue != nil, object["messages"]?.arrayValue != nil
        {
            return projectMessagePage(result, object: object)
        }
        let initial = AgentTruncateResult.apply(readable, strategy: strategy, limits: limits)
        // Trusted installed instructions retain their separate import/validation contract.
        if !initial.isTruncated && !result.isTruncated && clean.utf8.count <= maximumBytes
            && result.outputCapture == nil
        {
            projected.modelContent = clean
            return projected
        }

        let capture = result.outputCapture
        projected.outputCapture = capture
        let totalLines =
            result.metadata["output_total_lines"]?.integerValue ?? (result.isTruncated ? nil : initial.totalLines)
        let lineOffset = result.metadata["output_line_offset"]?.integerValue ?? 0
        var fields: [String: AgentJSONValue] = [
            "is_error": .bool(result.isError),
            "source_bytes": .number(Double(initial.totalBytes)),
            "source_truncated": .bool(result.isTruncated),
            "capture_status": .string(
                capture == nil ? "not_requested" : capture?.error == nil && capture?.path != nil ? "saved" : "failed"),
        ]
        for key in [
            "handle", "host_id", "status", "exit_code", "signal", "error", "stdin_closed", "next_offset", "offset",
            "eof", "path",
        ] {
            if let value = object?[key] { fields[key] = value }
        }
        if let path = capture?.path, capture?.error == nil {
            fields["captured_bytes"] = .number(Double(capture?.bytes ?? 0))
            fields["captured_output_path"] = .string(path)
            fields["captured_local_path"] = capture?.localPath.map(AgentJSONValue.string)
            fields["continuation"] = .string(
                "Use scratch_read(path: \"\(path)\", offset: 1) or scratch_search with this path.")
        }
        if let error = capture?.error {
            fields["capture_error"] = .string(error)
        }
        if result.isTruncated, result.outputCapture == nil {
            fields["source_notice"] = .string("The source was already limited. Use its continuation to read more.")
        }
        let bodyKey = object?["output"] == nil ? "preview" : "output"
        var budget = maximumBytes
        var selected = initial
        var text = ""
        // Account for JSON escaping and the footer, dropping whole lines rather
        // than slicing the serialized result into invalid JSON.
        repeat {
            selected = AgentTruncateResult.apply(
                readable, strategy: strategy,
                limits: .init(bytes: budget, lines: maximumLines))
            fields[bodyKey] = .string(selected.content)
            fields["returned_lines"] = .number(Double(selected.returnedLines))
            fields["total_lines"] = totalLines.map { .number(Double($0)) }
            fields["oversized_line"] = .bool(selected.oversizedLine)
            projected.truncateMarker = AgentTruncateMarker.render(
                ranges: selected.ranges.map { ($0.lowerBound + lineOffset)...($0.upperBound + lineOffset) },
                totalLines: totalLines, capture: capture)
            fields["notice"] = projected.truncateMarker.map(AgentJSONValue.string)
            text = Self.frame(fields)
            guard text.utf8.count > maximumBytes, budget > 0 else { break }
            budget = smallerBudget(budget, encodedBytes: text.utf8.count)
        } while true
        // A tiny custom budget cannot fit an envelope. Never slice a saved path.
        if text.utf8.count > maximumBytes {
            let notice = projected.truncateMarker ?? ""
            text = notice.utf8.count <= maximumBytes ? notice : ""
        }
        projected.metadata["output_truncated"] = .bool(true)
        projected.metadata["truncate_strategy"] = .string(strategy.rawValue)
        projected.modelContent = text
        return projected
    }

    /// A page's continuation must describe the lines actually returned, not the
    /// larger source window before JSON escaping and envelope costs were counted.
    private func projectPage(_ result: AgentToolResult, object: [String: AgentJSONValue]) -> AgentToolResult {
        var fields = object
        let offset = fields["offset"]!.integerValue!
        let content = fields["content"]!.stringValue!
        let count = fields["returned_lines"]?.integerValue ?? content.components(separatedBy: "\n").count
        let pageText = count == 0 ? "" : content + "\n"
        var budget = maximumBytes
        var selected: AgentTruncateResult
        var encoded: String
        repeat {
            selected = AgentTruncateResult.apply(
                pageText, limits: .init(bytes: budget, lines: maximumLines))
            fields["content"] = .string(
                selected.content.hasSuffix("\n") ? String(selected.content.dropLast()) : selected.content)
            fields["returned_lines"] = .number(Double(selected.returnedLines))
            fields["capture_status"] = .string("not_requested")
            if selected.isTruncated {
                fields["truncated"] = .bool(true)
                fields["next_offset"] = .number(Double(offset + selected.returnedLines))
                if fields["eof"] != nil { fields["eof"] = .bool(false) }
            }
            if let next = fields["next_offset"]?.integerValue {
                fields["notice"] = .string(
                    AgentTruncateMarker.render(
                        ranges: selected.ranges.map { ($0.lowerBound + offset - 1)...($0.upperBound + offset - 1) },
                        totalLines: fields["total_lines"]?.integerValue))
                if selected.returnedLines == 0 {
                    fields["continuation"] = .string(
                        "Line \(offset) exceeds the response limit. Use a file transfer to retrieve it; offset \(offset + 1) skips this line."
                    )
                } else {
                    fields["continuation"] = .string("Continue with offset \(next).")
                }
            }
            encoded = Self.frame(fields)
            guard encoded.utf8.count > maximumBytes, budget > 0 else { break }
            budget = smallerBudget(budget, encodedBytes: encoded.utf8.count)
        } while true
        var projected = result
        let fallback = AgentTruncateMarker.render(ranges: [], totalLines: fields["total_lines"]?.integerValue)
        projected.modelContent =
            encoded.utf8.count <= maximumBytes ? encoded : fallback.utf8.count <= maximumBytes ? fallback : ""
        projected.truncateMarker = fields["notice"]?.stringValue
        if selected.isTruncated { projected.metadata["output_truncated"] = .bool(true) }
        return projected
    }

    static func frame(_ fields: [String: AgentJSONValue]) -> String {
        AgentToolResult.untrustedDataOpeningMarker + AgentJSONValue.object(fields).encodedString
            + AgentToolResult.untrustedDataClosingMarker
    }

    /// Escaping can multiply byte cost. Subtracting the encoded overage from the
    /// raw budget may jump straight to zero even when many complete lines fit.
    func smallerBudget(_ budget: Int, encodedBytes: Int) -> Int {
        max(0, min(budget - 1, Int(Double(budget) * Double(maximumBytes) / Double(encodedBytes))))
    }
}
