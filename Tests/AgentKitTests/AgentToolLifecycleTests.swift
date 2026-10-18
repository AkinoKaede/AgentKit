import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentToolLifecycleTests {
    @Test(arguments: [AgentToolExecutionMode.sequential, .parallel])
    func cancellationSettlesUnstartedCallsWithoutDispatchingThem(_ mode: AgentToolExecutionMode) async {
        let probe = ToolLifecycleProbe()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let tools = ["first", "second", "third"].map { name in
            tool(name) { invocation, _ in
                probe.record(name)
                signal.yield(())
                try await Task.sleep(for: .seconds(30))
                return AgentToolResult(callID: invocation.call.id, content: name)
            }
        }
        let channel = AgentEventChannel(repository: InMemoryAgentRunRepository())
        let scheduler = AgentToolScheduler(
            executor: executor(tools, channel: channel), mode: mode, maximumConcurrency: 1)
        let task = Task {
            defer { signal.finish() }
            return await scheduler.run(calls(["first", "second", "third"]))
        }
        for await _ in started { break }
        task.cancel()
        let results = await task.value
        channel.finish()
        let events = await collect(channel.events)

        #expect(probe.names == ["first"])
        #expect(results.map(\.callID) == ["first", "second", "third"])
        #expect(results.allSatisfy { $0.isError })
        #expect(results.first?.metadata["interrupted"] == .bool(true))
        #expect(results.dropFirst().allSatisfy { $0.metadata["interrupted"] == nil })
        #expect(events.filter { if case .toolStarted = $0 { true } else { false } }.count == 1)
        #expect(events.filter { if case .toolFinished = $0 { true } else { false } }.count == 3)
    }

    @Test
    func cancellationWhileApprovalWaitsCannotDispatchAnAllowedTool() async {
        let probe = ToolLifecycleProbe()
        let (waiting, signal) = AsyncStream<Void>.makeStream()
        let channel = AgentEventChannel(repository: InMemoryAgentRunRepository())
        let approval = AgentApprovalBroker(
            reviewer: nil,
            manualApproval: { _ in
                signal.yield(())
                try? await Task.sleep(for: .seconds(30))
                return .allow
            })
        let write = tool("write", approval: .ask) { invocation, _ in
            probe.record("write")
            return AgentToolResult(callID: invocation.call.id, content: "written")
        }
        let scheduler = AgentToolScheduler(executor: executor([write], channel: channel, approval: approval))
        let task = Task {
            defer { signal.finish() }
            return await scheduler.run(calls(["write"]))
        }
        for await _ in waiting { break }
        task.cancel()
        let results = await task.value
        channel.finish()
        let events = await collect(channel.events)

        #expect(probe.names.isEmpty)
        #expect(results.count == 1)
        #expect(results.first?.isError == true)
        #expect(results.first?.metadata["interrupted"] == nil)
        #expect(!events.contains { if case .toolStarted = $0 { true } else { false } })
        #expect(events.filter { if case .toolFinished = $0 { true } else { false } }.count == 1)
    }

    @Test(arguments: [0, -4])
    func nonpositiveConcurrencyStillExecutesAndFinishesEveryCall(_ limit: Int) async {
        let probe = ToolLifecycleProbe()
        let tools = ["one", "two"].map { name in
            tool(name) { invocation, _ in
                probe.record(name)
                return AgentToolResult(callID: invocation.call.id, content: name)
            }
        }
        let channel = AgentEventChannel(repository: InMemoryAgentRunRepository())
        let scheduler = AgentToolScheduler(executor: executor(tools, channel: channel), maximumConcurrency: limit)
        let results = await scheduler.run(calls(["one", "two"]))
        channel.finish()
        let events = await collect(channel.events)

        #expect(probe.names == ["one", "two"])
        #expect(results.map(\.content) == ["one", "two"])
        #expect(results.allSatisfy { !$0.isError })
        #expect(events.filter { if case .toolFinished = $0 { true } else { false } }.count == 2)
    }

    @Test
    func progressClosesBeforeResultHooksAndRemainsClosedAfterCompletion() async {
        let probe = ToolLifecycleProbe()
        let work = tool("work") { invocation, context in
            let result = AgentToolResult(callID: invocation.call.id, content: "running")
            context.report(result)
            probe.store(context.report)
            return AgentToolResult(callID: invocation.call.id, content: "done")
        }
        let channel = AgentEventChannel(repository: InMemoryAgentRunRepository())
        let scheduler = AgentToolScheduler(
            executor: executor([work], channel: channel, hooks: [LateProgressHook(probe: probe)]))
        _ = await scheduler.run(calls(["work"]))
        probe.publish()
        channel.finish()
        let events = await collect(channel.events)
        let progress = events.compactMap { event -> String? in
            if case .toolProgress(_, let result) = event { return result.content }
            return nil
        }
        #expect(progress == ["running"])
        #expect(events.filter { if case .toolFinished = $0 { true } else { false } }.count == 1)
    }

    @Test
    func progressCallbackCanCloseItsOwnGate() {
        let gate = AgentToolProgressGate()
        let probe = ToolLifecycleProbe()
        let report = gate.forward { _ in
            probe.record("reported")
            gate.close()
        }
        let partial = AgentToolResult(callID: "work", content: "partial")
        report(partial)
        report(partial)
        #expect(probe.names == ["reported"])
    }

    @Test
    func userAnswerIsAvailableToApprovalWithinTheSameSequentialBatch() async {
        let probe = ToolLifecycleProbe()
        let write = tool("write", approval: .ask) { invocation, _ in
            probe.record("write")
            return AgentToolResult(callID: invocation.call.id, content: "written")
        }
        let approval = AgentApprovalBroker(
            reviewer: nil,
            manualApproval: { request in
                let constrained = request.authorizationEvidence.contains {
                    $0.source == .userInputAnswer && $0.text.contains("Do not write to production")
                }
                probe.record(constrained ? "constrained" : "missing evidence")
                return constrained ? .deny("User ruled out this write") : .allow
            })
        var configuration = AgentLoopConfiguration()
        configuration.toolExecution = .sequential
        let runtime = AgentRuntime(
            model: InputThenWriteModel(), tools: [AnyAgentTool(RequestUserInputTool()), write],
            approval: approval, userInteraction: RestrictingUserInteraction(), configuration: configuration)
        for await _ in await runtime.start(
            .init(conversationID: UUID(), prompt: "Inspect the environment", permissionMode: .askForApproval))
        {}
        #expect(probe.names == ["constrained"])
    }

    private func tool(
        _ name: String, approval: AgentToolDescriptor.ApprovalPolicy = .approve,
        execute: @escaping @Sendable (AgentToolInvocation, AgentToolExecutionContext) async throws -> AgentToolResult
    ) -> AnyAgentTool {
        AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: name, summary: name,
                inputSchema: .object(["type": .string("object")]),
                target: .local, approvalPolicy: approval, concurrency: .parallel),
            execute: execute)
    }

    private func executor(
        _ tools: [AnyAgentTool], channel: AgentEventChannel,
        approval: (any AgentApprovalHandling)? = nil, hooks: [any AgentLoopHook] = []
    ) -> AgentToolExecutor {
        AgentToolExecutor(
            tools: AgentToolRegistry(tools),
            approval: approval ?? AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
            hooks: AgentLoopHooks(hooks), channel: channel, secretBroker: SecretBroker(),
            userInteraction: UnavailableAgentUserInteraction(), runID: UUID(),
            permissionMode: .askForApproval, userIntent: "Inspect")
    }

    private func calls(_ names: [String]) -> [AgentToolCall] {
        names.map { AgentToolCall(id: $0, name: $0, arguments: .object([:])) }
    }

    private func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
}

