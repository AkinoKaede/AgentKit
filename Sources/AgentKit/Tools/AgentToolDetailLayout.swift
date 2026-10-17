import Foundation

/// Trusted, tool-owned display policy. This never changes model output or creates captures.
/// A host resolves it with the locally registered presenter, including when replaying old cards.
public nonisolated struct AgentToolDetailLayout: Equatable, Sendable {
    public static let compact = Self(compactHeader: true, boundsApprovalHeight: true)

    public var compactHeader: Bool
    public var boundsApprovalHeight: Bool
    public var truncateStrategy: AgentTruncateStrategy

    public init(
        compactHeader: Bool = false,
        boundsApprovalHeight: Bool = false,
        truncateStrategy: AgentTruncateStrategy = .head
    ) {
        self.compactHeader = compactHeader
        self.boundsApprovalHeight = boundsApprovalHeight
        self.truncateStrategy = truncateStrategy
    }
}
