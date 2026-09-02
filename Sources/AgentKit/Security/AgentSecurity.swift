import Foundation

public nonisolated struct AgentApprovalRequest: Identifiable, Hashable, Sendable {
    public init(
        id: UUID = UUID(),
        invocation: AgentToolInvocation,
        descriptor: AgentToolDescriptor,
        userIntent: String,
        localReasons: [String] = []
    ) {
        self.id = id
        self.invocation = invocation
        self.descriptor = descriptor
        self.userIntent = userIntent
        self.localReasons = localReasons
    }

    public var id: UUID = UUID()
    public var invocation: AgentToolInvocation
    public var descriptor: AgentToolDescriptor
    public var userIntent: String
    public var localReasons: [String] = []
}

public nonisolated enum AgentApprovalDecision: Hashable, Sendable {
    case allow
    case deny(String)
}

public nonisolated enum SecurityReviewRisk: String, Hashable, Sendable, Codable {
    case low, medium, high, critical

    public var displayName: String {
        switch self {
        case .low: String(localized: "Low", bundle: .module)
        case .medium: String(localized: "Medium", bundle: .module)
        case .high: String(localized: "High", bundle: .module)
        case .critical: String(localized: "Critical", bundle: .module)
        }
    }
}

public nonisolated enum SecurityReviewVerdict: String, Hashable, Sendable, Codable {
    case approve, deny
}

public nonisolated enum SecurityReviewAuthorization: String, Hashable, Sendable, Codable {
    case sufficient, insufficient
}

public nonisolated struct SecurityReviewDecision: Hashable, Sendable, Codable {
    public init(
        verdict: SecurityReviewVerdict,
        risk: SecurityReviewRisk,
        userAuthorization: SecurityReviewAuthorization,
        reason: String
    ) {
        self.verdict = verdict
        self.risk = risk
        self.userAuthorization = userAuthorization
        self.reason = reason
    }

    public var verdict: SecurityReviewVerdict
    public var risk: SecurityReviewRisk
    public var userAuthorization: SecurityReviewAuthorization
    public var reason: String

    public var allowsExecution: Bool {
        guard verdict == .approve, risk != .critical else { return false }
        return risk != .high || userAuthorization == .sufficient
    }
}

public nonisolated protocol SecurityReviewing: Sendable {
    func review(_ request: AgentApprovalRequest) async throws -> SecurityReviewDecision
}

public nonisolated protocol AgentApprovalHandling: Sendable {
    func authorize(
        _ request: AgentApprovalRequest,
        mode: AgentPermissionMode
    ) async -> AgentApprovalDecision
}

/// Implements the three permission modes. Reviewer failures are deliberately
/// fail-closed, matching Codex Auto-review rather than silently becoming approval.
public actor AgentApprovalBroker: AgentApprovalHandling {
    public typealias ManualApproval = @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision

    private let reviewer: (any SecurityReviewing)?
    private let manualApproval: ManualApproval
    private let event: @Sendable (AgentEvent) -> Void
    private let reviewTimeout: Duration

    public init(
        reviewer: (any SecurityReviewing)?,
        manualApproval: @escaping ManualApproval,
        reviewTimeout: Duration = .seconds(30),
        event: @escaping @Sendable (AgentEvent) -> Void = { _ in }
    ) {
        self.reviewer = reviewer
        self.manualApproval = manualApproval
        self.reviewTimeout = reviewTimeout
        self.event = event
    }

    public func authorize(
        _ request: AgentApprovalRequest,
        mode: AgentPermissionMode
    ) async -> AgentApprovalDecision {
        if request.descriptor.safety.isAutoAllowed { return .allow }
        if mode == .fullAccess { return .allow }

        if request.descriptor.alwaysAskUser || mode == .askForApproval {
            event(.approvalRequested(request))
            return await manualApproval(request)
        }

        guard mode == .approveForMe, let reviewer else {
            return .deny(
                String(localized: "Security Review is unavailable; the action was not executed.", bundle: .module))
        }
        event(.reviewStarted(request))
        do {
            let decision = try await reviewWithTimeout(reviewer, request: request)
            event(.reviewFinished(request, decision))
            return decision.allowsExecution ? .allow : .deny(decision.reason)
        } catch is SecurityReviewTimeoutError {
            let reason = String(localized: "Security Review timed out; the action was not executed.", bundle: .module)
            event(.reviewFailed(request, reason: reason, timedOut: true))
            return .deny(reason)
        } catch {
            let reason = String(
                localized: "Security Review failed; the action was not executed. \(error.localizedDescription)"
            )
            event(.reviewFailed(request, reason: reason, timedOut: false))
            return .deny(reason)
        }
    }

    private func reviewWithTimeout(
        _ reviewer: any SecurityReviewing,
        request: AgentApprovalRequest
    ) async throws -> SecurityReviewDecision {
        try await withThrowingTaskGroup(of: SecurityReviewDecision.self) { group in
            group.addTask { try await reviewer.review(request) }
            group.addTask { [reviewTimeout] in
                try await Task.sleep(for: reviewTimeout)
                throw SecurityReviewTimeoutError()
            }
            guard let first = try await group.next() else { throw SecurityReviewTimeoutError() }
            group.cancelAll()
            return first
        }
    }
}

