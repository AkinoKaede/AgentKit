import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentSecretLifetimeTests {
    @Test(arguments: [AgentRunState.completed, .failed, .cancelled])
    func endingARunDoesNotDiscardCallerOwnedSecrets(_ state: AgentRunState) async throws {
        let broker = SecretBroker()
        var source = Data("retained".utf8)
        let handle = try await broker.issue(AgentSecret(consumingUTF8: &source))
        let model = SecretLifetimeModel(state: state)
        let repository = InMemoryAgentRunRepository()
        let runtime = AgentRuntime(
            model: model, tools: [],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
            repository: repository, secretBroker: broker)
        var summaries: [AgentRunSummary] = []
        var terminalEvents: [String] = []
        for await event in await runtime.start(
            .init(conversationID: UUID(), prompt: "Continue", permissionMode: .fullAccess))
        {
            if state == .cancelled, case .messageDelta = event {
                await runtime.cancel()
            }
            switch event {
            case .failed: terminalEvents.append("failed")
            case .runFinished(let summary):
                summaries.append(summary)
                terminalEvents.append("finished")
            case .runState(let value) where value == state:
                terminalEvents.append("state")
            default: break
            }
        }
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.state == state)
        #expect(terminalEvents == (state == .failed ? ["failed", "finished", "state"] : ["finished", "state"]))
        let saved = try #require(await repository.snapshot(summary.id))
        #expect(saved.state == state)
        #expect(saved.finishedAt == summary.finishedAt)
        #expect(saved.finishedAt != nil)
        #expect((saved.failure != nil) == (state == .failed))
        #expect(await runtime.steer(.init(role: .user, text: "too late")) == false)
        let secret = try await broker.consume(handle)
        defer { secret.clear() }
        #expect(try secret.withUnsafeBytes { Array($0) } == Array("retained".utf8))
    }

    @Test
    func laterRunsKeepAvailableHandlesUntilExplicitCleanup() async throws {
        let broker = SecretBroker()
        var source = Data("retained".utf8)
        let handle = try await broker.issue(AgentSecret(consumingUTF8: &source))
        let history = messages(handle)
        let model = SecretLifetimeModel(state: .completed)
        let conversationID = UUID()
        for _ in 0..<2 {
            let runtime = AgentRuntime(
                model: model, tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                secretBroker: broker)
            for await _ in await runtime.start(
                .init(
                    conversationID: conversationID, prompt: "Continue",
                    permissionMode: .fullAccess, priorMessages: history))
            {}
        }
        let requests = await model.requests
        #expect(requests.count == 2)
        for request in requests {
            let result = try #require(request.messages.first { $0.toolCallID == "secret" })
            #expect(result.text.contains(handle.id.uuidString))
            #expect(!result.text.contains("retained"))
        }
        await broker.discardAll()
        let sanitized = AgentSecretLifecycle.sanitizeHistoricalMessages(
            history, availableHandles: await broker.availableHandleIDs)
        #expect(sanitized[1].text == AgentSecretLifecycle.expiredResultContent)
        await #expect(throws: SecretBrokerError.notFound) { try await broker.consume(handle) }
    }

    @Test
    func historicalConsumerArgumentsKeepOnlyAvailableHandles() {
        let handle = SecretHandle(id: UUID())
        let message = AgentTranscriptMessage(
            role: .assistant,
            toolCalls: [
                .init(
                    id: "consumer", name: "consume",
                    arguments: .object(["secret_handle": .string(handle.id.uuidString)]))
            ])
        let available = AgentSecretLifecycle.sanitizeHistoricalMessages([message], availableHandles: [handle.id])
        #expect(available == [message])
        let unavailable = AgentSecretLifecycle.sanitizeHistoricalMessages([message])
        #expect(unavailable[0].toolCalls[0].arguments.objectValue?["secret_handle"] == nil)
    }

    private func messages(_ handle: SecretHandle) -> [AgentTranscriptMessage] {
        let call = AgentToolCall(
            id: "secret", name: "request_user_secret",
            arguments: .object(["prompt": .string("API key"), "purpose": .string("Service access")]))
        let result = RequestUserSecretTool.result(
            .init(runID: UUID(), call: call),
            .object(["secret_handle": .string(handle.id.uuidString), "single_use": .bool(true)]))
        return [
            .init(role: .assistant, toolCalls: [call]),
            .init(role: .tool, text: result.content, toolCallID: call.id, toolName: call.name),
        ]
    }
}

private actor SecretLifetimeModel: AgentModelStreaming {
    let state: AgentRunState
    private(set) var requests: [AgentModelRequest] = []

    init(state: AgentRunState) { self.state = state }

    nonisolated func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await record(request)
                switch state {
                case .completed:
                    continuation.yield(.textDelta("done"))
                    continuation.yield(.finished(.completed))
                    continuation.finish()
                case .failed:
                    continuation.finish(throwing: Failure.expected)
                default:
                    continuation.yield(.textDelta("waiting"))
                }
            }
        }
    }

    private func record(_ request: AgentModelRequest) { requests.append(request) }
    private enum Failure: Error { case expected }
}
