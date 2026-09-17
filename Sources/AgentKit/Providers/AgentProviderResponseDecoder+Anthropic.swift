import Foundation

nonisolated extension AgentProviderResponseDecoder {
    static func parseCompletedAnthropic(
        _ root: [String: Any], wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        guard root["type"] as? String == "message" else { return [] }
        var events: [AgentModelStreamEvent] = []
        // The buffered body has both halves of a search in hand, so the query
        // is matched to its results here rather than parked across events the
        // way the streaming parser has to.
        var queries: [String: String] = [:]
        for block in root["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "thinking":
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    events.append(.reasoningDelta(thinking))
                }
                if let value = jsonValue(block) { events.append(.providerItem(value)) }
            case "redacted_thinking":
                if let value = jsonValue(block) { events.append(.providerItem(value)) }
            case "text":
                if let text = block["text"] as? String { events.append(.textDelta(text)) }
            case "tool_use":
                guard let name = block["name"] as? String else { continue }
                let data =
                    block["input"].flatMap {
                        try? JSONSerialization.data(withJSONObject: $0)
                    } ?? Data("{}".utf8)
                events.append(
                    .toolCallDelta(
                        id: block["id"] as? String ?? UUID().uuidString,
                        name: canonicalName(name, wireNames: wireNames),
                        arguments: String(decoding: data, as: UTF8.self)
                    ))
            case "server_tool_use":
                guard let id = block["id"] as? String else { continue }
                queries[id] = (block["input"] as? [String: Any])?["query"] as? String ?? ""
            case "web_search_tool_result":
                let query = (block["tool_use_id"] as? String).flatMap { queries[$0] }
                events.append(
                    .webSearch(
                        AgentWebSearchActivity(
                            query: query ?? "", sources: anthropicSources(block["content"])
                        )))
            default:
                continue
            }
        }
        if let usage = anthropicUsage(root["usage"]) { events.append(usage) }
        events.append(.finished(events.containsToolCall ? .toolCalls : .completed))
        return events
    }

    static func parseAnthropic(_ type: String, _ root: [String: Any]) -> [AgentModelStreamEvent] {
        var state = AnthropicStreamState()
        return parseAnthropic(type, root, state: &state, wireNames: [:])
    }

    static func parseAnthropic(
        _ type: String, _ root: [String: Any], state: inout AnthropicStreamState,
        wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        let index = root["index"] as? Int ?? 0

        // Anthropic splits one turn's count across two events: input arrives
        // with `message_start`, output grows on each `message_delta`. Both are
        // cumulative, which is what `AgentTokenUsage.merging` is built for.
        if type == "message_start" {
            let message = root["message"] as? [String: Any]
            return anthropicUsage(message?["usage"]).map { [$0] } ?? []
        }
        if type == "message_delta" {
            return anthropicUsage(root["usage"]).map { [$0] } ?? []
        }

        if type == "content_block_start", let block = root["content_block"] as? [String: Any] {
            switch block["type"] as? String {
            case "thinking":
                state.thinkingBlocks[index] = AnthropicStreamState.ThinkingBlock(
                    text: block["thinking"] as? String ?? "",
                    signature: block["signature"] as? String ?? ""
                )
                return []
            case "redacted_thinking":
                return jsonValue(block).map { [.providerItem($0)] } ?? []
            case "tool_use":
                let id = block["id"] as? String ?? "index-\(index)"
                state.callIDs[index] = id
                return [
                    .toolCallDelta(
                        id: id,
                        name: (block["name"] as? String).map {
                            canonicalName($0, wireNames: wireNames)
                        }, arguments: ""
                    )
                ]
            case "server_tool_use":
                // The provider's own call, not the model's. Claiming the index
                // here is the whole point: `server_tool_use` streams
                // `input_json_delta` exactly like `tool_use` does, and letting
                // those deltas fall through to the tool-call branch below
                // manufactures a call with an empty name — which `AgentRuntime`
                // rejects with `invalidToolCall`, failing the entire turn.
                state.serverBlocks[index] = AnthropicStreamState.ServerBlock(
                    id: block["id"] as? String ?? "", name: block["name"] as? String ?? ""
                )
                return []
            case "web_search_tool_result":
                state.serverBlocks[index] = AnthropicStreamState.ServerBlock()
                // Anthropic sends the query and its hits as two sibling blocks.
                // The query was parked at the previous block's stop so one card
                // can carry both.
                let query = (block["tool_use_id"] as? String)
                    .flatMap { state.pendingQueries.removeValue(forKey: $0) }
                return [
                    .webSearch(
                        AgentWebSearchActivity(
                            query: query ?? "", sources: anthropicSources(block["content"])
                        ))
                ]
            default:
                return []
            }
        }

        if type == "content_block_delta", let delta = root["delta"] as? [String: Any] {
            if state.thinkingBlocks[index] != nil {
                if let thinking = delta["thinking"] as? String {
                    state.thinkingBlocks[index]?.text += thinking
                    return [.reasoningDelta(thinking)]
                }
                if let signature = delta["signature"] as? String {
                    state.thinkingBlocks[index]?.signature += signature
                }
                return []
            }
            if state.serverBlocks[index] != nil {
                if let json = delta["partial_json"] as? String {
                    state.serverBlocks[index]?.input += json
                }
                return []
            }
            if let text = delta["text"] as? String { return [.textDelta(text)] }
            if let json = delta["partial_json"] as? String {
                return [
                    .toolCallDelta(
                        id: state.callIDs[index] ?? "index-\(index)", name: nil, arguments: json
                    )
                ]
            }
        }

        if type == "content_block_stop",
            let block = state.thinkingBlocks.removeValue(forKey: index)
        {
            var item: [String: Any] = [
                "type": "thinking", "thinking": block.text,
            ]
            if !block.signature.isEmpty { item["signature"] = block.signature }
            return jsonValue(item).map { [.providerItem($0)] } ?? []
        }

        if type == "content_block_stop",
            let block = state.serverBlocks.removeValue(forKey: index), !block.id.isEmpty
        {
            state.pendingQueries[block.id] = anthropicQuery(block.input)
            return []
        }

        if type == "message_stop" { return [.finished(.completed)] }
        return []
    }

    private static func anthropicQuery(_ rawInput: String) -> String {
        guard let data = rawInput.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        return object["query"] as? String ?? ""
    }

    /// Tolerates the error shape. A failed search replaces the array of hits
    /// with a single `web_search_tool_result_error` object, so the cast is what
    /// turns "the search failed" into an empty source list rather than a crash.
    private static func anthropicSources(_ content: Any?) -> [AgentWebSearchActivity.Source] {
        (content as? [[String: Any]] ?? []).compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            return AgentWebSearchActivity.Source(
                title: row["title"] as? String ?? "", url: url
            )
        }
    }

    /// Unlike OpenAI and Gemini, input_tokens excludes cache reads and writes.
    /// Add the three disjoint counts so cached prompts do not look nearly empty.
    private static func anthropicUsage(_ usage: Any?) -> AgentModelStreamEvent? {
        guard let usage = usage as? [String: Any] else { return nil }
        let read = count(usage["cache_read_input_tokens"])
        return .usage(
            AgentTokenUsage(
                inputTokens: count(usage["input_tokens"]) + read
                    + count(usage["cache_creation_input_tokens"]),
                outputTokens: count(usage["output_tokens"]),
                cachedInputTokens: read,
                cacheWriteInputTokens: count(usage["cache_creation_input_tokens"])
            ))
    }
}

/// Per-stream Anthropic block bookkeeping.
///
/// Anthropic streams two kinds of block through the same delta events: the
/// model's own `tool_use`, which the runtime must execute, and the provider's
/// `server_tool_use`, which it must not. Knowing which index is which is the
/// only way to tell them apart mid-stream, and getting it wrong is not a
/// cosmetic error — see `parseAnthropic`.
public nonisolated struct AnthropicStreamState: Sendable {
    fileprivate struct ThinkingBlock: Sendable {
        var text = ""
        var signature = ""
    }

    fileprivate struct ServerBlock: Sendable {
        var id: String = ""
        var name: String = ""
        var input: String = ""
    }

    fileprivate var callIDs: [Int: String] = [:]
    fileprivate var thinkingBlocks: [Int: ThinkingBlock] = [:]
    fileprivate var serverBlocks: [Int: ServerBlock] = [:]
    /// `server_tool_use.id` → query, held from that block's stop until the
    /// sibling `web_search_tool_result` arrives, so one card carries both.
    fileprivate var pendingQueries: [String: String] = [:]

    public init() {}
}