private nonisolated struct SecurityReviewTimeoutError: Error, Sendable {}

public nonisolated struct SecretBinding: Hashable, Sendable {
    public init(
        runID: UUID,
        toolName: String,
        hostID: UUID? = nil,
        purpose: String
    ) {
        self.runID = runID
        self.toolName = toolName
        self.hostID = hostID
        self.purpose = purpose
    }

    public var runID: UUID
    public var toolName: String
    public var hostID: UUID?
    public var purpose: String
}

public nonisolated struct SecretHandle: Identifiable, Hashable, Sendable, Codable {
    public init(
        id: UUID
    ) {
        self.id = id
    }

    public var id: UUID
}

public nonisolated enum SecretBrokerError: LocalizedError, Sendable, Equatable {
    case notFound, bindingMismatch

    public var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "The secret is unavailable or has already been used.", bundle: .module)
        case .bindingMismatch:
            String(localized: "The secret is not valid for this host, tool, or purpose.", bundle: .module)
        }
    }
}

/// Plaintext exists only in this actor and in the executor call that consumes it.
/// A failed binding check does not consume the handle; a successful read always does.
public actor SecretBroker {
    public init() {}

    private struct Entry {
        var secret: String
        var binding: SecretBinding
    }
    private var entries: [SecretHandle.ID: Entry] = [:]

    public func issue(_ secret: String, binding: SecretBinding) -> SecretHandle {
        let handle = SecretHandle(id: UUID())
        entries[handle.id] = Entry(secret: secret, binding: binding)
        return handle
    }

    public func consume(_ handle: SecretHandle, matching binding: SecretBinding) throws -> String {
        guard let entry = entries[handle.id] else { throw SecretBrokerError.notFound }
        guard entry.binding == binding else { throw SecretBrokerError.bindingMismatch }
        entries[handle.id] = nil
        return entry.secret
    }

    public func discardSecrets(for runID: UUID) {
        entries = entries.filter { $0.value.binding.runID != runID }
    }

    public func discardAll() { entries.removeAll() }

    public var count: Int { entries.count }
}

/// One choice offered by `request_user_input`.
///
/// A bare string used to be the whole option, which left the model nowhere to
/// put the tradeoff: it either crammed it into the label or lost it, and the
/// reader was left choosing between four words with no way to tell them apart.
public nonisolated struct AgentUserInputOption: Identifiable, Hashable, Sendable {
    public init(
        id: String,
        label: String,
        detail: String = "",
        isRecommended: Bool = false
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isRecommended = isRecommended
    }

    public var id: String
    public var label: String
    /// One sentence on what this choice means or costs. Optional, and the
    /// reason this type exists.
    public var detail: String = ""
    /// Advisory only. It marks the model's recommendation; it never preselects,
    /// because a preselected answer is one the user can submit without reading.
    public var isRecommended: Bool = false
}

public nonisolated struct AgentUserInputChoice: Hashable, Sendable {
    public init(
        options: [AgentUserInputOption],
        allowsCustomAnswer: Bool = true,
        allowsMultipleAnswers: Bool = false,
        customPlaceholder: String = ""
    ) {
        self.options = options
        self.allowsCustomAnswer = allowsCustomAnswer
        self.allowsMultipleAnswers = allowsMultipleAnswers
        self.customPlaceholder = customPlaceholder
    }

    public var options: [AgentUserInputOption]
    /// Whether the user may answer with something the model did not think of.
    ///
    /// Defaults to true, and that default is the whole point: an agent that
    /// offers four wrong answers and no fifth field leaves Cancel as the only
    /// honest response, and a cancelled run tells it nothing about why.
    public var allowsCustomAnswer: Bool = true
    public var allowsMultipleAnswers: Bool = false
    public var customPlaceholder: String = ""
}

