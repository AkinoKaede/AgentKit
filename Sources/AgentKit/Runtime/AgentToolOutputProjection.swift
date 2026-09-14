import Foundation

/// Produces a tool result's model representation once, before toolFinished is emitted.
/// The ordinary content remains available to the host's presentation and storage.
public nonisolated struct AgentToolOutputProjection: Sendable {
    public var workspace: AgentScratchWorkspace?
    public var maximumBytes: Int
    public var maximumLines: Int

    public init(
        workspace: AgentScratchWorkspace? = nil,
        maximumBytes: Int = AgentTextPageReader.defaultMaximumBytes,
        maximumLines: Int = AgentTextPageReader.defaultLineLimit
    ) {
        self.workspace = workspace
        self.maximumBytes = max(1, maximumBytes)
        self.maximumLines = max(2, maximumLines)
    }

    public func project(_ result: AgentToolResult, invocation: AgentToolInvocation) async -> AgentToolResult {
        // Secret handles are deliberately live-only; historical replay sanitizes them.
        guard invocation.call.name != "request_user_secret", !result.isProviderNative else { return result }
        var projected = result
        let clean = AgentSensitiveDataRedactor.visibleText(result.content)
        if invocation.call.name == LoadSkillTool.name || result.hasBoundedModelContent || !exceedsLimit(clean) {
            projected.modelContent = clean
            return projected
        }

        let payload = result.untrustedPayload.map { AgentSensitiveDataRedactor.visibleText($0) } ?? clean
        let readable = Self.archiveText(payload)
        var fields: [String: AgentJSONValue] = [
            "is_error": .bool(result.isError),
            "preview": .string(Self.preview(readable, maximumBytes: maximumBytes, maximumLines: maximumLines)),
            "captured_bytes": .number(Double(payload.utf8.count)),
            "source_truncated": .bool(result.isTruncated),
        ]
        let object = (try? AgentJSONValue.decode(Data(payload.utf8)))?.objectValue
        for key in ["exit_code", "signal", "status", "stdout_truncated", "stderr_truncated"] {
            if let value = object?[key] { fields[key] = value }
        }
        if let workspace {
            do {
                // Names are local invocation identities, never remote-chosen paths.
                let path = "tool-output-\(invocation.id.uuidString).txt"
                let archive = readable
                _ = try await workspace.write(path, data: Data(archive.utf8))
                fields["captured_output_path"] = .string(path)
                fields["notice"] = .string(
                    "The preview is shortened. Use scratch_read or scratch_search on captured_output_path for the captured result."
                )
            } catch {
                fields["notice"] = .string(
                    "The preview is shortened. Saving the captured output failed; no complete copy is available.")
            }
        } else {
            fields["notice"] = .string(
                "The preview is shortened. No scratch workspace is available to save the captured output.")
        }
        if result.isTruncated {
            fields["source_notice"] = .string(
                "The source already truncated this result; omitted source data is not in the saved capture.")
        }
        let text = AgentJSONValue.object(fields).encodedString
        projected.modelContent =
            AgentToolResult.untrustedDataOpeningMarker + text + AgentToolResult.untrustedDataClosingMarker
        return projected
    }

    private func exceedsLimit(_ text: String) -> Bool {
        text.utf8.count > maximumBytes
            || text.split(separator: "\n", omittingEmptySubsequences: false).count > maximumLines
    }

    private static func preview(_ text: String, maximumBytes: Int, maximumLines: Int) -> String {
        let marker = "[… omitted …]"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lineBudget = max(0, maximumLines - 3)
        let lineBounded =
            lines.count > max(1, lineBudget)
            ? (lines.prefix(lineBudget / 2).map(String.init) + [marker]
                + lines.suffix(lineBudget - lineBudget / 2).map(String.init)).joined(separator: "\n") : text
        guard lineBounded.utf8.count > maximumBytes else { return lineBounded }
        let separator = "\n" + marker + "\n"
        let byteBudget = max(0, maximumBytes - separator.utf8.count)
        if byteBudget == 0 { return String("...".prefix(maximumBytes)) }
        let bytes = Data(lineBounded.utf8)
        var head = Data(bytes.prefix(byteBudget / 2))
        var tail = Data(bytes.suffix(byteBudget - byteBudget / 2))
        while String(data: head, encoding: .utf8) == nil { head.removeLast() }
        while String(data: tail, encoding: .utf8) == nil { tail.removeFirst() }
        return String(decoding: head, as: UTF8.self) + separator + String(decoding: tail, as: UTF8.self)
    }

    /// Expand JSON string fields into actual lines so captured stdout can be paged.
    private static func archiveText(_ payload: String) -> String {
        guard let value = try? AgentJSONValue.decode(Data(payload.utf8)) else { return payload }
        func render(_ value: AgentJSONValue) -> String {
            switch value {
            case .string(let text): return text
            case .object(let fields):
                return fields.keys.sorted().map { "\($0):\n\(render(fields[$0]!))" }.joined(separator: "\n\n")
            case .array(let values):
                return values.enumerated().map { "[\($0.offset)]\n\(render($0.element))" }.joined(separator: "\n\n")
            default: return value.encodedString
            }
        }
        return render(value)
    }
}
