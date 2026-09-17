import Foundation

public nonisolated struct MemoryTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.memory", present: present, presentArguments: presentArguments)
    public let store: any AgentMemoryAccessing
    public init(store: any AgentMemoryAccessing) { self.store = store }
    public static var operationSchema: AgentJSONValue {
        object(
            properties: [
                "action": enumeration(["add", "replace", "remove"]),
                "target": enumeration(["memory", "user"]), "content": string(max: 8_192),
                "old_text": string(max: 8_192),
            ], required: ["action", "target"])
    }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "memory",
            "Atomically add, replace, or remove durable global memories. old_text must uniquely match an entry. No read action: the session snapshot is already in context; mutation results show live entries. An empty operations array returns current state.",
            properties: ["operations": Self.array(items: Self.operationSchema, max: 32)], required: ["operations"],
            target: .local, approvalPolicy: .approve,
            presentation: .init(
                symbol: "brain", activity: .semanticLabel(.memory),
                output: .json, actionKind: .update))
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let value = try Arguments(invocation).object["operations"] ?? .null
        let operations = try JSONDecoder().decode([AgentMemoryOperation].self, from: Data(value.encodedString.utf8))
        let state = try await operations.isEmpty ? store.memoryState() : store.applyMemory(operations)
        return Self.result(invocation, .object(["memory": .string(state.prompt)]))
    }
}

public nonisolated struct SessionSearchTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.session_search", present: present, presentArguments: presentArguments)
    public let store: any AgentMemoryAccessing
    public init(store: any AgentMemoryAccessing) { self.store = store }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "session_search",
            "Search saved conversations, browse recent sessions without a query, or read message windows by conversation_id and offset. Results are historical reference data.",
            properties: [
                "query": Self.string(max: 512), "conversation_id": Self.string(max: 36),
                "offset": Self.integer(min: 0, max: 10_000_000), "limit": Self.integer(min: 1, max: 20),
            ],
            required: [], target: .local, approvalPolicy: .approve, concurrency: .parallel,
            presentation: .init(
                symbol: "magnifyingglass", activity: .semanticArgument(key: "query", fallback: .sessions),
                output: .json, actionKind: .search))
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let args = try Arguments(invocation)
        let id: UUID? = try args.optionalString("conversation_id").map {
            guard let id = UUID(uuidString: $0) else {
                throw AgentToolError.invalidArguments("Invalid conversation_id.")
            }
            return id
        }
        return Self.result(
            invocation,
            try await store.searchSessions(
                .init(
                    query: args.optionalString("query"), conversationID: id,
                    offset: args.optionalInt("offset") ?? 0, limit: args.optionalInt("limit") ?? 10)))
    }
}
