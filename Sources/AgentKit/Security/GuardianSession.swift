import Foundation

/// One in-memory set of isolated Guardian conversations.
///
/// The adopting app keeps this store alive across ordinary agent runs. Each
/// channel is serialized and append-only, preserving provider prompt prefixes
/// without mixing reviewer state into the main conversation.
public actor GuardianSessionStore {
    public init(maximumSessions: Int = 64) {
        self.maximumSessions = max(2, maximumSessions)
    }

    private let maximumSessions: Int
    private var sessions: [String: GuardianSession] = [:]
    private var recency: [String] = []

    func review(
        channelID: String,
        request: AgentApprovalRequest,
        model: any AgentModelStreaming,
        tools: AgentToolRegistry,
        services: AgentToolServices,
        systemPrompt: String
    ) async throws -> GuardianDecision {
        let session: GuardianSession
        if let existing = sessions[channelID] {
            session = existing
        } else {
            session = GuardianSession()
            sessions[channelID] = session
        }
        recency.removeAll { $0 == channelID }
        recency.append(channelID)
        while recency.count > maximumSessions {
            sessions[recency.removeFirst()] = nil
        }
        return try await session.review(
            request, model: model, tools: tools, services: services,
            systemPrompt: systemPrompt
        )
    }
}

private actor GuardianSession {
    private static let maximumAttempts = 3
    private static let maximumTurns = 5
    private static let maximumInvestigationTurns = 4
    private static let maximumToolCalls = 4
    private static let maximumHistoryCharacters = 160_000
    private static let maximumEvidenceCharacters = 32_000

    private var history: [AgentTranscriptMessage] = []
    private var deliveredEvidence: [GuardianEvidence] = []
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func review(
        _ request: AgentApprovalRequest,
        model: any AgentModelStreaming,
        tools: AgentToolRegistry,
        services: AgentToolServices,
        systemPrompt: String
    ) async throws -> GuardianDecision {
        await acquire()
        defer { release() }

        let evidence =
            request.authorizationEvidence.isEmpty
            ? [
                GuardianEvidence(
                    id: "intent:\(request.invocation.runID.uuidString)",
                    source: .directUser, text: request.userIntent
                )
            ]
            : request.authorizationEvidence
        let delta = selectEvidence(evidence)
        let prompt = GuardianPolicy.reviewPrompt(request, evidence: bounded(delta))
        var lastError: (any Error)?

        for attempt in 1...Self.maximumAttempts {
            do {
                let retry =
                    attempt == 1
                    ? ""
                    : "\n\nA prior attempt returned an invalid or unavailable result. Reassess and return the required JSON."
                let result = try await runAttempt(
                    prompt: prompt + retry, request: request, model: model,
                    tools: tools, services: services, systemPrompt: systemPrompt
                )
                history = boundedHistory(result.messages)
                deliveredEvidence = history.isEmpty ? [] : evidence
                return result.decision
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < Self.maximumAttempts {
                    try await Task.sleep(for: .milliseconds(200 * attempt))
                }
            }
        }
        throw lastError ?? GuardianError.invalidResponse
    }

    private func runAttempt(
        prompt: String,
        request: AgentApprovalRequest,
        model: any AgentModelStreaming,
        tools: AgentToolRegistry,
        services: AgentToolServices,
        systemPrompt: String
    ) async throws -> (decision: GuardianDecision, messages: [AgentTranscriptMessage]) {
        let channel = AgentEventChannel(repository: InMemoryAgentRunRepository())
        defer { channel.finish() }
        let runID = UUID()
        var messages = history
        messages.append(AgentTranscriptMessage(role: .user, text: prompt))
        var toolCount = 0

        for turnIndex in 0..<Self.maximumTurns {
            try Task.checkCancellation()
            let canInvestigate =
                turnIndex < Self.maximumInvestigationTurns
                && toolCount < Self.maximumToolCalls && !tools.descriptors.isEmpty
            let turnTools = canInvestigate ? tools : AgentToolRegistry([])
            if !canInvestigate, !tools.descriptors.isEmpty {
                messages.append(
                    AgentTranscriptMessage(
                        role: .user,
                        text:
                            "Investigation budget exhausted. Use the evidence already collected and return a conservative final JSON decision without tools."
                    )
                )
            }
            let driver = AgentTurnDriver(
                model: model, tools: turnTools, channel: channel, runID: runID
            )
            let turn = try await driver.run(
                AgentModelContext(
                    systemPrompt: systemPrompt, messages: messages,
                    tools: turnTools.descriptors,
                    outputFormat: GuardianClient.outputFormat
                )
            )
            guard turn.reason != .error, turn.reason != .length else {
                throw GuardianError.invalidResponse
            }
            messages.append(turn.message)
            if turn.message.toolCalls.isEmpty {
                let decision = try GuardianDecision.parseGuardianJSON(turn.message.text)
                var canonical = messages.removeLast()
                canonical.text = decision.guardianJSON
                canonical.reasoning = []
                canonical.providerItems = []
                messages.append(canonical)
                return (decision, messages)
            }
            guard canInvestigate else { throw GuardianError.toolBudgetExceeded }
            let remaining = Self.maximumToolCalls - toolCount
            let acceptedCalls = Array(turn.message.toolCalls.prefix(remaining))
            let refusedCalls = Array(turn.message.toolCalls.dropFirst(remaining))
            let scheduler = AgentToolScheduler(
                executor: AgentToolExecutor(
                    tools: turnTools,
                    approval: ReviewerReadOnlyApproval(), hooks: AgentLoopHooks([]),
                    channel: channel, secretBroker: SecretBroker(),
                    userInteraction: UnavailableAgentUserInteraction(), services: services,
                    runID: runID, permissionMode: .askForApproval,
                    userIntent: request.userIntent,
                    outputProjection: AgentToolOutputProjection(
                        maximumBytes: 16 * 1024, maximumLines: 200
                    )
                ),
                mode: .sequential, maximumConcurrency: 1
            )
            var results = await scheduler.run(
                acceptedCalls, sourceMessageID: turn.message.id
            )
            if !refusedCalls.isEmpty {
                results += scheduler.fail(
                    refusedCalls,
                    reason: "Guardian investigation tool budget was exhausted.",
                    sourceMessageID: turn.message.id
                )
            }
            toolCount += acceptedCalls.count
            for (call, result) in zip(turn.message.toolCalls, results) {
                messages.append(
                    AgentTranscriptMessage(
                        id: AgentTranscriptMessage.toolResultID(
                            runID: runID, callID: result.callID
                        ),
                        role: .tool, text: result.content,
                        toolCallID: result.callID, toolName: call.name,
                        isError: result.isError, modelText: result.modelContent
                    )
                )
            }
        }
        throw GuardianError.turnBudgetExceeded
    }

    private func selectEvidence(
        _ current: [GuardianEvidence]
    ) -> [GuardianEvidence] {
        guard current.count >= deliveredEvidence.count,
            Array(current.prefix(deliveredEvidence.count)) == deliveredEvidence
        else {
            history = []
            deliveredEvidence = []
            return current
        }
        return Array(current.dropFirst(deliveredEvidence.count))
    }

    private func bounded(
        _ evidence: [GuardianEvidence]
    ) -> [GuardianEvidence] {
        guard evidence.reduce(0, { $0 + $1.text.count }) > Self.maximumEvidenceCharacters,
            let first = evidence.first
        else { return evidence }
        var suffix: [GuardianEvidence] = []
        var used = first.text.count
        for item in evidence.dropFirst().reversed()
        where used + item.text.count <= Self.maximumEvidenceCharacters {
            suffix.append(item)
            used += item.text.count
        }
        let omitted = max(0, evidence.count - suffix.count - 1)
        return [
            first,
            GuardianEvidence(
                id: "guardian-truncated", source: .directUser,
                text: "<guardian_truncated omitted_authorization_evidence=\(omitted) />"
            ),
        ] + suffix.reversed()
    }

    private func boundedHistory(
        _ messages: [AgentTranscriptMessage]
    ) -> [AgentTranscriptMessage] {
        guard messages.reduce(0, { $0 + $1.text.count }) > Self.maximumHistoryCharacters else {
            return messages
        }
        // Reset at a review boundary rather than summarize authorization with a
        // model. The next request sends a fresh trusted-evidence baseline.
        deliveredEvidence = []
        return []
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        waiters.removeFirst().resume()
    }
}

