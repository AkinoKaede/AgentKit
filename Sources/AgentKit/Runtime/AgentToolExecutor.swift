import Foundation

/// One tool call that has been checked and is ready to run — or that already
/// failed before it could.
///
/// Planning is separated from execution because the batch cannot be scheduled
/// until every call in it has been preflighted: a tool may decide there that
/// this particular call may not run beside anything else, so the concurrency of
/// the batch is not known until then.
public nonisolated enum AgentPlannedToolCall: Sendable {
    case ready(Ready)
    case rejected(invocation: AgentToolInvocation, result: AgentToolResult)

    public nonisolated struct Ready: Sendable {
        public init(
            tool: AnyAgentTool,
            invocation: AgentToolInvocation,
            descriptor: AgentToolDescriptor,
            reasons: [String],
            executionMetadata: [String: AgentJSONValue]
        ) {
            self.tool = tool
            self.invocation = invocation
            self.descriptor = descriptor
            self.reasons = reasons
            self.executionMetadata = executionMetadata
        }

        public var tool: AnyAgentTool
        public var invocation: AgentToolInvocation
        /// Post-preflight, so this is the descriptor the approval gate, the
        /// card, and the hooks all see.
        public var descriptor: AgentToolDescriptor
        public var reasons: [String]
        public var executionMetadata: [String: AgentJSONValue]
    }

    /// The outcome a call already has. A planned call has none yet; the error a
    /// rejected one carries is final.
    public var result: AgentToolResult {
        switch self {
        case .ready(let ready):
            AgentToolResult(
                callID: ready.invocation.call.id,
                content: String(localized: "The tool call did not produce a result.", bundle: .module),
                isError: true
            )
        case .rejected(_, let result):
            result
        }
    }

    public var concurrency: AgentToolDescriptor.Concurrency {
        switch self {
        case .ready(let ready): ready.descriptor.concurrency
        // A rejected call runs nothing, so it can conflict with nothing.
        // Calling it parallel keeps one malformed argument list from
        // serializing the whole turn around it.
        case .rejected: .parallel
        }
    }
}

/// Open for as long as one `execute` call is running.
///
/// Pi's rule, and its words: a progress callback "is scoped to the current
/// `execute()` invocation. Calls made after the tool promise settles are
/// ignored." It matters here because a tool may hand its work on — leaving a
/// long-running job in someone else's hands and returning — and without this the
/// finished call's card would go on rewriting itself with output belonging to
/// whoever took that job over.
public nonisolated final class AgentToolProgressGate: @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var isOpen = true

    public func close() { lock.withLock { isOpen = false } }

    public func forward(_ report: @escaping @Sendable (AgentToolResult) -> Void)
        -> @Sendable (AgentToolResult) -> Void
    {
        { [self] partial in
            guard lock.withLock({ isOpen }) else { return }
            report(partial)
        }
    }
}

/// What a call whose wait was cut short says to the model.
///
/// Shared by the two ways that happens — the user pressing Stop, and a steered
/// message ending the batch early — because the honest thing to say is the same
/// in both. It must not say the tool did not run: cancelling a call abandons
/// the channel it was waiting on, it does not undo what was already dispatched,
/// and a model told "this never ran" will happily run it again. See
/// `AgentUnansweredToolCallRepair`, which says the same thing about a process
/// that died.
public nonisolated enum AgentInterruptedToolCall {
    public static let reason = String(
        localized: """
            The app stopped waiting for this tool before it finished. Whether the action \
            completed is unknown; check the current state before doing it again.
            """
    )
}

