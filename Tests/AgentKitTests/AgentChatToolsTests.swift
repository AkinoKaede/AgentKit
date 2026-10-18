import Foundation
import Testing

@testable import AgentKit

@Suite
@MainActor
struct AgentChatToolsTests {
    @Test
    func collaborationGroupRegistersSixApprovedToolsOnlyWithItsHostDependencies() {
        let host = StubChatHost()
        let source = AgentChatSourceContext(
            conversationID: UUID(), title: "Source", modelReference: "provider::model",
            permissionMode: .askForApproval, mode: .acting)

        let complete = AgentToolCatalog.registry(
            builtIn: .init(
                groups: [.chatCollaboration], chatModels: host, chats: host,
                chatSource: source))
        let expected = Set([
            "list_models", "create_new_chat", "list_chats", "read_chat", "send_to_chat",
            "wait_chats",
        ]).union(AgentKitSmokeTests.scratchNames)
        #expect(Set(complete.descriptors.map(\.name)) == expected)
        #expect(complete.descriptors.allSatisfy { $0.approvalPolicy == .approve })
        #expect(Set(complete.available(in: .planning).descriptors.map(\.name)) == expected)
        #expect(Set(complete.available(in: .acting).descriptors.map(\.name)) == expected)
        #expect(complete.available(in: .reviewing).descriptors.isEmpty)

        let absent = AgentToolCatalog.registry(
            builtIn: .init(groups: [.chatCollaboration]))
        #expect(Set(absent.descriptors.map(\.name)) == AgentKitSmokeTests.scratchNames)

        let catalogOnly = AgentToolCatalog.registry(
            builtIn: .init(groups: [.chatCollaboration], chatModels: host))
        #expect(Set(catalogOnly.descriptors.map(\.name)) == AgentKitSmokeTests.scratchNames.union(["list_models"]))

        let missingSource = AgentToolCatalog.registry(
            builtIn: .init(groups: [.chatCollaboration], chatModels: host, chats: host))
        #expect(Set(missingSource.descriptors.map(\.name)) == AgentKitSmokeTests.scratchNames.union(["list_models"]))
    }

    @Test
    func readOnlyToolsForwardPaginationWithoutChangingAvailability() async throws {
        let host = StubChatHost()
        let source = AgentChatSourceContext(
            conversationID: UUID(), title: "Source", modelReference: "provider::model",
            permissionMode: .askForApproval, mode: .acting)
        let runID = UUID()
        let context = AgentToolExecutionContext(
            runID: runID, userIntent: "Read chats", secretBroker: SecretBroker(),
            userInteraction: UnavailableAgentUserInteraction(), preflightMetadata: [:],
            authorize: { _ in .allow })
        let list = ListChatsTool(coordinator: host, source: source)
        _ = try await list.execute(
            .init(
                runID: runID,
                call: .init(
                    id: "list", name: "list_chats",
                    arguments: .object(["cursor": .string("next-list"), "include_archived": .bool(true)]))),
            context: context)
        #expect(host.listRequests.count == 1)
        #expect(host.listRequests.first?.cursor == "next-list")
        #expect(host.listRequests.first?.includeArchived == true)

        let chatID = UUID()
        let read = ReadChatTool(coordinator: host, source: source)
        let result = try await read.execute(
            .init(
                runID: runID,
                call: .init(
                    id: "read", name: "read_chat",
                    arguments: .object(["chat_id": .string(chatID.uuidString), "cursor": .string("next-read")]))),
            context: context)
        #expect(host.readRequests.count == 1)
        #expect(host.readRequests.first?.id == chatID)
        #expect(host.readRequests.first?.cursor == "next-read")
        #expect(result.hasBoundedModelContent)
        #expect(result.callID == "read")
    }

    @Test
    func approvalPresentersNeverRevealCreatePromptOrSendMessage() throws {
        let chatID = UUID()
        let create = try #require(
            CreateNewChatTool.presenter.presentArguments(
                .init(
                    arguments: [
                        "prompt": .string("private create body"),
                        "model": .string("provider::model"),
                        "title": .string("Private title"),
                    ],
                    locale: Locale(identifier: "en")
                )))
        #expect(create.isEmpty)

