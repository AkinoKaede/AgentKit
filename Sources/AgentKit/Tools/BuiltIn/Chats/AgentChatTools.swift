import Foundation

/// One locally configured Chat model. The catalog is a snapshot of enabled configuration;
/// implementations must not fetch a remote model catalog or expose credentials.
public nonisolated struct AgentChatModelDescription: Hashable, Sendable {
    public init(
        reference: String,
        name: String,
        provider: String,
        abilities: [String],
        contextWindow: Int,
        supportedReasoning: [String],
        isReady: Bool
    ) {
        self.reference = reference
        self.name = name
        self.provider = provider
        self.abilities = abilities
        self.contextWindow = contextWindow
        self.supportedReasoning = supportedReasoning
        self.isReady = isReady
    }

    public var reference: String
    public var name: String
    public var provider: String
    public var abilities: [String]
    public var contextWindow: Int
    public var supportedReasoning: [String]
    public var isReady: Bool

    fileprivate var json: AgentJSONValue {
        .object([
            "ref": .string(reference),
            "name": .string(name),
            "provider": .string(provider),
            "abilities": .array(abilities.map(AgentJSONValue.string)),
            "context_window": .number(Double(contextWindow)),
            "supported_reasoning": .array(supportedReasoning.map(AgentJSONValue.string)),
            "ready": .bool(isReady),
        ])
    }
}

@MainActor public protocol AgentChatModelCatalog: Sendable {
    func configuredChatModels() async throws -> [AgentChatModelDescription]
}

/// Immutable identity and policy of the run that is using a chat tool.
public nonisolated struct AgentChatSourceContext: Hashable, Sendable {
    public init(
        conversationID: UUID,
        title: String,
        modelReference: String,
        permissionMode: AgentPermissionMode,
        mode: AgentRunMode
    ) {
        self.conversationID = conversationID
        self.title = title
        self.modelReference = modelReference
        self.permissionMode = permissionMode
        self.mode = mode
    }

    public var conversationID: UUID
    public var title: String
    public var modelReference: String
    public var permissionMode: AgentPermissionMode
    public var mode: AgentRunMode
}

/// Host-owned lifecycle and storage for collaboration between independent chats.
/// Results are bounded JSON contracts consumed by the model and safe presenters below.
@MainActor public protocol AgentChatCoordinating: Sendable {
    func createChat(
        prompt: String, model: String?, title: String?,
        source: AgentChatSourceContext, sourceRunID: UUID, sourceToolCallID: String
    ) async throws -> AgentJSONValue
    func listChats(cursor: String?, includeArchived: Bool) async throws -> AgentJSONValue
    func readChat(id: UUID, cursor: String?) async throws -> AgentJSONValue
    func sendToChat(
        id: UUID, message: String, source: AgentChatSourceContext,
        sourceRunID: UUID, sourceToolCallID: String
    ) async throws -> AgentJSONValue
    func waitForChats(
        ids: [UUID], timeoutMilliseconds: Int,
        source: AgentChatSourceContext,
        untilUserInterjects: @escaping @Sendable () async -> Void
    ) async throws -> AgentJSONValue
}

