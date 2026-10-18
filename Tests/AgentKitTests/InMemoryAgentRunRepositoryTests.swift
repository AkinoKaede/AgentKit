import Foundation
import Testing

@testable import AgentKit

@Suite
struct InMemoryAgentRunRepositoryTests {
    private let date = Date(timeIntervalSince1970: 100)
    private let descriptor = AgentToolDescriptor(
        name: "inspect", summary: "Inspect a fixture",
        inputSchema: .object(["type": .string("object")]), target: .local, approvalPolicy: .approve)

    @Test
    func overlappingSnapshotsReplaceWholePayloadButKeepFirstPositionAndOwner() async throws {
        let repository = InMemoryAgentRunRepository()
        let conversationID = UUID()
        let old = AgentTranscriptMessage(
            role: .user, text: "old", authoredText: "authored", toolName: "stale",
            isError: true, providerItems: [.string("old")], modelText: "old model", createdAt: date)
        let next = AgentTranscriptMessage(role: .assistant, text: "next", createdAt: date)
        let latest = AgentTranscriptMessage(id: old.id, role: .user, createdAt: date)
        let first = snapshot(conversationID, messages: [old, next])
        let second = snapshot(conversationID, messages: [latest], offset: 1)
        await repository.save(second)
        await repository.save(first)
        let restored = try #require(await repository.loadConversations().first)
        #expect(restored.messages == [latest, next])
        #expect(restored.modelTranscript == [latest, next])
        #expect(restored.messageRunIDs[old.id] == first.id)
        #expect(restored.runs.map(\.id) == [first.id, second.id])
    }

    @Test
    func equalStartTimesUseRunIDsForMergeAndTruncation() async throws {
        let repository = InMemoryAgentRunRepository()
        let conversationID = UUID()
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let old = AgentTranscriptMessage(role: .assistant, text: "old", createdAt: date)
        var newest = old
        newest.text = "newest"
        let prompt = AgentTranscriptMessage(role: .user, text: "edit", createdAt: date)
        let first = snapshot(conversationID, id: firstID, messages: [old])
        let second = snapshot(conversationID, id: secondID, messages: [newest, prompt])
        await repository.save(second)
        await repository.save(first)
        let before = try #require(await repository.loadConversations().first)
        #expect(before.messages == [newest, prompt])
        #expect(before.messageRunIDs[old.id] == firstID)
        let replacement = AgentTranscriptMessage(role: .user, text: "replacement", createdAt: date)
        try await repository.truncateConversation(
            conversationID, fromUserMessageID: prompt.id, replacingWith: replacement)
        // A late save from a removed run must not undo the edit.
        await repository.save(second)
        let after = try #require(await repository.loadConversations().first)
        #expect(after.messages == [newest, replacement])
        #expect(after.messageRunIDs[old.id] == firstID)
        #expect(await repository.snapshot(secondID) == nil)
    }

    @Test
    func seededCardsAndLiveEventsAreInvocationKeyedAndIdempotent() async throws {
        let repository = InMemoryAgentRunRepository()
        let conversationID = UUID()
        let run = snapshot(conversationID)
        let invocation = invocation(run.id)
        try await repository.createConversation(
            StoredAgentConversation(
                id: conversationID, messages: [],
                runs: [.init(id: run.id, state: .completed, startedAt: date)],
                toolCards: [.init(invocation: invocation, descriptor: descriptor, state: "proposed")],
                lastRunState: .completed))
        let request = AgentApprovalRequest(invocation: invocation, descriptor: descriptor, userIntent: "Inspect")
        let decision = GuardianDecision(verdict: .approve, risk: .low, userAuthorization: .high, reason: "Read only")
        let result = AgentToolResult(callID: invocation.call.id, content: "result")
        let events: [AgentEvent] = [
            .toolProposed(invocation, descriptor), .reviewStarted(request), .reviewFinished(request, decision),
            .toolStarted(invocation), .toolFinished(invocation, result),
        ]
        for event in events + events { await repository.record(event, runID: run.id) }
        // Late duplicate proposals preserve completed results and reviews.
        await repository.record(.toolProposed(invocation, descriptor), runID: run.id)
        let other = self.invocation(run.id)
        await repository.record(.toolProposed(other, descriptor), runID: run.id)
        let otherRun = snapshot(conversationID, offset: 1)
        await repository.save(otherRun)
        let otherRunInvocation = self.invocation(otherRun.id)
        await repository.record(.toolProposed(otherRunInvocation, descriptor), runID: otherRun.id)
        let restored = try #require(await repository.loadConversations().first)
        #expect(restored.toolCards.count == 3)
        let card = try #require(restored.toolCards.first { $0.invocation.id == invocation.id })
        #expect(card.state == "finished")
        #expect(card.descriptor == descriptor)
        #expect(card.result == result)
        #expect(card.review == decision)
        #expect(Set(restored.toolCards.map { $0.invocation.call.id }) == ["same-call"])
    }

    @Test
    func approvalEventsSupplyRealDescriptorsAndUnknownStartsDoNotFabricateCards() async throws {
        let repository = InMemoryAgentRunRepository()
        let run = snapshot(UUID())
        await repository.save(run)
        let invocation = invocation(run.id)
        await repository.record(.toolStarted(invocation), runID: run.id)
        #expect(await repository.loadConversations().first?.toolCards.isEmpty == true)
        let request = AgentApprovalRequest(invocation: invocation, descriptor: descriptor, userIntent: "Inspect")
        await repository.record(.reviewStarted(request), runID: run.id)
        await repository.record(.reviewFailed(request, reason: "Unavailable", timedOut: false), runID: run.id)
        let card = try #require(await repository.loadConversations().first?.toolCards.first)
        #expect(card.descriptor == descriptor)
        #expect(card.review == nil)
        #expect(card.result == nil)
    }

