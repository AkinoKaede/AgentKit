import Foundation

/// Plan mode, as a loop hook.
///
/// A hook rather than a fourth `AgentPermissionMode` because the two answer
/// different questions and compose: permission mode decides *who authorizes* an
/// action, plan mode decides *whether the action is on the table at all*. Hooks
/// run before authorization ([AgentLoopHook]), so this can only ever tighten —
/// there is no arrangement of it that routes a call past
/// `AgentApprovalHandling`.
///
/// A plain value, not an actor. A run's posture is fixed when it starts:
/// `present_plan` ends the turn rather than flipping a flag inside it, and
/// implementing a plan is a new run. Nothing here mutates.
public nonisolated struct AgentPlanModeHook: AgentLoopHook {
    public init(
        isPlanning: Bool,
        blockedToolNames: Set<String> = Self.blockedByName
    ) {
        self.isPlanning = isPlanning
        self.blockedToolNames = blockedToolNames
    }

    public let isPlanning: Bool

    /// Tools refused by name rather than by safety.
    ///
    /// `manage_tasks` is `.locallyReadOnly` — it changes nothing, so the safety
    /// gate has no reason to stop it — and it still has no business running
    /// here. `pi-plan-mode` blocks Pi's `update_plan` during planning "because
    /// it tracks execution progress rather than conversational planning", and
    /// the same holds: nothing is executing yet, so a task list would be a
    /// checklist of things that have not started, sitting beside a plan that has
    /// not been agreed to.
    public var blockedToolNames: Set<String> = Self.blockedByName

    /// A host's own judgement about one call, asked before the safety gate.
    ///
    /// `nil` falls through to the ordinary rules; a decision replaces them. This
    /// is where "which of *my* tools deserve a finer answer than their declared
    /// safety" lives — a host with a shell tool reads its command with
    /// `CommandRiskClassifier` here, because whether a command may run while
    /// planning is a property of the command and only its owner can say.
    ///
    /// It can refuse a call the ordinary rules would allow, and allow one they
    /// would refuse. That is deliberate and is not a hole: plan mode is a
    /// posture, and hooks run before `AgentApprovalHandling`, so anything
    /// returned `.proceed` here still meets the approval gate it would have met
    /// anyway.
    public var hostDecision: @Sendable (AgentToolCallContext) async -> AgentToolCallDecision? = { _ in
        nil
    }

    public static let blockedByName: Set<String> = ["manage_tasks"]

    /// Named here rather than matched as a string at the call sites that care.
    public static let presentPlanToolName = "present_plan"

    public func willExecute(_ context: AgentToolCallContext) async -> AgentToolCallDecision {
        guard isPlanning else { return .proceed }

        let name = context.invocation.call.name
        if blockedToolNames.contains(name) {
            return .block(
                reason: String(
                    localized: """
                        \(name) is unavailable while planning: nothing has been agreed to yet, so \
                        there is no work to track. Finish the plan and call present_plan.
                        """
                ))
        }

        if let decision = await hostDecision(context) { return decision }

        // `context.descriptor` is post-preflight, so the rest rides evidence the
        // pipeline already proved locally rather than anything the model or a
        // remote server asserted. `scratch_write` and `scratch_edit` are
        // contained; a remote write, a private-network `fetch`, and every MCP
        // tool are not.
        guard !context.descriptor.safety.isAllowedWhilePlanning else { return .proceed }
        return .block(
            reason: String(
                localized: """
                    Plan mode is on, so \(name) was not run — it changes something outside this \
                    app. Investigate with reads, draft the plan in the scratch workspace, and \
                    call present_plan. The user runs it, or not, from there.
                    """
            ))
    }

    /// Ends the run on the turn that presented a plan.
    ///
    /// `pi-plan-mode`'s `terminate: true`, through the seam this codebase
    /// already has. `shouldStop` stops *after* the turn completes rather than
    /// abandoning it, so every call in the batch is still answered and the
    /// transcript stays replayable.
    ///
    /// Not conditional on `isPlanning`: a plan presented outside plan mode is a
    /// plan the user still has to answer, and continuing past it would act on
    /// something nobody agreed to.
    public func shouldStop(after summary: AgentTurnSummary) async -> Bool {
        summary.message.toolCalls.contains { $0.name == Self.presentPlanToolName }
    }
}

/// The instructions a planning run is given, injected at the model boundary.
///
/// A message rather than a different system prompt, following `pi-plan-mode`
/// ("one hidden, model-visible, versioned Plan contract before the first Plan
/// prompt"). The reason is the one `AgentSessionContextInjection` already
/// documents: every provider cache is a *prefix* cache, so a system prompt that
/// changed with the mode would miss the whole replayed conversation on every
/// toggle. `AgentSystemPrompt.default` stays byte-identical for every run.
public nonisolated struct AgentPlanContractInjection: AgentContextTransforming {
    public init(
        isPlanning: Bool,
        before: AgentTranscriptMessage.ID? = nil,
        contract: String = AgentPlanContractInjection.contract
    ) {
        self.isPlanning = isPlanning
        self.before = before
        self.contract = contract
    }

    public var isPlanning: Bool
    /// The turn this sits in front of, by identity rather than index — the
    /// transforms ahead of this one are free to add and remove messages.
    public var before: AgentTranscriptMessage.ID?
    /// What planning means for *these* tools.
    ///
    /// A property rather than a constant because the honest version of this text
    /// names the tools the run actually has: an app whose agent reaches servers
    /// owes the model a sentence about commands, and one whose agent reaches
    /// nothing but the scratch workspace would be lying if it repeated it. The
    /// default is the part that is true of the built-in tools alone.
    public var contract: String = AgentPlanContractInjection.contract

    public func transform(_ context: AgentModelContext) -> AgentModelContext {
        guard isPlanning, let before,
            let index = context.messages.firstIndex(where: { $0.id == before })
        else { return context }
        var result = context
        result.messages.insert(
            AgentTranscriptMessage(role: .user, text: contract), at: index
        )
        return result
    }

    public static let contract = """
        Plan mode is on for this turn. You are designing a change, not making one.

        Investigate freely. Reads are unrestricted: fetch and search work, and so does anything \
        else that only looks.

        What is refused is changing anything outside this app, and every MCP tool. Do not \
        attempt those, and never describe an action as taken — you have taken none.

        Draft the plan in the scratch workspace with scratch_write, and revise it there with \
        scratch_edit rather than rewriting it. That way a revision costs a diff instead of \
        another copy of the document.

        When a choice is genuinely the user's — which of two approaches to take, a tradeoff \
        with no defensible default — ask with request_user_input, giving real options and \
        saying what each one costs. Resolve those before you finish, not after: a plan built \
        on a guess is one they have to unpick. Decide anything the conversation or an obvious \
        convention already answers, and say which assumption you used.

        When the approach is settled, call present_plan with the scratch path, on its own and \
        as the last thing you do. The run ends there and the user decides whether to \
        implement it.
        """
}