nonisolated extension GuardianDecision {
    static func parseGuardianJSON(_ text: String) throws -> Self {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8), data.count <= 16 * 1024,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: [
                "outcome", "rationale", "risk_level", "user_authorization",
            ]),
            let outcome = object["outcome"] as? String,
            outcome == "allow" || outcome == "deny"
        else { throw GuardianError.invalidResponse }

        if object.keys.count == 1, outcome == "allow" {
            return Self(
                verdict: .approve, risk: .low, userAuthorization: .unknown,
                reason: "Routine low-risk action."
            )
        }
        guard let rationale = object["rationale"] as? String,
            !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            rationale.utf8.count <= 4_096,
            let riskText = object["risk_level"] as? String,
            let risk = GuardianRisk(rawValue: riskText),
            let authorizationText = object["user_authorization"] as? String,
            let authorization = GuardianAuthorization(rawValue: authorizationText)
        else { throw GuardianError.invalidResponse }
        let verdict: GuardianVerdict = outcome == "allow" ? .approve : .deny
        if verdict == .approve,
            risk == .critical
                || risk == .high && authorization != .medium && authorization != .high
        {
            throw GuardianError.invalidResponse
        }
        return Self(
            verdict: verdict, risk: risk, userAuthorization: authorization,
            reason: rationale
        )
    }

    var guardianJSON: String {
        let object: [String: String] = [
            "outcome": verdict == .approve ? "allow" : "deny",
            "rationale": reason,
            "risk_level": risk.rawValue,
            "user_authorization": userAuthorization.rawValue,
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]
            )
        else { return "{\"outcome\":\"deny\"}" }
        return String(decoding: data, as: UTF8.self)
    }
}
