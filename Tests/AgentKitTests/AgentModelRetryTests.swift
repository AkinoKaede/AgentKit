import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentModelRetryTests {
    @Test
    func transientFailureResetsOneLogicalTurnAndRecovers() async throws {
        let model = RetryScriptedModel(scripts: [
            .init(events: [.textDelta("discarded")], error: RetryTestError.transient),
            .init(events: [.textDelta("kept"), .finished(.completed)]),
        ])

        let events = await run(model)

        #expect(await model.requestCount == 2)
        #expect(
            events.compactMap { event -> Int? in
                guard case .modelRetryScheduled(let progress) = event else { return nil }
                return progress.attempt
            } == [1]
        )
        #expect(events.contains { if case .modelRetryRecovered = $0 { true } else { false } })
        #expect(
            events.compactMap { event -> String? in
                guard case .messageFinished(let message) = event else { return nil }
                return message.text
            } == ["kept"]
        )
    }

    @Test
    func retryBudgetIsFiveAttemptsAfterTheInitialRequest() async {
        let model = RetryScriptedModel(
            scripts: Array(
                repeating: .init(events: [], error: RetryTestError.transient),
                count: 6
            ))

        let events = await run(model)

        #expect(await model.requestCount == 6)
        #expect(
            events.compactMap { event -> Int? in
                guard case .modelRetryScheduled(let progress) = event else { return nil }
                return progress.attempt
            } == [1, 2, 3, 4, 5]
        )
        #expect(events.contains(.runState(.failed)))
        #expect(
            events.contains { event in
                guard case .runFinished(let summary) = event else { return false }
                return summary.state == .failed && summary.failure == RetryTestError.transient.localizedDescription
            }
        )
    }

    @Test
    func permanentFailureIsNotRetried() async {
        let model = RetryScriptedModel(
            scripts: [.init(events: [], error: RetryTestError.permanent)]
        )

        let events = await run(model)

        #expect(await model.requestCount == 1)
        #expect(!events.contains { if case .modelRetryScheduled = $0 { true } else { false } })
        #expect(events.contains(.runState(.failed)))
    }

    @Test
    func cleanEOFWithoutAFinishEventIsRetried() async throws {
        let model = RetryScriptedModel(scripts: [
            .init(events: [.textDelta("discarded")]),
            .init(events: [.textDelta("complete"), .finished(.completed)]),
        ])

        let events = await run(model)

        #expect(await model.requestCount == 2)
        #expect(
            events.contains { event in
                guard case .messageFinished(let message) = event else { return false }
                return message.text == "complete"
            }
        )
    }

    @Test
    func transportFailureAfterFinishDoesNotRepeatACompleteResponse() async throws {
        let model = RetryScriptedModel(
            scripts: [
                .init(
                    events: [.textDelta("complete"), .finished(.completed)],
                    error: RetryTestError.transient
                )
            ]
        )

        let events = await run(model)

        #expect(await model.requestCount == 1)
        #expect(events.contains(.runState(.completed)))
        #expect(!events.contains { if case .modelRetryScheduled = $0 { true } else { false } })
    }

    @Test
    func abandonedToolCallIsExecutedOnlyAfterACompleteRetry() async {
        let executions = RetryExecutionCounter()
        let model = RetryScriptedModel(scripts: [
            .init(
                events: [
                    .toolCallSnapshot(
                        id: "call", providerItemID: nil, name: "probe", arguments: "{}"
                    )
                ],
                error: RetryTestError.transient
            ),
            .init(events: [
                .toolCallSnapshot(
                    id: "call", providerItemID: nil, name: "probe", arguments: "{}"
                ),
                .finished(.toolCalls),
            ]),
            .init(events: [.textDelta("done"), .finished(.completed)]),
        ])
        let tool = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "probe", summary: "probe",
                inputSchema: .object([
                    "type": .string("object"), "properties": .object([:]),
                    "required": .array([]), "additionalProperties": .bool(false),
                ]),
                target: .local, approvalPolicy: .approve
            )
        ) { invocation, _ in
            await executions.increment()
            return AgentToolResult(callID: invocation.call.id, content: "ok")
        }

        _ = await run(model, tools: [tool])

        #expect(await executions.value == 1)
    }

    @Test
    func providerClassifiesOnlyTemporaryFailuresForRetry() {
        let client = AgentProviderClient(
            provider: ModelProvider(name: "test"),
            model: AIModel(id: "test"), secret: ""
        )

        #expect(client.shouldRetry(after: URLError(.networkConnectionLost)))
        #expect(client.shouldRetry(after: URLError(.timedOut)))
        #expect(client.shouldRetry(after: AgentProviderError.http(408, "timeout")))
        #expect(client.shouldRetry(after: AgentProviderError.http(429, "limited")))
        #expect(client.shouldRetry(after: AgentProviderError.http(503, "unavailable")))
        #expect(!client.shouldRetry(after: AgentProviderError.http(401, "unauthorized")))
        #expect(!client.shouldRetry(after: AgentProviderError.invalidResponse))
    }

    private func run(
        _ model: RetryScriptedModel,
        tools: [AnyAgentTool] = []
    ) async -> [AgentEvent] {
        var configuration = AgentLoopConfiguration()
        configuration.modelRetryPolicy = AgentModelRetryPolicy(
            delays: [.zero, .zero, .zero, .zero, .zero]
        )
        let runtime = AgentRuntime(
            model: model, tools: tools,
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
            configuration: configuration
        )
        var events: [AgentEvent] = []
        for await event in await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "run",
                permissionMode: .askForApproval
            )
        ) {
            events.append(event)
        }
        return events
    }
}

private actor RetryScriptedModel: AgentModelStreaming {
    struct Script: Sendable {
        var events: [AgentModelStreamEvent]
        var error: RetryTestError?

        init(events: [AgentModelStreamEvent], error: RetryTestError? = nil) {
            self.events = events
            self.error = error
        }
    }

    private let scripts: [Script]
    private var requests = 0

    init(scripts: [Script]) { self.scripts = scripts }

    nonisolated func stream(
        _ request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let script = await next()
                for event in script.events { continuation.yield(event) }
                if let error = script.error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    nonisolated func shouldRetry(after error: any Error) -> Bool {
        (error as? RetryTestError) == .transient
    }

    var requestCount: Int { requests }

    private func next() -> Script {
        defer { requests += 1 }
        return scripts[min(requests, scripts.count - 1)]
    }
}

private enum RetryTestError: String, Error, LocalizedError, Sendable {
    case transient
    case permanent

    var errorDescription: String? { rawValue }
}

private actor RetryExecutionCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
