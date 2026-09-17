import Foundation

/// Pure wire encoding. Authentication and network lifetimes belong to the client;
/// this value contains only the configuration that affects a request payload.
nonisolated struct AgentProviderRequestEncoder: Sendable {
    let provider: ModelProvider
    let model: AIModel
    let reasoning: ReasoningEffort
    let webSearch: Bool
    let promptCacheKey: String?

    func buildRequest(
        _ input: AgentModelRequest, streaming: Bool
    ) throws -> URLRequest {
        var urlString = provider.requestURL(model: model.id)
        if provider.apiFormat == .generateContent, streaming {
            urlString = urlString.replacingOccurrences(
                of: ":generateContent", with: ":streamGenerateContent"
            )
            if !urlString.contains("alt=sse") {
                urlString += urlString.contains("?") ? "&alt=sse" : "?alt=sse"
            }
        }
        guard let url = URL(string: urlString) else {
            throw AgentProviderError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            streaming ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body(input, streaming: streaming), options: [.sortedKeys]
        )
        return request
    }

    func body(
        _ request: AgentModelRequest, streaming: Bool
    ) -> [String: Any] {
        var request = request
        request.tools.sort { $0.qualifiedName < $1.qualifiedName }
        let toolNames = AgentProviderToolNameMap.flat(request.tools)
        let reasoningResolution = ModelCapabilityResolver.reasoning(
            model: model, provider: provider
        )
        let normalizedReasoning = reasoningResolution.clamp(reasoning)
        let reasoningValue = reasoningResolution.wireValue(for: normalizedReasoning)
        let prepared = PreparedRequest(
            input: request, streaming: streaming, toolNames: toolNames,
            reasoningValue: reasoningValue, output: supportedOutputFormat(request)
        )
        switch provider.apiFormat {
        case .responses: return responsesBody(prepared)
        case .chatCompletions: return chatBody(prepared)
        case .messages: return anthropicBody(prepared)
        case .generateContent: return googleBody(prepared)
        }
    }

    /// Canonical ordering and capability decisions are resolved once, before
    /// choosing a wire format. The original request remains unchanged.
    private struct PreparedRequest {
        let input: AgentModelRequest
        let streaming: Bool
        let toolNames: AgentProviderToolNameMap
        let reasoningValue: String?
        let output: AgentModelOutputFormat?
    }

    private func responsesBody(_ prepared: PreparedRequest) -> [String: Any] {
        let request = prepared.input
        var tools = Self.responsesToolObjects(request.tools)
        if webSearch { tools.append(["type": "web_search"]) }
        var body: [String: Any] = [
            "model": model.id, "stream": prepared.streaming,
            "instructions": request.systemPrompt,
            "input": request.messages.flatMap(Self.responsesMessages),
        ]
        if let promptCacheKey { body["prompt_cache_key"] = promptCacheKey }
        if !tools.isEmpty { body["tools"] = tools }
        if let output = prepared.output {
            var format = Self.openAIOutputSchema(output)
            format["type"] = "json_schema"
            body["text"] = ["format": format]
        }
        if let reasoningValue = prepared.reasoningValue {
            body["reasoning"] = ["effort": reasoningValue, "summary": "auto"]
        }
        return body
    }

    private func chatBody(_ prepared: PreparedRequest) -> [String: Any] {
        let request = prepared.input
        let toolNames = prepared.toolNames
        // No search here, whatever the model claims. `web_search_options`
        // exists on two `*-search-preview` SKUs, while this branch is also
        // every OpenAI-compatible gateway — see
        // `ModelProvider.supportsNativeWebSearch`, which is what actually
        // prevents it reaching this far.
        let tools = request.tools.map {
            Self.openAIToolObject($0, name: toolNames.wireName(for: $0.qualifiedName))
        }
        var messages: [[String: Any]] = [["role": "system", "content": request.systemPrompt]]
        messages += request.messages.flatMap {
            Self.chatMessages($0, toolNames: toolNames)
        }
        var body: [String: Any] = [
            "model": model.id, "stream": prepared.streaming, "messages": messages,
        ]
        // The one provider that has to be asked for its own token counts.
        // Responses, Anthropic and Gemini report usage unconditionally;
        // Chat Completions omits it from a stream unless this is present.
        // Only on the streaming path — sending it on a non-streaming request
        // is what several OpenAI-compatible gateways reject outright.
        if let promptCacheKey { body["prompt_cache_key"] = promptCacheKey }
        if prepared.streaming { body["stream_options"] = ["include_usage": true] }
        if !tools.isEmpty { body["tools"] = tools.map { ["type": "function", "function": $0] } }
        if let output = prepared.output {
            body["response_format"] = [
                "type": "json_schema", "json_schema": Self.openAIOutputSchema(output),
            ]
        }
        if let reasoningValue = prepared.reasoningValue { body["reasoning_effort"] = reasoningValue }
        return body
    }

    private func anthropicBody(_ prepared: PreparedRequest) -> [String: Any] {
        let request = prepared.input
        let toolNames = prepared.toolNames
        var tools: [[String: Any]] = request.tools.map {
            Self.providerToolObject(
                $0, name: toolNames.wireName(for: $0.qualifiedName), schemaKey: "input_schema"
            )
        }
        if webSearch {
            tools.append([
                "type": "web_search_20250305", "name": "web_search",
                "max_uses": Self.nativeWebSearchMaxUses,
            ])
        }
        var body: [String: Any] = [
            "model": model.id, "stream": prepared.streaming,
            "max_tokens": model.maxOutputTokens ?? 4096,
            "system": [["type": "text", "text": request.systemPrompt, "cache_control": ["type": "ephemeral"]]],
            "messages": Self.anthropicCachedMessages(
                request.messages.flatMap {
                    Self.anthropicMessages($0, toolNames: toolNames)
                }),
        ]
        if !tools.isEmpty { body["tools"] = tools }
        var outputConfig: [String: Any] = [:]
        if let output = prepared.output {
            outputConfig["format"] = [
                "type": "json_schema", "schema": Self.foundationObject(output.schema),
            ]
        }
        if let reasoningValue = prepared.reasoningValue {
            outputConfig["effort"] = reasoningValue
            if Self.supportsAdaptiveAnthropicThinking(model.id) {
                body["thinking"] = [
                    "type": "adaptive", "display": "summarized",
                ]
            }
        }
        if !outputConfig.isEmpty { body["output_config"] = outputConfig }
        return body
    }

    private func googleBody(_ prepared: PreparedRequest) -> [String: Any] {
        let request = prepared.input
        let toolNames = prepared.toolNames
        let declarations = request.tools.map {
            Self.providerToolObject($0, name: toolNames.wireName(for: $0.qualifiedName))
        }
        // Two entries, not two keys in one entry. Gemini's `tools` is a
        // list of tool *groups*, and putting `google_search` beside
        // `functionDeclarations` inside one object is the arrangement it
        // rejects.
        var tools: [[String: Any]] = []
        if !declarations.isEmpty { tools.append(["functionDeclarations": declarations]) }
        if webSearch { tools.append(["google_search": [String: Any]()]) }
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": request.systemPrompt]]],
            "contents": request.messages.map {
                Self.googleMessage($0, toolNames: toolNames)
            },
        ]
        if !tools.isEmpty { body["tools"] = tools }
        var generationConfig: [String: Any] = [:]
        if let output = prepared.output {
            generationConfig["responseFormat"] = [
                "text": [
                    "mimeType": "application/json",
                    "schema": Self.foundationObject(output.schema),
                ]
            ]
        }
        if let reasoningValue = prepared.reasoningValue {
            generationConfig["thinkingConfig"] = [
                "thinkingLevel": reasoningValue,
                "includeThoughts": true,
            ]
        }
        if !generationConfig.isEmpty { body["generationConfig"] = generationConfig }
        return body
    }

    private static func openAIOutputSchema(_ output: AgentModelOutputFormat) -> [String: Any] {
        [
            "name": output.name, "strict": output.strict,
            "schema": foundationObject(output.strict ? openAIStrictSchema(output.schema) : output.schema),
        ]
    }

    private func supportedOutputFormat(
        _ request: AgentModelRequest
    ) -> AgentModelOutputFormat? {
        guard model.abilities.contains(.structuredOutput) else { return nil }
        return request.outputFormat
    }

    private static func anthropicCachedMessages(_ input: [[String: Any]]) -> [[String: Any]] {
        var messages = input
        var marked = 0
        for index in messages.indices.reversed() {
            guard marked < 2 else { break }
            let content = messages[index]["content"]
            var blocks: [[String: Any]]
            if let text = content as? String, !text.isEmpty {
                blocks = [["type": "text", "text": text]]
            } else if let values = content as? [[String: Any]] {
                blocks = values
            } else {
                continue
            }
            guard
                let last = blocks.indices.last(where: {
                    let kind = blocks[$0]["type"] as? String
                    return kind == "text" || kind == "image" || kind == "tool_result" || kind == "tool_use"
                })
            else { continue }
            blocks[last]["cache_control"] = ["type": "ephemeral"]
            messages[index]["content"] = blocks
            marked += 1
        }
        return messages
    }

    /// A ceiling on searches per turn, which only Anthropic's tool takes as a
    /// parameter. Eight is enough for a model to refine a query a few times and
    /// low enough that a loop costs a bounded number of billed searches.
    static let nativeWebSearchMaxUses = 8

    /// Adaptive thinking and effort are one protocol on current Claude
    /// families. Older extended-thinking models use a token budget instead;
    /// inventing that budget from this app's qualitative effort control would
    /// silently change cost, so those models keep their existing request shape.
    private static func supportsAdaptiveAnthropicThinking(_ modelID: String) -> Bool {
        modelID.lowercased().range(
            of: #"claude-(opus|sonnet|haiku)-(4[-.]([6-9])|[5-9])"#,
            options: .regularExpression
        ) != nil
    }

    private static func providerToolObject(
        _ descriptor: AgentToolDescriptor, name: String, schemaKey: String = "parameters"
    ) -> [String: Any] {
        [
            "name": name,
            "description": descriptor.summary,
            schemaKey: foundationObject(descriptor.inputSchema),
        ]
    }

    private static func openAIToolObject(
        _ descriptor: AgentToolDescriptor, name: String? = nil
    ) -> [String: Any] {
        [
            "name": name ?? descriptor.name,
            "description": descriptor.summary,
            "parameters": foundationObject(openAIStrictSchema(descriptor.inputSchema)),
            "strict": true,
        ]
    }

    private static func responsesToolObjects(
        _ descriptors: [AgentToolDescriptor]
    ) -> [[String: Any]] {
        var tools = descriptors.filter { $0.namespace == nil }.map { descriptor in
            var tool = openAIToolObject(descriptor)
            tool["type"] = "function"
            return tool
        }
        let grouped = Dictionary(
            grouping: descriptors.compactMap { descriptor in
                descriptor.namespace.map { ($0, descriptor) }
            }, by: { $0.0 })
        for namespace in grouped.keys.sorted() {
            let members = (grouped[namespace] ?? []).map(\.1)
                .sorted { $0.name < $1.name }
            let children = members.map { descriptor -> [String: Any] in
                var tool = openAIToolObject(descriptor)
                tool["type"] = "function"
                return tool
            }
            tools.append([
                "type": "namespace", "name": namespace, "tools": children,
            ])
        }
        return tools
    }

    /// OpenAI strict function schemas require every property to appear in
    /// `required`; semantic optionals are represented as nullable instead.
    /// The provider-neutral schema is kept unchanged for local validation.
    static func openAIStrictSchema(_ schema: AgentJSONValue) -> AgentJSONValue {
        guard var object = schema.objectValue else { return schema }

        if let properties = object["properties"]?.objectValue {
            let originallyRequired = Set(
                object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
            object["properties"] = .object(
                properties.reduce(into: [:]) { result, pair in
                    let normalized = openAIStrictSchema(pair.value)
                    result[pair.key] =
                        originallyRequired.contains(pair.key)
                        ? normalized : nullable(normalized)
                })
            object["required"] = .array(properties.keys.sorted().map(AgentJSONValue.string))
            object["additionalProperties"] = .bool(false)
        }
        if let items = object["items"] { object["items"] = openAIStrictSchema(items) }
        if let variants = object["anyOf"]?.arrayValue {
            object["anyOf"] = .array(variants.map(openAIStrictSchema))
        }
        return .object(object)
    }

    private static func nullable(_ schema: AgentJSONValue) -> AgentJSONValue {
        guard var object = schema.objectValue else {
            return .object(["anyOf": .array([schema, .object(["type": .string("null")])])])
        }
        if let type = object["type"]?.stringValue {
            object["type"] = .array([.string(type), .string("null")])
            return .object(object)
        }
        if var types = object["type"]?.arrayValue {
            if !types.contains(.string("null")) { types.append(.string("null")) }
            object["type"] = .array(types)
            return .object(object)
        }
        if var variants = object["anyOf"]?.arrayValue {
            let nullType = AgentJSONValue.object(["type": .string("null")])
            if !variants.contains(nullType) { variants.append(nullType) }
            object["anyOf"] = .array(variants)
            return .object(object)
        }
        return .object(["anyOf": .array([.object(object), .object(["type": .string("null")])])])
    }

    private static func foundationObject(_ value: AgentJSONValue) -> Any {
        switch value {
        case .object(let value): value.mapValues(foundationObject)
        case .array(let value): value.map(foundationObject)
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }

    private static func responsesMessages(_ message: AgentTranscriptMessage) -> [[String: Any]] {
        if message.role == .tool {
            return [["type": "function_call_output", "call_id": message.toolCallID ?? "", "output": message.text]]
        }
        var rows = message.providerItems.compactMap { foundationObject($0) as? [String: Any] }
        if !message.text.isEmpty || !message.images.isEmpty {
            var content: [[String: Any]] = []
            if !message.text.isEmpty {
                content.append([
                    "type": message.role == .assistant ? "output_text" : "input_text",
                    "text": message.text,
                ])
            }
            if message.role == .user {
                content += message.images.map {
                    ["type": "input_image", "image_url": dataURI(for: $0)]
                }
            }
            rows.append([
                "type": "message", "role": message.role.rawValue,
                "content": content,
            ])
        }
        rows += message.toolCalls.map { call in
            let parts = splitQualifiedName(call.name)
            var item: [String: Any] = [
                "type": "function_call", "call_id": call.id,
                "name": parts.name, "arguments": call.arguments.encodedString,
            ]
            if let namespace = parts.namespace { item["namespace"] = namespace }
            if let providerItemID = call.providerItemID { item["id"] = providerItemID }
            return item
        }
        return rows
    }

    private static func chatMessages(
        _ message: AgentTranscriptMessage, toolNames: AgentProviderToolNameMap
    ) -> [[String: Any]] {
        if message.role == .tool {
            return [["role": "tool", "tool_call_id": message.toolCallID ?? "", "content": message.text]]
        }
        var row: [String: Any] = ["role": message.role.rawValue]
        if message.role == .user, !message.images.isEmpty {
            var content: [[String: Any]] = []
            if !message.text.isEmpty { content.append(["type": "text", "text": message.text]) }
            content += message.images.map {
                ["type": "image_url", "image_url": ["url": dataURI(for: $0)]]
            }
            row["content"] = content
        } else {
            row["content"] = message.text
        }
        if !message.toolCalls.isEmpty {
            row["tool_calls"] = message.toolCalls.map {
                [
                    "id": $0.id, "type": "function",
                    "function": [
                        "name": toolNames.wireName(for: $0.name),
                        "arguments": $0.arguments.encodedString,
                    ],
                ]
            }
        }
        return [row]
    }

    private static func anthropicMessages(
        _ message: AgentTranscriptMessage, toolNames: AgentProviderToolNameMap
    ) -> [[String: Any]] {
        if message.role == .tool {
            return [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result", "tool_use_id": message.toolCallID ?? "", "content": message.text,
                            "is_error": message.isError,
                        ]
                    ],
                ]
            ]
        }
        var content = message.providerItems.compactMap { item -> [String: Any]? in
            guard let row = foundationObject(item) as? [String: Any],
                let type = row["type"] as? String,
                type == "thinking" || type == "redacted_thinking"
            else { return nil }
            return row
        }
        if !message.text.isEmpty { content.append(["type": "text", "text": message.text]) }
        if message.role == .user {
            content += message.images.map { image in
                [
                    "type": "image",
                    "source": [
                        "type": "base64", "media_type": image.mimeType,
                        "data": image.data.base64EncodedString(),
                    ],
                ]
            }
        }
        content += message.toolCalls.map {
            [
                "type": "tool_use", "id": $0.id,
                "name": toolNames.wireName(for: $0.name),
                "input": foundationObject($0.arguments),
            ]
        }
        return [["role": message.role == .assistant ? "assistant" : "user", "content": content]]
    }

    private static func googleMessage(
        _ message: AgentTranscriptMessage, toolNames: AgentProviderToolNameMap
    ) -> [String: Any] {
        if message.role == .tool {
            return [
                "role": "user",
                "parts": [
                    [
                        "functionResponse": [
                            "name": toolNames.wireName(for: message.toolName ?? "tool"),
                            "response": ["output": message.text],
                        ]
                    ]
                ],
            ]
        }
        var parts = message.providerItems.compactMap { item -> [String: Any]? in
            guard let row = foundationObject(item) as? [String: Any],
                row["thought"] as? Bool == true
            else { return nil }
            return row
        }
        if !message.text.isEmpty { parts.append(["text": message.text]) }
        if message.role == .user {
            parts += message.images.map { image in
                [
                    "inlineData": [
                        "mimeType": image.mimeType,
                        "data": image.data.base64EncodedString(),
                    ]
                ]
            }
        }
        parts += message.toolCalls.map { call in
            var part: [String: Any] = [
                "functionCall": [
                    "name": toolNames.wireName(for: call.name),
                    "args": foundationObject(call.arguments),
                ]
            ]
            if let signature = call.providerItemID {
                part["thoughtSignature"] = signature
            }
            return part
        }
        return ["role": message.role == .assistant ? "model" : "user", "parts": parts]
    }

    private static func splitQualifiedName(
        _ qualifiedName: String
    ) -> (namespace: String?, name: String) {
        guard let separator = qualifiedName.firstIndex(of: ".") else {
            return (nil, qualifiedName)
        }
        return (
            String(qualifiedName[..<separator]),
            String(qualifiedName[qualifiedName.index(after: separator)...])
        )
    }

    private static func dataURI(for image: AgentImageAttachment) -> String {
        "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
    }
}