/// Runs a single tool call through every gate, in a fixed order.
///
/// The order is the contract: structural validation, then locally-proven facts,
/// then the card, then hooks, then authorization, then the tool. Nothing the
/// model or a remote server said can move a step earlier, and `willExecute`
/// deliberately sits *before* authorization so a hook can stop a call but never
/// smuggle one past the gate.
public nonisolated struct AgentToolExecutor: Sendable {
    public let tools: AgentToolRegistry
    public let approval: any AgentApprovalHandling
    public let hooks: AgentLoopHooks
    public let channel: AgentEventChannel
    public let secretBroker: SecretBroker
    public let userInteraction: any AgentUserInteractionHandling
    /// Passed through untouched to every call — see `AgentToolServices`.
    public var services = AgentToolServices()
    public let runID: UUID
    public let permissionMode: AgentPermissionMode
    public let userIntent: String
    /// Not behind the progress gate and not scoped to one call: a tool asks
    /// this whenever it is about to wait a long time on purpose.
    public var interjection: @Sendable () async -> Void = {}

    public init(
        tools: AgentToolRegistry,
        approval: any AgentApprovalHandling,
        hooks: AgentLoopHooks,
        channel: AgentEventChannel,
        secretBroker: SecretBroker,
        userInteraction: any AgentUserInteractionHandling,
        services: AgentToolServices = AgentToolServices(),
        runID: UUID,
        permissionMode: AgentPermissionMode,
        userIntent: String,
        interjection: @escaping @Sendable () async -> Void = {}
    ) {
        self.tools = tools
        self.approval = approval
        self.hooks = hooks
        self.channel = channel
        self.secretBroker = secretBroker
        self.userInteraction = userInteraction
        self.services = services
        self.runID = runID
        self.permissionMode = permissionMode
        self.userIntent = userIntent
        self.interjection = interjection
    }

    public func plan(
        _ call: AgentToolCall, sourceMessageID: UUID? = nil
    ) async -> AgentPlannedToolCall {
        let proposed = AgentToolInvocation(
            runID: runID, call: call, sourceMessageID: sourceMessageID
        )
        guard let tool = tools[call.name] else {
            // Still a card. Returning silently left the transcript showing an
            // empty assistant turn and nothing else, which reads as "the model
            // said nothing" rather than "the model called a tool we do not
            // have" — the one thing the user needs to see here.
            let result = AgentToolResult(
                callID: call.id,
                content: String(localized: "Unknown tool: \(call.name)", bundle: .module),
                isError: true
            )
            channel.emit(
                .toolProposed(
                    proposed,
                    AgentToolDescriptor(
                        name: call.name,
                        summary: String(localized: "This tool is not available in this run.", bundle: .module),
                        inputSchema: .object(["type": .string("object")]),
                        target: .local, safety: .requiresAuthorization
                    )))
            channel.emit(.toolFinished(proposed, result))
            return .rejected(invocation: proposed, result: result)
        }

        let preflight: AgentToolPreflight
        do {
            try AgentJSONSchemaValidator.validate(
                call.arguments, against: tool.descriptor.inputSchema
            )
            preflight = try await tool.preflight(proposed)
        } catch {
            let result = AgentToolResult(
                callID: call.id,
                content: String(localized: "Tool input was rejected: \(error.localizedDescription)", bundle: .module),
                isError: true
            )
            channel.emit(.toolProposed(proposed, tool.descriptor))
            channel.emit(.toolFinished(proposed, result))
            return .rejected(invocation: proposed, result: result)
        }

        var descriptor = tool.descriptor
        descriptor.safety = preflight.safety
        // Only if preflight had something to say. A tool that does not override
        // keeps whatever it declared.
        if let concurrency = preflight.concurrency { descriptor.concurrency = concurrency }
        channel.emit(.toolProposed(preflight.invocation, descriptor))
        return .ready(
            AgentPlannedToolCall.Ready(
                tool: tool,
                invocation: preflight.invocation,
                descriptor: descriptor,
                reasons: preflight.reasons,
                executionMetadata: preflight.executionMetadata
            ))
    }

    public func execute(_ planned: AgentPlannedToolCall) async -> AgentToolResult {
        // A rejected call's card was raised and finished during planning;
        // re-emitting here would draw it twice.
        guard case .ready(let ready) = planned else { return planned.result }

        let hookDecision = await hooks.willExecute(
            AgentToolCallContext(
                invocation: ready.invocation, descriptor: ready.descriptor,
                userIntent: userIntent, permissionMode: permissionMode
            ))
        if case .block(let reason) = hookDecision {
            return await finish(
                ready,
                AgentToolResult(
                    callID: ready.invocation.call.id, content: reason, isError: true
                ))
        }

        let request = AgentApprovalRequest(
            invocation: ready.invocation,
            descriptor: ready.descriptor,
            userIntent: userIntent,
            localReasons: ready.reasons
        )
        switch await approval.authorize(request, mode: permissionMode) {
        case .deny(let reason):
            return await finish(
                ready,
                AgentToolResult(
                    callID: ready.invocation.call.id, content: reason, isError: true
                ))
        case .allow:
            channel.emit(.toolStarted(ready.invocation))
            let gate = AgentToolProgressGate()
            defer { gate.close() }
            do {
                let result = try await ready.tool.execute(
                    ready.invocation, context: context(for: ready, gate: gate)
                )
                return await finish(ready, result)
            } catch is CancellationError {
                // Not `localizedDescription`, which for this error is
                // "The operation couldn't be completed. (Swift.CancellationError
                // error 1.)" — a sentence about Swift, addressed to a model that
                // needs a sentence about the host. And not "it did not run"
                // either: cancelling a call abandons the channel without
                // undoing what was dispatched, so the outcome is
                // genuinely unknown. Same wording, for the same reason, as
                // `AgentUnansweredToolCallRepair`.
                return await finish(
                    ready,
                    AgentToolResult(
                        callID: ready.invocation.call.id,
                        content: AgentInterruptedToolCall.reason, isError: true,
                        metadata: ["interrupted": .bool(true)]
                    ))
            } catch {
                return await finish(
                    ready,
                    AgentToolResult(
                        callID: ready.invocation.call.id,
                        content: error.localizedDescription, isError: true
                    ))
            }
        }
    }

    /// Refuses a call outright, with a card, without planning or running it.
    ///
    /// The card matters as much as the result. A turn where the model asked for
    /// four things and three cards appeared reads as the fourth having been
    /// quietly ignored; this is what makes "the budget ran out" or "the run was
    /// cancelled" a visible outcome of a specific call.
    public func fail(
        _ call: AgentToolCall, reason: String, sourceMessageID: UUID? = nil
    ) -> AgentToolResult {
        let invocation = AgentToolInvocation(
            runID: runID, call: call, sourceMessageID: sourceMessageID
        )
        let result = AgentToolResult(callID: call.id, content: reason, isError: true)
        let descriptor =
            tools[call.name]?.descriptor
            ?? AgentToolDescriptor(
                name: call.name,
                summary: String(localized: "This tool is not available in this run.", bundle: .module),
                inputSchema: .object(["type": .string("object")]),
                target: .local, safety: .requiresAuthorization
            )
        channel.emit(.toolProposed(invocation, descriptor))
        channel.emit(.toolFinished(invocation, result))
        return result
    }

    private func context(
        for ready: AgentPlannedToolCall.Ready, gate: AgentToolProgressGate
    ) -> AgentToolExecutionContext {
        AgentToolExecutionContext(
            runID: runID,
            userIntent: userIntent,
            secretBroker: secretBroker,
            userInteraction: EventingAgentUserInteraction(
                base: userInteraction, channel: channel
            ),
            services: services,
            preflightMetadata: ready.executionMetadata,
            authorize: { [approval, permissionMode] request in
                await approval.authorize(request, mode: permissionMode)
            },
            report: gate.forward { [channel, invocation = ready.invocation] partial in
                channel.emit(.toolProgress(invocation, partial))
            },
            whenUserInterjects: interjection
        )
    }

    /// The single exit. Every result — denied, blocked, thrown, or returned —
    /// passes the `didExecute` hooks and then one `toolFinished`, so a hook can
    /// never see a subset of outcomes and the card can never be left open.
    private func finish(
        _ ready: AgentPlannedToolCall.Ready, _ result: AgentToolResult
    ) async -> AgentToolResult {
        var final = await hooks.didExecute(
            ready.invocation, descriptor: ready.descriptor, result: result
        )
        final.toolPresentation = ready.descriptor.presentation
        channel.emit(.toolFinished(ready.invocation, final))
        return final
    }
}

/// Publishes the question a tool is asking, then gets out of the way.
///
/// It raises `userInputRequested` and nothing else. It used to also emit
/// `runState(.waitingForUser)` and `runState(.running)` around the wait, which
/// only worked while one tool ran at a time: with a batch in flight, the tool
/// whose question is answered would announce "running" while another was still
/// waiting on the user. Run state is derived by the reader from what is
/// actually outstanding, rather than asserted by whichever tool moved last.
private nonisolated struct EventingAgentUserInteraction: AgentUserInteractionHandling, Sendable {
    var base: any AgentUserInteractionHandling
    var channel: AgentEventChannel

    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        channel.emit(.userInputRequested(request))
        return await base.request(request)
    }
}
