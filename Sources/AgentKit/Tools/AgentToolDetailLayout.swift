import Foundation

/// Trusted, tool-owned display policy. This never changes model output or creates captures.
/// A host resolves it with the locally registered presenter, including when replaying old cards.
public nonisolated struct AgentToolDetailLayout: Equatable, Sendable {
    public static let compact = Self(singleLineHeader: true, boundsApprovalHeight: true)

    public var singleLineHeader: Bool
    public var boundsApprovalHeight: Bool
    public var truncateStrategy: AgentTruncateStrategy

    public init(
        singleLineHeader: Bool = false,
        boundsApprovalHeight: Bool = false,
        truncateStrategy: AgentTruncateStrategy = .head
    ) {
        self.singleLineHeader = singleLineHeader
        self.boundsApprovalHeight = boundsApprovalHeight
        self.truncateStrategy = truncateStrategy
    }
}