private final class ToolLifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var report: (@Sendable (AgentToolResult) -> Void)?

    var names: [String] { lock.withLock { recorded } }
    func record(_ name: String) { lock.withLock { recorded.append(name) } }
    func store(_ report: @escaping @Sendable (AgentToolResult) -> Void) { lock.withLock { self.report = report } }
    func publish() {
        let callback = lock.withLock { report }
        callback?(AgentToolResult(callID: "work", content: "too late"))
    }
}

private struct LateProgressHook: AgentLoopHook {
    let probe: ToolLifecycleProbe
    func didExecute(_ context: AgentToolResultContext) async -> AgentToolResultOverride? {
        probe.publish()
        return nil
    }
}

private struct RestrictingUserInteraction: AgentUserInteractionHandling {
    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        .answered([.init(questionID: "scope", value: .text("Do not write to production"))])
    }
}

private actor InputThenWriteModel: AgentModelStreaming {
    private var count = 0
    private func next() -> Int {
        defer { count += 1 }
        return count
    }

    nonisolated func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await next() == 0 {
                    let arguments = AgentJSONValue.object([
                        "questions": .array([.object(["id": .string("scope"), "prompt": .string("Any restrictions?")])])
                    ])
                    continuation.yield(
                        .toolCallSnapshot(
                            id: "question", providerItemID: nil, name: RequestUserInputTool.name,
                            arguments: arguments.encodedString))
                    continuation.yield(
                        .toolCallSnapshot(id: "write", providerItemID: nil, name: "write", arguments: "{}"))
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
