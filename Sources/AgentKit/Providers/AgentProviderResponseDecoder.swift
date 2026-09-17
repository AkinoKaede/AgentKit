import Foundation

/// Stateless provider wire adapters shared by live and buffered response parsing.
/// Mutable call/block identity stays in AgentProviderResponseParser, never here.
nonisolated enum AgentProviderResponseDecoder {
    static func streamEventType(_ event: SSEEvent, root: [String: Any]) -> String {
        event.event == "message" ? root["type"] as? String ?? event.event : event.event
    }

    static func jsonValue(_ object: Any) -> AgentJSONValue? {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? AgentJSONValue.decode(data)
    }

    static func canonicalName(
        _ wireName: String, wireNames: [String: String]
    ) -> String {
        wireNames[wireName] ?? wireName
    }

    /// Both OpenAI formats report a prompt total that already includes cache
    /// reads and writes. Only the token field names differ between formats.
    static func openAIUsage(
        _ root: [String: Any], inputKey: String, outputKey: String
    ) -> AgentModelStreamEvent? {
        guard let usage = root["usage"] as? [String: Any] else { return nil }
        let details = usage[inputKey + "_details"] as? [String: Any]
        return .usage(
            AgentTokenUsage(
                inputTokens: count(usage[inputKey]),
                outputTokens: count(usage[outputKey]),
                cachedInputTokens: count(details?["cached_tokens"]),
                cacheWriteInputTokens: count(details?["cache_write_tokens"])
            ))
    }

    /// `JSONSerialization` hands back `NSNumber` for every JSON number, and a
    /// gateway is free to send `1024.0`. Reading these as `Int` directly works
    /// often enough to look correct and then silently returns nil.
    static func count(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}

nonisolated extension Array where Element == AgentModelStreamEvent {
    var containsToolCall: Bool {
        contains {
            switch $0 {
            case .toolCallDelta, .toolCallSnapshot: true
            default: false
            }
        }
    }
}
