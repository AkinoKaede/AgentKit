import Foundation
import Testing

@testable import AgentKit

private actor AvailabilityProbe {
    private(set) var requests: [AgentModelRequest] = []
    private(set) var executions = 0

    func record(_ request: AgentModelRequest) -> Int {
        requests.append(request)
        return requests.count
    }

    func execute() { executions += 1 }
}

private struct AvailabilityModel: AgentModelStreaming {
    let probe: AvailabilityProbe

    func stream(
        _ request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let turn = await probe.record(request)
                if turn == 1 {
                    continuation.yield(
                        .toolCallSnapshot(
                            id: "task-call", providerItemID: nil,
                            name: "mode_task", arguments: "{}"
                        ))
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

private func availabilityTool(_ probe: AvailabilityProbe) -> AnyAgentTool {
    AnyAgentTool(
        descriptor: AgentToolDescriptor(
            name: "mode_task", summary: "Track execution",
            inputSchema: .object([
                "type": .string("object"), "properties": .object([:]),
                "required": .array([]), "additionalProperties": .bool(false),
            ]),
            target: .local, approvalPolicy: .approve
        ),
        availableIn: [.acting],
        execute: { invocation, _ in
            await probe.execute()
            return AgentToolResult(callID: invocation.call.id, content: "tracked")
        }
    )
}

private func runAvailabilityFixture(isPlanning: Bool) async -> AvailabilityProbe {
    let probe = AvailabilityProbe()
    let runtime = AgentRuntime(
        model: AvailabilityModel(probe: probe), tools: [availabilityTool(probe)],
        approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
    )
    for await _ in await runtime.start(
        AgentRunRequest(
            conversationID: UUID(), prompt: "go", permissionMode: .askForApproval,
            isPlanning: isPlanning
        ))
    {}
    return probe
}

@Suite
struct AgentToolAvailabilityTests {
    @Test
    func actingOnlyToolIsAbsentAndCannotExecuteWhilePlanning() async {
        let probe = await runAvailabilityFixture(isPlanning: true)

        let requests = await probe.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.tools.allSatisfy { $0.name != "mode_task" } })
        #expect(await probe.executions == 0)
    }

    @Test
    func actingOnlyToolIsSentAndExecutesWhileActing() async {
        let probe = await runAvailabilityFixture(isPlanning: false)

        let requests = await probe.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.tools.contains { $0.name == "mode_task" } })
        #expect(await probe.executions == 1)
    }

    @Test
    func manageTasksRegistrationIsActingOnlyWhileOtherToolsDefaultToBothModes() {
        let registry = AgentToolCatalog.registry(
            builtIn: .init(
                groups: [.tasks, .userInteraction],
                tasks: AgentTaskList { _ in }
            )
        )

        let planning = Set(registry.available(in: .planning).descriptors.map(\.name))
        let acting = Set(registry.available(in: .acting).descriptors.map(\.name))
        #expect(!planning.contains("manage_tasks"))
        #expect(acting.contains("manage_tasks"))
        #expect(planning.contains("request_user_input"))
        #expect(acting.contains("request_user_input"))
    }
}