public nonisolated enum AgentUserInputLimits {
    /// Codex's ceiling, and for the same reason: past three, a form stops being
    /// a decision and starts being a questionnaire.
    public static let maxQuestions = 3
    public static let minimumTimeoutSeconds = 1
    public static let maximumTimeoutSeconds = 30 * 60
    public static let defaultTimeoutSeconds = 5 * 60
}

/// One thing the agent needs decided.
public nonisolated struct AgentUserQuestion: Identifiable, Hashable, Sendable {
    public init(
        id: String,
        header: String = "",
        prompt: String,
        kind: Kind
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.kind = kind
    }

    public nonisolated enum Kind: Hashable, Sendable {
        case text
        case choice(AgentUserInputChoice)
        case secret
    }

    /// Named by the model, unique within its request. It wrote the questions
    /// and it reads the answers back by these names, so they are its own
    /// vocabulary rather than an index we assign.
    public var id: String
    /// Short label naming the decision, shown above the prompt.
    public var header: String = ""
    public var prompt: String
    public var kind: Kind

    /// The choices this question offers, or none for a free-form one. Saves
    /// every reader of a question from re-matching on `kind` to find out.
    public var options: [AgentUserInputOption] {
        guard case .choice(let choice) = kind else { return [] }
        return choice.options
    }
}

/// A set of questions put to the user at once.
///
/// Several rather than one because a group of decisions is usually a group —
/// asking about storage, then about migrations only once storage is answered,
/// hides the second question at the moment it would have informed the first.
/// The tool's calls are `.sequential`, so asking twice in a turn already meant
/// answering twice in a row; this keeps them in one navigable request instead.
public nonisolated struct AgentUserInputRequest: Identifiable, Hashable, Sendable {
    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        questions: [AgentUserQuestion],
        purpose: String = "",
        hostID: UUID? = nil,
        timeout: Duration = .seconds(AgentUserInputLimits.defaultTimeoutSeconds)
    ) {
        self.id = id
        self.createdAt = createdAt
        self.questions = questions
        self.purpose = purpose
        self.hostID = hostID
        self.timeout = timeout
    }

    public var id: UUID = UUID()
    public var createdAt: Date = .now
    public var questions: [AgentUserQuestion]
    public var purpose: String = ""
    public var hostID: UUID?
    /// Starts when this request reaches the head of its presentation queue.
    /// Time spent behind another prompt does not consume this duration.
    public var timeout: Duration = .seconds(AgentUserInputLimits.defaultTimeoutSeconds)
}

/// What has been filled into one question so far.
public nonisolated struct AgentUserInputDraft: Hashable, Sendable {
    public init(
        text: String = "",
        selection: Set<String> = []
    ) {
        self.text = text
        self.selection = selection
    }

    /// The "something else" field, and the whole answer for a free-form
    /// question.
    public var text = ""
    public var selection: Set<String> = []

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public nonisolated struct AgentUserInputAnswer: Hashable, Sendable {
    public init(
        questionID: String,
        value: Value
    ) {
        self.questionID = questionID
        self.value = value
    }

    public nonisolated enum Value: Hashable, Sendable {
        case text(String)
        /// Selected option ids in the order the question listed them, plus
        /// whatever the user typed instead of — or, when several answers are
        /// allowed, alongside — them. Kept structured rather than flattened to
        /// a string so the tool can hand the model ids it chose itself.
        case choice(selectedIDs: [String], custom: String?)
        case secret(String)
    }

    public var questionID: String
    public var value: Value
}

public nonisolated enum AgentUserInputResponse: Hashable, Sendable {
    /// Only the questions the user actually answered.
    ///
    /// An absent question was skipped, and skipping is itself an answer — the
    /// user declining to decide that one. So there is no `.skipped` case: the
    /// absence carries it, and the tool reports it to the model as a null.
    case answered([AgentUserInputAnswer])
    case cancelled
    case timedOut
}

/// The one question the runtime itself knows how to ask.
///
/// Model-authored, and answered back into a tool result — which is what keeps it
/// here while a credential prompt does not belong here. A checkpoint a host
/// raises on its own behalf, like a credential prompt, is that app's own
/// protocol reached through `AgentToolServices`, so its request and answer types
/// never enter this one and never reach an adopter that has no hosts.
public nonisolated protocol AgentUserInteractionHandling: Sendable {
    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse
}

public nonisolated struct UnavailableAgentUserInteraction: AgentUserInteractionHandling, Sendable {
    public init() {}

    public func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse { .cancelled }
}