        let send = try #require(
            SendToChatTool.presenter.presentArguments(
                .init(
                    arguments: [
                        "chat_id": .string(chatID.uuidString),
                        "message": .string("private send body"),
                    ],
                    locale: Locale(identifier: "en")
                )))
        #expect(!detailText(send).contains("private send body"))
        #expect(detailNavigation(send) == [.chat(chatID)])
    }

    @Test
    func localizedModelAndWaitPresentationsUseInputLocaleAndTypedChatNavigation() throws {
        let chatID = UUID()
        let models = ListModelsTool.presenter.present(
            .init(
                result: .object([
                    "models": .array([
                        .object([
                            "name": .string("Large"), "provider": .string("Provider"),
                            "abilities": .array([.string("toolCall")]),
                            "context_window": .number(12_345), "ready": .bool(true),
                        ])
                    ])
                ]),
                arguments: [:], locale: Locale(identifier: "zh-Hans")
            ))
        let modelText = detailText(models)
        #expect(modelText.contains("1个模型"))
        #expect(modelText.contains("上下文窗口"))
        #expect(modelText.contains("工具"))

        let wait = WaitChatsTool.presenter.present(
            .init(
                result: .object([
                    "timed_out": .bool(true),
                    "interrupted": .bool(false),
                    "chats": .array([
                        .object([
                            "chat_id": .string(chatID.uuidString), "title": .string("Target"),
                            "status": .string("completed"),
                        ])
                    ]),
                ]),
                arguments: [:], locale: Locale(identifier: "en")
            ))
        #expect(detailText(wait).contains("Wait timed out"))
        #expect(detailNavigation(wait) == [.chat(chatID)])
    }

    private func detailText(_ items: [AgentToolDetail.Item]) -> String {
        items.flatMap { item -> [String] in
            switch item {
            case .field(let field): [field.label, field.value]
            case .message(let text, _): [text]
            case .text(let block): [block.title, block.text].compactMap { $0 }
            case .list(let list):
                [list.title, list.emptyMessage].compactMap { $0 }
                    + list.rows.flatMap(rowText)
            case .groupedList(let list):
                [list.summary]
                    + list.sections.flatMap { [$0.title] + $0.rows.flatMap(rowText) }
            }
        }.joined(separator: "\n")
    }

    private func rowText(_ row: AgentToolDetail.ListRow) -> [String] {
        [row.title, row.subtitle, row.detail].compactMap { $0 } + row.badges
    }

    private func detailNavigation(
        _ items: [AgentToolDetail.Item]
    ) -> [AgentToolDetail.NavigationReference] {
        items.flatMap { item -> [AgentToolDetail.NavigationReference] in
            switch item {
            case .field(let field): field.navigation.map { [$0] } ?? []
            case .message, .text: []
            case .list(let list): list.rows.compactMap(\.navigation)
            case .groupedList(let list): list.sections.flatMap { $0.rows.compactMap(\.navigation) }
            }
        }
    }
}

@MainActor
private final class StubChatHost: AgentChatModelCatalog, AgentChatCoordinating {
    private(set) var listRequests: [(cursor: String?, includeArchived: Bool)] = []
    private(set) var readRequests: [(id: UUID, cursor: String?)] = []

    func configuredChatModels() async throws -> [AgentChatModelDescription] { [] }

    func createChat(
        prompt: String, model: String?, title: String?, source: AgentChatSourceContext,
        sourceRunID: UUID, sourceToolCallID: String
    ) async throws -> AgentJSONValue { .object([:]) }

    func listChats(cursor: String?, includeArchived: Bool) async throws -> AgentJSONValue {
        listRequests.append((cursor, includeArchived))
        return .object([:])
    }

    func readChat(id: UUID, cursor: String?) async throws -> AgentJSONValue {
        readRequests.append((id, cursor))
        return .object([:])
    }

    func sendToChat(
        id: UUID, message: String, source: AgentChatSourceContext,
        sourceRunID: UUID, sourceToolCallID: String
    ) async throws -> AgentJSONValue { .object([:]) }

    func waitForChats(
        ids: [UUID], timeoutMilliseconds: Int, source: AgentChatSourceContext,
        untilUserInterjects: @escaping @concurrent @Sendable () async -> Void
    ) async throws -> AgentJSONValue { .object([:]) }
}