private nonisolated enum AgentChatToolPresentation {
    typealias F = AgentToolDetailFormatting
    typealias Item = AgentToolDetail.Item

    static func chatRow(
        _ value: AgentJSONValue, locale: Locale, includeModel: Bool = true
    ) -> AgentToolDetail.ListRow? {
        guard let object = value.objectValue,
            let rawID = object["chat_id"]?.stringValue,
            let id = UUID(uuidString: rawID)
        else { return nil }
        let title =
            F.nonempty(object["title"]?.stringValue)
            ?? F.localized("Chat", locale: locale)
        let status = F.nonempty(object["status"]?.stringValue)
        let model = includeModel ? F.nonempty(object["model"]?.stringValue) : nil
        return .init(
            title: title,
            subtitle: [model, status.map { F.statusLabel($0, locale: locale) }]
                .compactMap { $0 }.joined(separator: " · "),
            symbol: "bubble.left.and.bubble.right",
            navigation: .chat(id)
        )
    }

    static func models(_ input: AgentToolDetailInput) -> [Item] {
        guard let object = input.result.objectValue,
            let values = object["models"]?.arrayValue
        else {
            return [.message(F.localized("Model list unavailable", locale: input.locale), .secondary)]
        }
        let grouped = Dictionary(grouping: values) { value in
            value.objectValue?["provider"]?.stringValue
                ?? F.localized("Provider", locale: input.locale)
        }
        let sections = grouped.keys.sorted().map { provider in
            AgentToolDetail.ListSection(
                title: provider,
                rows: grouped[provider, default: []].compactMap { value in
                    guard let model = value.objectValue,
                        let name = F.nonempty(model["name"]?.stringValue)
                    else { return nil }
                    let context = model["context_window"]?.integerValue.map {
                        localizedNumber($0, locale: input.locale)
                    }
                    let badges =
                        model["abilities"]?.arrayValue?.compactMap(\.stringValue)
                        .map { abilityLabel($0, locale: input.locale) }.prefix(3) ?? []
                    return .init(
                        title: name,
                        subtitle: context.map {
                            String(format: F.localized("%@ context", locale: input.locale), $0)
                        },
                        badges: Array(badges),
                        symbol: model["ready"]?.boolValue == false ? "exclamationmark.circle" : "cpu"
                    )
                })
        }
        return [
            .groupedList(
                .init(
                    summary: String(
                        format: F.localized("%lld models", locale: input.locale),
                        Int64(values.count)
                    ),
                    sections: sections, isScrollable: values.count > 5
                ))
        ]
    }

    static func oneChat(_ input: AgentToolDetailInput) -> [Item] {
        guard let row = chatRow(input.result, locale: input.locale) else {
            return [.message(F.localized("Chat unavailable", locale: input.locale), .secondary)]
        }
        return [.list(.init(rows: [row]))]
    }

    static func chats(_ input: AgentToolDetailInput) -> [Item] {
        guard let object = input.result.objectValue,
            let values = object["chats"]?.arrayValue
        else {
            return [.message(F.localized("Chat list unavailable", locale: input.locale), .secondary)]
        }
        return [
            .list(
                .init(
                    rows: values.compactMap { chatRow($0, locale: input.locale) },
                    emptyMessage: F.localized("No chats", locale: input.locale)
                ))
        ]
    }

    static func read(_ input: AgentToolDetailInput) -> [Item] {
        guard var row = chatRow(input.result, locale: input.locale, includeModel: false),
            let object = input.result.objectValue
        else { return [.message(F.localized("Chat unavailable", locale: input.locale), .secondary)] }
        if let count = object["message_count"]?.integerValue {
            row.detail = String(
                format: F.localized("%lld messages read", locale: input.locale), Int64(count))
        }
        return [.list(.init(rows: [row]))]
    }

    static func wait(_ input: AgentToolDetailInput) -> [Item] {
        guard let object = input.result.objectValue,
            let values = object["chats"]?.arrayValue
        else { return [.message(F.localized("Chat status unavailable", locale: input.locale), .secondary)] }
        var items: [Item] = []
        if object["timed_out"]?.boolValue == true {
            items.append(.message(F.localized("Wait timed out", locale: input.locale), .secondary))
        } else if object["interrupted"]?.boolValue == true {
            items.append(.message(F.localized("Wait stopped by user input", locale: input.locale), .secondary))
        }
        let rows = values.compactMap { chatRow($0, locale: input.locale, includeModel: false) }
        if !rows.isEmpty { items.append(.list(.init(rows: rows))) }
        return items.isEmpty
            ? [.message(F.localized("Chat status unavailable", locale: input.locale), .secondary)]
            : items
    }

    static func safeArguments(_ input: AgentToolArgumentDetailInput) -> [Item] {
        guard let rawID = input.arguments["chat_id"]?.stringValue,
            let id = UUID(uuidString: rawID)
        else { return [] }
        return [
            .list(
                .init(rows: [
                    .init(
                        title: F.localized("Chat", locale: input.locale),
                        symbol: "bubble.left.and.bubble.right", navigation: .chat(id))
                ]))
        ]
    }

    private static func localizedNumber(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func abilityLabel(_ value: String, locale: Locale) -> String {
        switch value {
        case "toolCall": F.localized("Tools", locale: locale)
        case "reasoning": F.localized("Reasoning", locale: locale)
        case "structuredOutput": F.localized("Structured Output", locale: locale)
        case "webSearch": F.localized("Web Search", locale: locale)
        default: F.humanized(value).capitalized(with: locale)
        }
    }
}

public nonisolated struct ListModelsTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.list_models", present: AgentChatToolPresentation.models,
        presentArguments: { _ in [] })
    let catalog: any AgentChatModelCatalog
    public init(catalog: any AgentChatModelCatalog) { self.catalog = catalog }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "list_models",
            "List enabled locally configured Chat models, their capabilities, context windows, reasoning support, and readiness. Does not fetch remote catalogs or reveal credentials.",
            properties: [:], required: [], target: .local, approvalPolicy: .approve,
            concurrency: .parallel,
            presentation: .init(
                symbol: "cpu", activity: .semanticLabel(.models), output: .json,
                actionKind: .list))
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let models = try await catalog.configuredChatModels()
        return Self.result(
            invocation,
            .object([
                "count": .number(Double(models.count)),
                "models": .array(models.map(\.json)),
            ]))
    }
}

