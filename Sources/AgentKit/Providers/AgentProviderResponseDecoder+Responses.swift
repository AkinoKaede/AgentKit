import Foundation

nonisolated extension AgentProviderResponseDecoder {
    private static func responseName(_ object: [String: Any]) -> String? {
        guard let name = object["name"] as? String else { return nil }
        guard let namespace = object["namespace"] as? String, !namespace.isEmpty else {
            return name
        }
        return "\(namespace).\(name)"
    }

    private static func responsesReasoningSummary(_ item: [String: Any]) -> String? {
        let parts = item["summary"] as? [[String: Any]] ?? []
        let text = parts.compactMap { part -> String? in
            guard part["type"] as? String == "summary_text" else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    static func parseResponses(_ type: String, _ root: [String: Any]) -> [AgentModelStreamEvent] {
        var callIDs: [String: String] = [:]
        var callNames: [String: String] = [:]
        return parseResponses(
            type, root, callIDs: &callIDs, callNames: &callNames
        )
    }

    static func parseResponses(
        _ type: String, _ root: [String: Any],
        callIDs: inout [String: String], callNames: inout [String: String]
    ) -> [AgentModelStreamEvent] {
        switch type {
        case "response.output_text.delta":
            let events: [AgentModelStreamEvent] =
                (root["delta"] as? String)
                .map { [.textDelta($0)] } ?? []
            return events
        case "response.reasoning_summary_text.delta":
            return (root["delta"] as? String).map { [.reasoningDelta($0)] } ?? []
        case "response.reasoning_summary_text.done":
            return (root["text"] as? String).map { [.reasoningSnapshot($0)] } ?? []
        case "response.function_call_arguments.delta":
            guard let sourceID = (root["item_id"] ?? root["call_id"]) as? String else {
                return []
            }
            let id = root["call_id"] as? String ?? callIDs[sourceID] ?? sourceID
            let name = responseName(root) ?? callNames[sourceID]
            callIDs[sourceID] = id
            if let name { callNames[sourceID] = name }
            return [
                .toolCallDelta(
                    id: id, name: name, arguments: root["delta"] as? String ?? ""
                )
            ]
        case "response.function_call_arguments.done":
            guard let sourceID = (root["item_id"] ?? root["call_id"]) as? String else {
                return []
            }
            let id = root["call_id"] as? String ?? callIDs[sourceID] ?? sourceID
            callIDs[sourceID] = id
            guard let name = responseName(root) ?? callNames[sourceID] else {
                return []
            }
            return [
                .toolCallSnapshot(
                    id: id, providerItemID: sourceID, name: name,
                    arguments: root["arguments"] as? String ?? ""
                )
            ]
        case "response.output_item.added":
            guard let item = root["item"] as? [String: Any], item["type"] as? String == "function_call",
                let sourceID = (item["id"] ?? item["call_id"]) as? String
            else { return [] }
            let id = item["call_id"] as? String ?? sourceID
            callIDs[sourceID] = id
            if let name = responseName(item) { callNames[sourceID] = name }
            return [
                .toolCallDelta(
                    id: id, name: responseName(item),
                    arguments: item["arguments"] as? String ?? ""
                )
            ]
        case "response.output_item.done":
            guard let item = root["item"] as? [String: Any] else { return [] }
            if item["type"] as? String == "reasoning",
                let value = jsonValue(item)
            {
                var events: [AgentModelStreamEvent] = [.providerItem(value)]
                if let summary = responsesReasoningSummary(item), !summary.isEmpty {
                    events.append(.reasoningSnapshot(summary))
                }
                return events
            }
            if item["type"] as? String == "web_search_call" {
                return responsesWebSearch(item)
            }
            guard item["type"] as? String == "function_call",
                let sourceID = (item["id"] ?? item["call_id"]) as? String,
                let name = responseName(item) ?? callNames[sourceID]
            else { return [] }
            let id = item["call_id"] as? String ?? callIDs[sourceID] ?? sourceID
            callIDs[sourceID] = id
            callNames[sourceID] = name
            return [
                .toolCallSnapshot(
                    id: id, providerItemID: item["id"] as? String,
                    name: name,
                    arguments: item["arguments"] as? String ?? ""
                )
            ]
        case "response.completed":
            guard root["response"] is [String: Any] else { return [] }
            return parseCompletedResponses(root)
        case "response.incomplete": return [.finished(.length)]
        case "response.failed": return [.finished(.error)]
        default:
            // Some compatible servers put the complete Responses object in one
            // unnamed SSE `data:` event instead of using typed delta events.
            guard root["object"] as? String == "response" else { return [] }
            let events = parseCompletedResponses(root)
            return events
        }
    }

    static func parseCompletedResponses(
        _ root: [String: Any]
    ) -> [AgentModelStreamEvent] {
        let response = root["response"] as? [String: Any] ?? root
        guard
            response["object"] as? String == "response"
                || response["output"] is [[String: Any]]
        else { return [] }

        var events: [AgentModelStreamEvent] = []
        var completedText = ""
        for item in response["output"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "reasoning":
                if let value = jsonValue(item) { events.append(.providerItem(value)) }
                if let summary = responsesReasoningSummary(item), !summary.isEmpty {
                    events.append(.reasoningSnapshot(summary))
                }
            case "web_search_call":
                events += responsesWebSearch(item)
            case "message":
                for content in item["content"] as? [[String: Any]] ?? [] {
                    if content["type"] as? String == "output_text",
                        let text = content["text"] as? String
                    {
                        completedText += text
                    }
                }
            case "function_call":
                guard let name = responseName(item) else { continue }
                let id =
                    (item["call_id"] ?? item["id"]) as? String
                    ?? UUID().uuidString
                events.append(
                    .toolCallSnapshot(
                        id: id, providerItemID: item["id"] as? String,
                        name: name,
                        arguments: item["arguments"] as? String ?? ""
                    ))
            default: continue
            }
        }
        if !completedText.isEmpty { events.append(.textSnapshot(completedText)) }
        if let usage = openAIUsage(response, inputKey: "input_tokens", outputKey: "output_tokens") {
            events.append(usage)
        }
        let status = response["status"] as? String
        let reason: AgentStopReason
        if status == "incomplete" {
            reason = .length
        } else if status == "failed" {
            reason = .error
        } else {
            reason = events.containsToolCall ? .toolCalls : .completed
        }
        events.append(.finished(reason))
        return events
    }

    /// A completed Responses search, as both a replay item and a card.
    ///
    /// Two events for one item, deliberately. The verbatim `web_search_call`
    /// has to go back to OpenAI on the next turn or the reasoning that produced
    /// it is orphaned, and that is what `providerItem` is for. The card wants
    /// the query, which lives at `action.query` and would mean nothing to the
    /// API. Neither can stand in for the other.
    ///
    /// Sources are absent here on purpose: Responses reports them as
    /// `url_citation` annotations on the message rather than on this item.
    private static func responsesWebSearch(_ item: [String: Any]) -> [AgentModelStreamEvent] {
        var events: [AgentModelStreamEvent] = []
        if let value = jsonValue(item) { events.append(.providerItem(value)) }
        let action = item["action"] as? [String: Any]
        let query = action?["query"] as? String ?? item["query"] as? String ?? ""
        events.append(.webSearch(AgentWebSearchActivity(query: query)))
        return events
    }
}
