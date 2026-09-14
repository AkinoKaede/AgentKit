import CryptoKit
import Foundation

/// The model-facing context captured when a user message was submitted.
/// Nil fields are explicit absence; a nil snapshot means legacy, unknown context.
public nonisolated struct AgentTurnContextSnapshot: Hashable, Sendable, Codable {
    public var sessionContext: String?
    public var skillCatalog: String?
    public var planContract: String?
    public var toolAvailability: [String: Bool]?

    public init(
        sessionContext: String? = nil, skillCatalog: String? = nil, planContract: String? = nil,
        toolAvailability: [String: Bool]? = nil
    ) {
        self.sessionContext = Self.cleaned(sessionContext)
        self.skillCatalog = Self.cleaned(skillCatalog)
        self.planContract = Self.cleaned(planContract)
        self.toolAvailability = toolAvailability
    }

    public func withSessionContext(_ text: String?) -> Self {
        Self(
            sessionContext: text, skillCatalog: skillCatalog, planContract: planContract,
            toolAvailability: toolAvailability)
    }

    public var characterCount: Int {
        modelDescription.count
    }

    /// Complete context for summaries and estimates, including cleared values.
    public var modelDescription: String { changes(from: nil).joined(separator: "\n") }

    private static func cleaned(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AgentSensitiveDataRedactor.visibleText(text)
    }

    func changes(from previous: Self?) -> [String] {
        var blocks: [String] = []
        if previous == nil || sessionContext != previous?.sessionContext {
            blocks.append(sessionContext ?? "Session context: no active session is associated with this user message.")
        }
        if previous == nil || skillCatalog != previous?.skillCatalog {
            blocks.append(skillCatalog ?? "No skills are enabled for this run.")
        }
        if previous == nil || planContract != previous?.planContract {
            blocks.append(
                planContract
                    ?? "Plan mode is off for this run. Follow the user's request and the tool approval policies.")
        }
        if toolAvailability != previous?.toolAvailability {
            let entries = (toolAvailability ?? [:]).keys.sorted().map {
                "\($0): \(toolAvailability?[$0] == true ? "available" : "unavailable")"
            }
            blocks.append(
                entries.isEmpty
                    ? "No surface-specific tool restrictions apply to this user message."
                    : "Surface tool availability for this user message:\n" + entries.joined(separator: "\n"))
        }
        return blocks
    }
}

/// Replays immutable context transitions at their original user-message boundaries.
/// Compaction naturally establishes a new baseline at the first retained snapshot.
public nonisolated struct AgentContextSnapshotReplay: AgentContextTransforming {
    public init() {}

    public func transform(_ context: AgentModelContext) -> AgentModelContext {
        var result = context
        var previous: AgentTurnContextSnapshot?
        result.messages = context.messages.flatMap { message -> [AgentTranscriptMessage] in
            var projected = message
            projected.text = message.modelText ?? message.text
            guard message.role == .user, !message.isCompaction, let snapshot = message.contextSnapshot else {
                return [projected]
            }
            let blocks = snapshot.changes(from: previous)
            previous = snapshot
            return blocks.enumerated().map { index, text in
                let digest = SHA256.hash(data: Data("\(message.id):context:\(index)".utf8))
                let bytes = Array(digest.prefix(16))
                let id = bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
                return AgentTranscriptMessage(id: id, role: .user, text: text, createdAt: message.createdAt)
            } + [projected]
        }
        return result
    }
}

/// Compatibility for callers that construct a pipeline without using AgentRuntime.
public nonisolated struct AgentContextSnapshotCapture: AgentContextTransforming {
    public var snapshot: AgentTurnContextSnapshot
    public var promptID: UUID?

    public init(snapshot: AgentTurnContextSnapshot, promptID: UUID?) {
        self.snapshot = snapshot
        self.promptID = promptID
    }

    public func transform(_ context: AgentModelContext) -> AgentModelContext {
        var result = context
        if let index = result.messages.firstIndex(where: { $0.id == promptID }),
            result.messages[index].contextSnapshot == nil
        {
            result.messages[index].contextSnapshot = snapshot
        }
        return result
    }
}

nonisolated extension AgentTranscriptMessage {
    /// The runtime, event consumer, and crash recovery must agree on result identity.
    public static func toolResultID(runID: UUID, callID: String) -> UUID {
        let digest = SHA256.hash(data: Data("tool-result:\(runID):\(callID)".utf8))
        return Array(digest.prefix(16)).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}
