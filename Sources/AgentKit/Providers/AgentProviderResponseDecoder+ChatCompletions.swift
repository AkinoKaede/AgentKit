import Foundation

nonisolated extension AgentProviderResponseDecoder {
    static func parseChat(
        _ root: [String: Any], wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        var callIDs: [Int: String] = [:]
        return parseChat(root, callIDs: &callIDs, wireNames: wireNames)
    }

    static func parseChat(
        _ root: [String: Any], callIDs: inout [Int: String],
        wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        // Before the `choices` guard, not after it. With `stream_options`
        // requested, OpenAI sends usage on a final chunk whose `choices` is an
        // empty array — the one chunk that carries the number would otherwise be
        // the one chunk this parser drops on the floor.
        var events: [AgentModelStreamEvent] =
            openAIUsage(root, inputKey: "prompt_tokens", outputKey: "completion_tokens").map { [$0] } ?? []
        guard let choice = (root["choices"] as? [[String: Any]])?.first else { return events }
        if let message = choice["message"] as? [String: Any] {
            if let text = message["content"] as? String { events.append(.textDelta(text)) }
            for (index, call) in (message["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                let function = call["function"] as? [String: Any]
                guard let name = function?["name"] as? String else { continue }
                events.append(
                    .toolCallDelta(
                        id: call["id"] as? String ?? "index-\(index)",
                        name: canonicalName(name, wireNames: wireNames),
                        arguments: function?["arguments"] as? String ?? ""
                    ))
            }
        }
        if let delta = choice["delta"] as? [String: Any] {
            if let text = delta["content"] as? String { events.append(.textDelta(text)) }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = call["index"] as? Int ?? 0
                if let id = call["id"] as? String { callIDs[index] = id }
                let function = call["function"] as? [String: Any]
                events.append(
                    .toolCallDelta(
                        id: callIDs[index] ?? "index-\(index)",
                        name: (function?["name"] as? String).map {
                            canonicalName($0, wireNames: wireNames)
                        },
                        arguments: function?["arguments"] as? String ?? ""
                    ))
            }
        }
        if let reason = choice["finish_reason"] as? String {
            events.append(.finished(reason == "length" ? .length : reason == "tool_calls" ? .toolCalls : .completed))
        } else if choice["message"] != nil {
            events.append(.finished(events.containsToolCall ? .toolCalls : .completed))
        }
        return events
    }
}