    @Test
    func deletionRejectsLateSnapshotsAndEvents() async throws {
        let repository = InMemoryAgentRunRepository()
        let run = snapshot(UUID())
        await repository.save(run)
        let invocation = invocation(run.id)
        await repository.record(.toolProposed(invocation, descriptor), runID: run.id)
        await repository.deleteConversation(run.conversationID)
        await repository.save(run)
        await repository.record(.toolFinished(invocation, .init(callID: "same-call", content: "late")), runID: run.id)
        await repository.record(.toolProposed(invocation, descriptor), runID: run.id)
        #expect(await repository.loadConversations().isEmpty)
        #expect(await repository.snapshot(run.id) == nil)
    }

    @Test
    func liveToolCardsPreventUnsafeTruncation() async throws {
        let repository = InMemoryAgentRunRepository()
        let prompt = AgentTranscriptMessage(role: .user, text: "inspect", createdAt: date)
        let run = snapshot(UUID(), messages: [prompt])
        await repository.save(run)
        let invocation = invocation(run.id)
        await repository.record(.toolProposed(invocation, descriptor), runID: run.id)
        do {
            try await repository.truncateConversation(
                run.conversationID, fromUserMessageID: prompt.id,
                replacingWith: .init(role: .user, text: "replacement"))
            Issue.record("Truncation must reject live tool activity")
        } catch AgentConversationPersistenceError.editWouldRemoveTools {
        }
        let restored = try #require(await repository.loadConversations().first)
        #expect(restored.messages == [prompt])
        #expect(restored.toolCards.count == 1)
    }

    @Test
    func truncationUsesNewestToolPayloadForSafety() async throws {
        let repository = InMemoryAgentRunRepository()
        let prompt = AgentTranscriptMessage(role: .user, text: "inspect", createdAt: date)
        let assistant = AgentTranscriptMessage(role: .assistant, createdAt: date)
        let first = snapshot(UUID(), messages: [prompt, assistant])
        var updated = assistant
        updated.toolCalls = [.init(id: "call", name: "inspect", arguments: .object([:]))]
        await repository.save(first)
        await repository.save(snapshot(first.conversationID, messages: [prompt, updated], offset: 1))
        do {
            try await repository.truncateConversation(
                first.conversationID, fromUserMessageID: prompt.id,
                replacingWith: .init(role: .user, text: "replacement"))
            Issue.record("Newest snapshot's tool call must prevent editing")
        } catch AgentConversationPersistenceError.editWouldRemoveTools {
        }
        #expect(await repository.loadConversations().first?.messages == [prompt, updated])
    }

    @Test
    func runtimeToolEventsRoundTripThroughTheOrderedChannel() async throws {
        let repository = InMemoryAgentRunRepository()
        let channel = AgentEventChannel(repository: repository)
        let approval = AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        let tool = AnyAgentTool(descriptor: descriptor) { invocation, _ in
            AgentToolResult(callID: invocation.call.id, content: "fixture result")
        }
        let runtime = AgentRuntime(
            model: PersistenceRoundTripModel(), tools: [tool], approval: approval,
            repository: repository, channel: channel)
        let conversationID = UUID()
        var finished: AgentToolInvocation?
        for await event in await runtime.start(
            .init(conversationID: conversationID, prompt: "Inspect", permissionMode: .askForApproval))
        {
            if case .toolFinished(let invocation, _) = event { finished = invocation }
        }
        let invocation = try #require(finished)
        // The UI stream closes independently of the durable channel's drain.
        // Bound the wait by time rather than assuming actor scheduling order.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await repository.loadConversations().first?.toolCards.first?.state != "finished",
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(1))
        }
        let restored = try #require(await repository.loadConversations().first)
        let card = try #require(restored.toolCards.first)
        #expect(restored.toolCards.count == 1)
        #expect(card.invocation == invocation)
        #expect(card.descriptor == descriptor)
        #expect(card.state == "finished")
        #expect(card.result?.content == "fixture result")
        #expect(restored.messages.contains { $0.role == .tool && $0.toolCallID == invocation.call.id })
        #expect(restored.messages.last?.text == "done")
        #expect(restored.lastRunState == .completed)
    }

    private func snapshot(
        _ conversationID: UUID, id: UUID = UUID(), messages: [AgentTranscriptMessage] = [], offset: TimeInterval = 0
    ) -> AgentRunSnapshot {
        AgentRunSnapshot(
            id: id, conversationID: conversationID, state: .completed, permissionMode: .askForApproval,
            messages: messages, startedAt: date.addingTimeInterval(offset))
    }

    private func invocation(_ runID: UUID) -> AgentToolInvocation {
        AgentToolInvocation(
            runID: runID, call: .init(id: "same-call", name: "inspect", arguments: .object([:])), createdAt: date)
    }
}

private actor PersistenceRoundTripModel: AgentModelStreaming {
    private var requestedTool = false

    private func shouldRequestTool() -> Bool {
        defer { requestedTool = true }
        return !requestedTool
    }

    nonisolated func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await shouldRequestTool() {
                    continuation.yield(
                        .toolCallSnapshot(id: "inspect-call", providerItemID: nil, name: "inspect", arguments: "{}"))
                    continuation.yield(.finished(.toolCalls))
                } else {
                    continuation.yield(.textDelta("done"))
                    continuation.yield(.finished(.completed))
                }
                continuation.finish()
            }
        }
    }
}