private nonisolated protocol AgentChatTool: AgentToolDefinition, AgentToolSchemaBuilding {
    var coordinator: any AgentChatCoordinating { get }
    var source: AgentChatSourceContext { get }
}

public nonisolated struct CreateNewChatTool: AgentChatTool {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.create_new_chat", present: AgentChatToolPresentation.oneChat,
        presentArguments: { _ in [] })
    let coordinator: any AgentChatCoordinating
    let source: AgentChatSourceContext
    public init(coordinator: any AgentChatCoordinating, source: AgentChatSourceContext) {
        self.coordinator = coordinator
        self.source = source
    }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "create_new_chat",
            "Create and start an independent local chat with an explicit prompt. The new chat receives no copied history, attachments, scratch files, windows, terminal connections, or secret handles.",
            properties: [
                "prompt": Self.string(max: 32_000), "model": Self.string(max: 512),
                "title": Self.string(max: 160),
            ], required: ["prompt"], target: .local, approvalPolicy: .approve,
            presentation: .init(
                symbol: "plus.bubble", activity: .semanticLabel(.chat), output: .json,
                groupsWithAdjacentTools: false, actionKind: .create))
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        return Self.result(
            invocation,
            try await coordinator.createChat(
                prompt: arguments.string("prompt"), model: arguments.optionalString("model"),
                title: arguments.optionalString("title"), source: source,
                sourceRunID: context.runID, sourceToolCallID: invocation.call.id))
    }
}

public nonisolated struct ListChatsTool: AgentChatTool {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.list_chats", present: AgentChatToolPresentation.chats,
        presentArguments: { _ in [] })
    let coordinator: any AgentChatCoordinating
    let source: AgentChatSourceContext
    public init(coordinator: any AgentChatCoordinating, source: AgentChatSourceContext) {
        self.coordinator = coordinator
        self.source = source
    }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "list_chats", "List the bounded local conversation library. Archived chats are excluded by default.",
            properties: ["cursor": Self.string(max: 512), "include_archived": Self.boolean()], required: [],
            target: .local, approvalPolicy: .approve, concurrency: .parallel,
            presentation: .init(
                symbol: "bubble.left.and.bubble.right", activity: .semanticLabel(.chats), output: .json,
                actionKind: .list))
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        return Self.result(
            invocation,
            try await coordinator.listChats(
                cursor: arguments.optionalString("cursor"),
                includeArchived: arguments.optionalBool("include_archived") ?? false))
    }
}

