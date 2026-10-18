import Foundation

/// Argument-dependent semantics resolved by trusted local tool code, never persisted executable metadata.
/// Hosts own sentence construction, lifecycle wording, and display limits.
public nonisolated struct AgentToolOperation: Sendable {
    public var action: AgentToolDescriptor.Presentation.ActionKind
    public var activity: AgentToolDescriptor.Presentation.ActivityKind
    public var batchActivity: AgentToolDescriptor.Presentation.ActivityKind
    public var argument: String?
    public var operationCount: Int?
    public var searchScope: AgentToolDescriptor.Presentation.ActivityKind?

    public init(
        action: AgentToolDescriptor.Presentation.ActionKind,
        activity: AgentToolDescriptor.Presentation.ActivityKind,
        batchActivity: AgentToolDescriptor.Presentation.ActivityKind? = nil,
        argument: String? = nil, operationCount: Int? = nil,
        searchScope: AgentToolDescriptor.Presentation.ActivityKind? = nil
    ) {
        self.action = action
        self.activity = activity
        self.batchActivity = batchActivity ?? activity
        self.argument = argument
        self.operationCount = operationCount
        self.searchScope = searchScope
    }
}
