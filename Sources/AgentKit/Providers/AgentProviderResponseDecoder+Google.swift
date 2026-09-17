import Foundation

nonisolated extension AgentProviderResponseDecoder {
    static func parseGoogle(
        _ root: [String: Any], wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        // Read before the `candidates` guard for the same reason as Chat
        // Completions: Gemini repeats `usageMetadata` on chunks that carry no
        // candidate at all, and those are frequently the last ones.
        var events: [AgentModelStreamEvent] = googleUsage(root).map { [$0] } ?? []
        guard let candidate = (root["candidates"] as? [[String: Any]])?.first else { return events }
        // Grounding hangs off the candidate, beside `content`, not inside
        // `parts` — and it is read before the guard below, because a chunk can
        // carry the metadata for a search without carrying any content.
        if let grounding = candidate["groundingMetadata"] as? [String: Any] {
            events.append(.webSearch(googleGrounding(grounding)))
        }
        guard let content = candidate["content"] as? [String: Any] else {
            if candidate["finishReason"] != nil { events.append(.finished(.completed)) }
            return events
        }
        for part in content["parts"] as? [[String: Any]] ?? [] {
            if part["thought"] as? Bool == true {
                if let text = part["text"] as? String, !text.isEmpty {
                    events.append(.reasoningDelta(text))
                }
                if part["thoughtSignature"] != nil, let value = jsonValue(part) {
                    events.append(.providerItem(value))
                }
                continue
            }
            if let text = part["text"] as? String { events.append(.textDelta(text)) }
            if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                let args = call["args"].flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
                events.append(
                    .toolCallSnapshot(
                        id: UUID().uuidString,
                        providerItemID: part["thoughtSignature"] as? String,
                        name: canonicalName(name, wireNames: wireNames),
                        arguments: String(decoding: args, as: UTF8.self)
                    ))
            }
        }
        if candidate["finishReason"] != nil {
            events.append(.finished(events.containsToolCall ? .toolCalls : .completed))
        }
        return events
    }

    /// Gemini reports every query of the turn in one `webSearchQueries` array
    /// and its sources in `groundingChunks`, with no mapping between them. The
    /// queries are joined rather than split into a card each, because inventing
    /// a source-to-query assignment the payload does not state would be worse
    /// than showing them together.
    private static func googleGrounding(
        _ metadata: [String: Any]
    ) -> AgentWebSearchActivity {
        let queries = (metadata["webSearchQueries"] as? [String] ?? [])
            .filter { !$0.isEmpty }
        let sources = (metadata["groundingChunks"] as? [[String: Any]] ?? []).compactMap {
            chunk -> AgentWebSearchActivity.Source? in
            guard let web = chunk["web"] as? [String: Any],
                let url = web["uri"] as? String, !url.isEmpty
            else { return nil }
            return AgentWebSearchActivity.Source(
                title: web["title"] as? String ?? "", url: url
            )
        }
        return AgentWebSearchActivity(
            query: queries.joined(separator: ", "), sources: sources
        )
    }

    private static func googleUsage(_ root: [String: Any]) -> AgentModelStreamEvent? {
        guard let usage = root["usageMetadata"] as? [String: Any] else { return nil }
        return .usage(
            AgentTokenUsage(
                inputTokens: count(usage["promptTokenCount"]),
                outputTokens: count(usage["candidatesTokenCount"]),
                cachedInputTokens: count(usage["cachedContentTokenCount"])
            ))
    }
}
