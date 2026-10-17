import Foundation

extension AgentScratchWorkspace {
    /// Reuses one actor for every run and tool in an application.
    public nonisolated static func shared(applicationName: String = "Agent") -> AgentScratchWorkspace {
        workspaces.get(applicationName)
    }

    private nonisolated static let workspaces = SharedWorkspaces()
}

private final class SharedWorkspaces: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: AgentScratchWorkspace] = [:]

    func get(_ name: String) -> AgentScratchWorkspace {
        lock.withLock {
            if let existing = values[name] { return existing }
            let workspace = AgentScratchWorkspace(applicationName: name)
            values[name] = workspace
            return workspace
        }
    }
}
