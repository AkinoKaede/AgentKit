import Foundation
import Testing

@testable import AgentKit

@Suite struct AgentKnowledgePresentationTests {
    private let locale = Locale(identifier: "en")

    @Test func inventoryPreservesOrderDescriptionsAndAvailability() throws {
        let input = input(
            .object([
                "skills": .array([
                    .object(["name": .string("z"), "description": .string("Last"), "enabled": .bool(false)]),
                    .object([
                        "name": .string("a"), "description": .string("First"), "enabled": .bool(true),
                        "read_only": .bool(true),
                    ]),
                ])
            ]))
        guard case .list(let list) = try #require(SkillsListTool.present(input).first) else {
            Issue.record("Expected a skill list")
            return
        }
        #expect(list.rows.map(\.title) == ["z", "a"])
        #expect(list.rows.map(\.subtitle) == ["Last", "First"])
        #expect(list.rows.map(\.badges) == [["Disabled"], ["Enabled", "Read-only"]])
    }

    @Test func readHandlesFileListsBinaryResourcesAndTextWindows() {
        let files = SkillReadFileTool.present(
            input(.object(["files": .array([.string("SKILL.md"), .string("a.bin")])])))
        #expect(text(files).contains("a.bin"))
        let binary = SkillReadFileTool.present(
            input(.object(["path": .string("a.bin"), "bytes": .number(4), "binary": .bool(true)])))
        #expect(text(binary).contains("Binary resource"))
        let window = SkillReadFileTool.present(
            input(
                .object([
                    "path": .string("ref.md"), "content": .string("one\ntwo"), "offset": .number(4),
                    "total_lines": .number(10), "next_offset": .number(6),
                ])))
        #expect(text(window).contains("4–5"))
        #expect(text(window).contains("More results"))
        #expect(text(window).contains("one\ntwo"))
        let empty = SkillReadFileTool.present(
            input(
                .object([
                    "path": .string("ref.md"), "content": .string(""), "offset": .number(11), "next_offset": .null,
                ])))
        #expect(text(empty).contains("No lines returned"))
        #expect(!text(empty).contains("More results"))
    }

    @Test func anEmptyFileStillReturnsOneEmptyLine() {
        let items = SkillReadFileTool.present(
            input(
                .object([
                    "path": .string("empty.txt"), "content": .string(""), "offset": .number(1),
                    "total_lines": .number(1), "next_offset": .null,
                ])))
        #expect(text(items).contains("1–1"))
        #expect(!text(items).contains("No lines returned"))
    }

    @Test func instructionAndLegacyResultsKeepTheirEntireText() {
        let body = String(repeating: "a\n", count: 300)
        for key in ["content", "instructions"] {
            let detail = SkillReadFileTool.present(input(.object(["title": .string("Guide"), key: .string(body)])))
            #expect(detail.contains(.text(.init(title: "Guide", text: body, style: .plain))))
        }
    }

    @Test(arguments: ["create", "update", "patch", "delete", "set_enabled", "write_file", "remove_file"])
    func everySkillOperationHasReadableArguments(_ action: String) {
        let args: [String: AgentJSONValue] = [
            "operations": .array([
                .object([
                    "action": .string(action), "name": .string("my-skill"), "path": .string("ref.md"),
                    "old_text": .string("original"), "content": .string("replacement"), "enabled": .bool(false),
                ])
            ])
        ]
        let items = SkillManageTool.presentArguments(.init(arguments: args, locale: locale))
        let rendered = text(items)
        #expect(rendered.contains("my-skill"))
        #expect(rendered.contains("ref.md"))
        #expect(rendered.contains("original"))
        #expect(rendered.contains("replacement"))
        #expect(!rendered.contains("old_text"))
        if action == "patch" { #expect(rendered.contains("Replacement text")) }
    }

    @Test func approvalKeepsFullContentUnknownArgumentsAndReviewedInstallFacts() {
        let body = String(repeating: "password=visible-only-in-approval\n", count: 500)
        let items = SkillManageTool.presentArguments(
            .init(
                arguments: [
                    "operations": .array([
                        .object([
                            "action": .string("create"), "name": .string("large"), "content": .string(body),
                            "future_option": .string("keep-me"),
                        ])
                    ])
                ], locale: locale))
        #expect(items.contains(.text(.init(title: "Content", text: body, style: .monospaced))))
        #expect(text(items).contains("keep-me"))
        let installed = SkillInstallTool.presentArguments(
            .init(
                arguments: [
                    "source_url": .string("original-url"), "resolved_source": .string("resolved-url"),
                    "name": .string("renamed"), "commit": .string(String(repeating: "a", count: 40)),
                    "files": .array([.string("SKILL.md"), .string("ref.md")]), "bytes": .number(123),
                    "warnings": .array([.string("Review scripts")]),
                ], locale: locale))
        for expected in [
            "original-url", "resolved-url", "renamed", String(repeating: "a", count: 40), "ref.md", "Review scripts",
        ] {
            #expect(text(installed).contains(expected))
        }
        #expect(installed.contains(.message("Review scripts", .warning)))
    }

    @Test func successfulMutationShowsNextRunWithoutExposingProtocolFields() {
        for presenter in [SkillManageTool.presenter, SkillInstallTool.presenter] {
            let items = presenter.present(
                input(.object(["saved": .bool(true), "available": .string("next_run"), "name": .string("test")])))
            #expect(text(items).contains("Available on the next run"))
            #expect(!text(items).contains("next_run"))
        }
    }

    @Test func memoryShowsOrderedOperationsAndTheUnparsedReturnedSnapshot() {
        let snapshot = "MEMORY [7/2200 characters]\n§\nUSER PROFILE inside authored text"
        let args: [String: AgentJSONValue] = [
            "operations": .array([
                .object(["action": .string("add"), "target": .string("memory"), "content": .string("first")]),
                .object([
                    "action": .string("replace"), "target": .string("user"), "old_text": .string("old"),
                    "content": .string("second"),
                ]),
                .object(["action": .string("remove"), "target": .string("memory"), "old_text": .string("third")]),
            ])
        ]
        let items = MemoryTool.present(input(.object(["memory": .string(snapshot)]), args: args))
        let labels = items.compactMap { item -> String? in
            if case .message(let value, _) = item { return value }
            return nil
        }
        #expect(labels == ["Memory operations processed", "1. Add memory", "2. Replace memory", "3. Remove memory"])
        #expect(items.last == .text(.init(title: "Current memory", text: snapshot, style: .plain)))
        let read = MemoryTool.present(input(.object(["memory": .string(snapshot)]), args: ["operations": .array([])]))
        #expect(read == [.text(.init(title: "Current memory", text: snapshot, style: .plain))])
        let memoryTarget = MemoryTool.presentArguments(
            .init(
                arguments: [
                    "operations": .array([
                        .object(["action": .string("add"), "target": .string("memory"), "content": .string("first")])
                    ])
                ], locale: locale))
        #expect(memoryTarget.contains(.field(.init(label: "Target", value: "memory"))))
    }

    @Test func memorySearchShowsQueryInActivityAndDetails() {
        let tool = MemorySearchTool(store: PresentationMemoryAccess())
        #expect(tool.descriptor.presentation?.activity == .semanticArgument(key: "query", fallback: .memory))
        let arguments: [String: AgentJSONValue] = [
            "query": .string("服务器部署"), "target": .string("user"), "limit": .number(5),
        ]
        let argumentItems = MemorySearchTool.presenter.presentArguments(
            .init(arguments: arguments, locale: locale))
        #expect(argumentItems?.contains(.text(.init(title: "Query", text: "服务器部署", style: .plain))) == true)
        #expect(argumentItems?.contains(.field(.init(label: "Target", value: "User profile"))) == true)
        let resultItems = MemorySearchTool.presenter.present(
            input(.object(["entries": .array([]), "next_offset": .null]), args: arguments))
        #expect(resultItems.contains(.text(.init(title: "Query", text: "服务器部署", style: .plain))))
        #expect(text(resultItems).contains("User profile"))
        let memoryTarget = MemorySearchTool.presenter.presentArguments(
            .init(arguments: ["query": .string("服务器部署"), "target": .string("memory")], locale: locale))
        #expect(memoryTarget?.contains(.field(.init(label: "Target", value: "memory"))) == true)
        for (language, expected) in [("zh-Hans", "记忆"), ("zh-Hant", "記憶")] {
            let items = MemorySearchTool.presenter.presentArguments(
                .init(
                    arguments: ["query": .string("服务器部署"), "target": .string("memory")],
                    locale: Locale(identifier: language)))
            #expect(items?.contains(.field(.init(label: language == "zh-Hans" ? "目标" : "目標", value: expected))) == true)
        }
    }

    @Test func sessionResultsHideIDsButKeepMessageRolesOrderAndPagination() {
        let items = SessionSearchTool.present(
            input(
                .object([
                    "messages": .array(
                        ["user", "assistant"].map { role in
                            .object([
                                "conversation_id": .string("secret-id"), "message_id": .string("internal-id"),
                                "title": .string("My chat"), "role": .string(role), "content": .string(role + " body"),
                            ])
                        }), "next_offset": .number(2),
                ])))
        #expect(items[0] == .text(.init(title: "My chat — User", text: "user body", style: .plain)))
        #expect(items[1] == .text(.init(title: "My chat — Assistant", text: "assistant body", style: .plain)))
        #expect(!text(items).contains("secret-id"))
        #expect(!text(items).contains("internal-id"))
        #expect(text(items).contains("More results"))
    }

    @Test func sessionSearchDetailsKeepQueryAndBrowseWithoutOneIsUnchanged() {
        let result: AgentJSONValue = .object(["sessions": .array([])])
        let browse = SessionSearchTool.present(input(result))
        let search = SessionSearchTool.present(input(result, args: ["query": .string("服务器 部署")]))
        #expect(search.first == .text(.init(title: "Query", text: "服务器 部署", style: .plain)))
        #expect(Array(search.dropFirst()) == browse)
    }

    @Test func emptyListsAndMalformedResultsNeverDisappearOrClaimSuccess() {
        for (presenter, key) in [
            (SkillsListTool.presenter, "skills"), (SessionSearchTool.presenter, "sessions"),
            (SessionSearchTool.presenter, "messages"),
        ] {
            #expect(!text(presenter.present(input(.object([key: .array([])])))).isEmpty)
        }
        for presenter in [
            SkillsListTool.presenter, SkillReadFileTool.presenter, SkillManageTool.presenter,
            SkillInstallTool.presenter, MemoryTool.presenter, SessionSearchTool.presenter,
        ] {
            for value in [AgentJSONValue.object(["error": .string("Failed safely")]), .array([.string("Unexpected")])] {
                let items = presenter.present(input(value))
                #expect(!items.isEmpty)
                #expect(
                    !items.contains {
                        if case .message(_, .success) = $0 { return true }
                        return false
                    })
            }
        }
    }

    @Test(arguments: ["zh-Hans", "zh-Hant"])
    func chineseKnowledgeLabelsResolveInThePackage(_ language: String) {
        let items = MemoryTool.present(
            .init(
                result: .object(["memory": .string("original")]), arguments: [:], locale: Locale(identifier: language)))
        #expect(text(items).contains(language == "zh-Hans" ? "当前记忆" : "目前記憶"))
        #expect(text(items).contains("original"))
    }

    private func input(_ result: AgentJSONValue, args: [String: AgentJSONValue] = [:]) -> AgentToolDetailInput {
        .init(result: result, arguments: args, locale: locale)
    }

    private func text(_ items: [AgentToolDetail.Item]) -> String {
        items.map { item in
            switch item {
            case .field(let value): return value.label + " " + value.value
            case .message(let text, _): return text
            case .text(let value): return (value.title ?? "") + " " + value.text
            case .list(let list):
                return (list.title ?? "") + (list.emptyMessage ?? "")
                    + list.rows.map { $0.title + ($0.subtitle ?? "") + $0.badges.joined() }.joined()
            case .groupedList(let list): return list.summary
            }
        }.joined(separator: "\n")
    }
}

private struct PresentationMemoryAccess: AgentMemoryAccessing {
    func memoryState() async throws -> AgentMemoryState { .init() }
    func applyMemory(_ operations: [AgentMemoryOperation]) async throws -> AgentMemoryState { .init() }
    func searchSessions(_ request: AgentSessionSearchRequest) async throws -> AgentJSONValue { .array([]) }
}