public nonisolated struct ReadChatTool: AgentChatTool {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.read_chat", present: AgentChatToolPresentation.read,
        presentArguments: AgentChatToolPresentation.safeArguments)
    let coordinator: any AgentChatCoordinating
    let source: AgentChatSourceContext
    public init(coordinator: any AgentChatCoordinating, source: AgentChatSourceContext) {
        self.coordinator = coordinator
        self.source = source
    }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "read_chat",
            "Read a bounded page of visible messages, tool summaries, run state, and delivery status from one local chat. Never returns internal reasoning or secrets.",
            properties: ["chat_id": Self.string(max: 36), "cursor": Self.string(max: 512)],
            required: ["chat_id"], target: .local, approvalPolicy: .approve, concurrency: .parallel,
            presentation: .init(
                symbol: "text.bubble", activity: .semanticLabel(.chat), output: .json,
                actionKind: .read))
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        return Self.result(
            invocation,
            try await coordinator.readChat(
                id: try arguments.chatID("chat_id"), cursor: arguments.optionalString("cursor")))
    }
}

public nonisolated struct SendToChatTool: AgentChatTool {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.send_to_chat", present: AgentChatToolPresentation.oneChat,
        presentArguments: AgentChatToolPresentation.safeArguments)
    let coordinator: any AgentChatCoordinating
    let source: AgentChatSourceContext
    public init(coordinator: any AgentChatCoordinating, source: AgentChatSourceContext) {
        self.coordinator = coordinator
        self.source = source
    }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "send_to_chat",
            "Send an agent-authored message to another local chat. Idle targets start a run; active targets accept it at the next model boundary. Returns immediately with a durable delivery receipt.",
            properties: ["chat_id": Self.string(max: 36), "message": Self.string(max: 32_000)],
            required: ["chat_id", "message"], target: .local, approvalPolicy: .approve,
            presentation: .init(
                symbol: "paperplane", activity: .semanticLabel(.chat), output: .json,
                groupsWithAdjacentTools: false, actionKind: .send))
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        return Self.result(
            invocation,
            try await coordinator.sendToChat(
                id: try arguments.chatID("chat_id"), message: arguments.string("message"),
                source: source, sourceRunID: context.runID,
                sourceToolCallID: invocation.call.id))
    }
}

public nonisolated struct WaitChatsTool: AgentChatTool {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.wait_chats", present: AgentChatToolPresentation.wait,
        presentArguments: { _ in [] })
    let coordinator: any AgentChatCoordinating
    let source: AgentChatSourceContext
    public init(coordinator: any AgentChatCoordinating, source: AgentChatSourceContext) {
        self.coordinator = coordinator
        self.source = source
    }
    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "wait_chats",
            "Wait until any of up to eight local chats completes or needs user action. A zero timeout returns a snapshot. User interjection stops the wait.",
            properties: [
                "chat_ids": Self.array(items: Self.string(max: 36), max: 8),
                "timeout_ms": Self.integer(min: 0, max: 60_000),
            ], required: ["chat_ids"], target: .local, approvalPolicy: .approve,
            concurrency: .parallel,
            presentation: .init(
                symbol: "hourglass", activity: .semanticLabel(.chats), output: .json,
                actionKind: .wait))
    }
    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        guard let values = arguments.object["chat_ids"]?.arrayValue, !values.isEmpty else {
            throw AgentToolError.invalidArguments("chat_ids must contain at least one chat.")
        }
        let ids = try values.map { value -> UUID in
            guard let raw = value.stringValue, let id = UUID(uuidString: raw) else {
                throw AgentToolError.invalidArguments("chat_ids contains an invalid chat ID.")
            }
            return id
        }
        guard Set(ids).count == ids.count else {
            throw AgentToolError.invalidArguments("chat_ids must not contain duplicates.")
        }
        return Self.result(
            invocation,
            try await coordinator.waitForChats(
                ids: ids, timeoutMilliseconds: arguments.optionalInt("timeout_ms") ?? 60_000,
                source: source, untilUserInterjects: context.whenUserInterjects))
    }
}
nonisolated

    extension Arguments
{
    fileprivate func chatID(_ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(key)) else {
            throw AgentToolError.invalidArguments("\(key) is not a valid chat ID.")
        }
        return value
    }
}
