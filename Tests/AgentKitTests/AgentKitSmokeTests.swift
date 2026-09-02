import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentKitSmokeTests {
    /// A group whose dependency is missing contributes nothing. `.userInteraction`
    /// is the exception and stays: its handler comes from the run rather than
    /// from this configuration, so there is nothing for it to be missing.
    @Test
    func groupsWithoutTheirDependenciesRegisterNothing() {
        let names = Set(
            AgentToolCatalog.registry(builtIn: .init()).descriptors.map(\.name)
        )
        #expect(names == ["request_user_input", "request_user_secret"])

        let none = AgentToolCatalog.registry(
            builtIn: .init(groups: [.web, .scratch, .planning, .tasks, .skills])
        )
        #expect(none.descriptors.isEmpty)
    }

    /// `scratch_fetch` spans two groups, and needs both. Taking `.web` alone
    /// would otherwise hand the model a tool that writes files nothing in the
    /// run can read back.
    @Test
    func scratchFetchNeedsBothItsGroups() throws {
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

        #expect(!names([.web]).contains("scratch_fetch"))
        #expect(names([.web]).contains("fetch"))
        #expect(!names([.scratch]).contains("scratch_fetch"))
        #expect(names([.scratch, .web]).contains("scratch_fetch"))
    }
}

private struct StubWebClient: AgentWebFetching {
    func document(for rawURL: String) async throws -> AgentWebDocument {
        throw AgentWebError.emptyDocument
    }
}
