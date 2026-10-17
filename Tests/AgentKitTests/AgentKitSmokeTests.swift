import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentKitSmokeTests {
    static let scratchNames: Set<String> = [
        "scratch_list", "scratch_read", "scratch_search", "scratch_write", "scratch_replace",
        "scratch_copy", "scratch_move", "scratch_diff", "scratch_delete",
    ]
    /// Mandatory scratch does not depend on optional service selection.
    @Test
    func missingOptionalDependenciesStillLeaveMandatoryScratch() {
        let names = Set(
            AgentToolCatalog.registry(builtIn: .init()).descriptors.map(\.name)
        )
        #expect(names == Set(["request_user_input", "request_user_secret"]).union(Self.scratchNames))

        let none = AgentToolCatalog.registry(
            builtIn: .init(groups: [.web, .scratch, .planning, .tasks, .skills])
        )
        #expect(Set(none.descriptors.map(\.name)) == Self.scratchNames)
    }

    @Test
    func scratchFetchUsesMandatoryScratchWhenWebIsAvailable() throws {
        let workspace = AgentScratchWorkspace(
            conversationID: UUID(), base: FileManager.default.temporaryDirectory
        )
        let web = StubWebClient()

        func names(_ groups: Set<AgentToolGroup>) -> Set<String> {
            Set(
                AgentToolCatalog.registry(
                    builtIn: .init(groups: groups, workspace: workspace, web: web)
                ).descriptors.map(\.name)
            )
        }

        #expect(names([.web]).contains("scratch_fetch"))
        #expect(names([.web]).contains("fetch"))
        #expect(!names([.scratch]).contains("scratch_fetch"))
        #expect(names([.scratch, .web]).contains("scratch_fetch"))
    }

    @Test
    func networkFetchesRequireApprovalWhileSearchIsPreapproved() {
        let workspace = AgentScratchWorkspace(
            conversationID: UUID(), base: FileManager.default.temporaryDirectory
        )
        let web = StubWebClient()
        let descriptors = AgentToolCatalog.registry(
            builtIn: .init(
                groups: [.scratch, .web], workspace: workspace,
                web: web, search: web
            )
        ).descriptors

        for name in ["fetch", "scratch_fetch"] {
            #expect(descriptors.first { $0.name == name }?.approvalPolicy == .ask, "\(name)")
        }
        #expect(descriptors.first { $0.name == "web_search" }?.approvalPolicy == .approve)
    }
}

private struct StubWebClient: AgentWebFetching, AgentWebSearching {
    func document(for rawURL: String) async throws -> AgentWebDocument {
        throw AgentWebError.emptyDocument
    }

    func search(_ query: String, count: Int) async throws -> [AgentWebDocument] {
        []
    }
}
