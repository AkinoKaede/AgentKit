import Foundation

/// One redaction policy for model review, live approval/tool cards, and durable
/// history. Fetch headers use `{name,value}`, so key-only redaction is not
/// enough: the header name determines whether its sibling value is sensitive.
public nonisolated enum AgentSensitiveDataRedactor {
    private static let sensitiveKeys = [
        "password", "passwd", "secret", "token", "authorization", "cookie", "api_key",
        "api-key", "apikey",
    ]

    public static func visibleText(_ text: String, maximumCharacters: Int? = nil) -> String {
        var output = maximumCharacters.map { String(text.prefix($0)) } ?? text
        for key in sensitiveKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            // A streaming snapshot may end inside a quoted value. Redact the
            // entire unfinished value, including whitespace and escaped quotes.
            let pattern =
                "(?i)(\\\"?\(escaped)\\\"?\\s*[:=]\\s*)"
                + #"(\"(?:\\.|[^\"\\])*(?:\"|$)|'(?:\\.|[^'\\])*(?:'|$)|[^\s,}]+)"#
            output = output.replacingOccurrences(
                of: pattern, with: "$1\"[REDACTED]\"", options: .regularExpression
            )
        }
        return output
    }

    public static func redactedJSON(_ value: AgentJSONValue) -> AgentJSONValue {
        switch value {
        case .object(let object):
            let headerIsSensitive = object["name"]?.stringValue.map(isSensitiveHeader) == true
            return .object(
                object.reduce(into: [:]) { output, pair in
                    if isSensitiveKey(pair.key) || headerIsSensitive && pair.key == "value" {
                        // Provider strict-mode arguments spell an omitted
                        // optional field as `null`. Turning that absence into a
                        // string creates a value that never existed — especially
                        // dangerous for one-shot handles, because a later turn
                        // can copy "[REDACTED]" back into the tool as if it were
                        // a credential. Preserve absence (and the harmless empty
                        // string); redact only a value that actually carries
                        // something.
                        switch pair.value {
                        case .null, .string(""):
                            output[pair.key] = pair.value
                        default:
                            output[pair.key] = .string("[REDACTED]")
                        }
                    } else {
                        output[pair.key] = redactedJSON(pair.value)
                    }
                })
        case .array(let array): return .array(array.map(redactedJSON))
        case .string(let string): return .string(visibleText(string))
        default: return value
        }
    }

    /// Redacts decoded fields before encoding, preserving valid JSON and its framing.
    /// Malformed or plain text retains the existing visible-text fallback.
    public static func toolResultText(_ text: String, isUntrusted: Bool = true) -> String {
        let redacted = redactedToolPayload(text, isUntrusted: isUntrusted)
        return redacted.value == nil ? visibleText(text) : redacted.text
    }

    /// Shares the decoded value with projection so it need not parse the redacted JSON again.
    static func redactedToolPayload(
        _ text: String, isUntrusted: Bool
    ) -> (text: String, payload: String, value: AgentJSONValue?) {
        let result = AgentToolResult(callID: "", content: text, metadata: ["untrusted": .bool(isUntrusted)])
        let untrustedPayload = result.untrustedPayload
        let value = AgentToolResult.decodeStructuredPayload(
            untrustedPayload ?? text, isUntrusted: false
        ).map(redactedJSON)
        let payload = value?.encodedString ?? visibleText(untrustedPayload ?? text)
        let framed =
            untrustedPayload == nil
            ? payload
            : AgentToolResult.untrustedDataOpeningMarker + payload + AgentToolResult.untrustedDataClosingMarker
        return (framed, payload, value)
    }

    public static func isSensitiveHeader(_ name: String) -> Bool {
        isSensitiveKey(name.replacingOccurrences(of: "-", with: "_"))
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return sensitiveKeys.contains { lowered.contains($0) }
    }
}

/// Removes unavailable capabilities from replayed history without expiring
/// handles that the caller's broker still owns. Durable storage preserves none.
public nonisolated enum AgentSecretLifecycle {
    /// The argument a consuming tool takes a handle in.
    ///
    /// One name, shared, because history is sanitized without knowing which
    /// tools an app registered.
    public static let handleArgumentKey = "secret_handle"

    public static let expiredResultContent =
        AgentToolResult.untrustedDataOpeningMarker
        + AgentJSONValue.object([
            "handle_status": .string("expired"),
            "single_use": .bool(true),
        ]).encodedString
        + AgentToolResult.untrustedDataClosingMarker

    public static func sanitizeHistoricalMessages(
        _ messages: [AgentTranscriptMessage],
        availableHandles: Set<UUID> = []
    ) -> [AgentTranscriptMessage] {
        let secretRequestCallIDs = Set(
            messages.flatMap(\.toolCalls).compactMap { call in
                call.name == "request_user_secret" ? call.id : nil
            })

        return messages.map { original in
            var message = original
            if message.role == .assistant {
                message.toolCalls = message.toolCalls.map { originalCall in
                    guard var arguments = originalCall.arguments.objectValue,
                        arguments[handleArgumentKey] != nil,
                        !isAvailable(arguments[handleArgumentKey], in: availableHandles)
                    else { return originalCall }
                    arguments.removeValue(forKey: handleArgumentKey)
                    var call = originalCall
                    call.arguments = .object(arguments)
                    return call
                }
            }
            if message.role == .tool,
                message.toolName == "request_user_secret"
                    || message.toolCallID.map(secretRequestCallIDs.contains) == true
            {
                let value = AgentToolResult.decodeStructuredPayload(message.text)
                if !isAvailable(value?.objectValue?[handleArgumentKey], in: availableHandles) {
                    message.text = expiredResultContent
                    message.modelText = nil
                }
            }
            return message
        }
    }

    public static func persistedResultText(toolName: String?, original: String) -> String {
        toolName == "request_user_secret" ? expiredResultContent : original
    }

    private static func isAvailable(_ value: AgentJSONValue?, in handles: Set<UUID>) -> Bool {
        guard let raw = value?.stringValue, let id = UUID(uuidString: raw) else { return false }
        return handles.contains(id)
    }
}
