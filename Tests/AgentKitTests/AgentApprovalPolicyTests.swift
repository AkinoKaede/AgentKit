import Foundation
import Testing

@testable import AgentKit

private actor ApprovalProbe {
    private(set) var count = 0

    func allow(_ request: AgentApprovalRequest) -> AgentApprovalDecision {
        count += 1
        return .allow
    }
}

private actor ReviewProbe: GuardianReviewing {
    private(set) var count = 0

    func review(_ request: AgentApprovalRequest) async throws -> GuardianDecision {
        count += 1
        return GuardianDecision(
            verdict: .approve, risk: .low, userAuthorization: .high,
            reason: "Locally approved for the test."
        )
    }
}

private actor DenyingReviewProbe: GuardianReviewing {
    private(set) var count = 0

    func review(_ request: AgentApprovalRequest) async throws -> GuardianDecision {
        count += 1
        return GuardianDecision(
            verdict: .deny, risk: .high, userAuthorization: .low,
            reason: "Denied for the test."
        )
    }
}

private actor ExecutionProbe {
    private(set) var count = 0

    func run(callID: String) -> AgentToolResult {
        count += 1
        return AgentToolResult(callID: callID, content: "ran")
    }
}

@Suite
struct AgentApprovalPolicyTests {
    @Test
    func approvalPolicyCodableWritesNewCasesAndReadsLegacyMCPValues() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for policy in AgentToolDescriptor.ApprovalPolicy.allCases {
            let encoded = String(decoding: try encoder.encode(policy), as: UTF8.self)
            #expect(encoded == "\"\(policy.rawValue)\"")
            #expect(
                try decoder.decode(
                    AgentToolDescriptor.ApprovalPolicy.self,
                    from: Data(encoded.utf8)
                ) == policy
            )
        }

        let legacy: [String: AgentToolDescriptor.ApprovalPolicy] = [
            "disabled": .deny,
            "alwaysAsk": .ask,
            "followPermissions": .ask,
        ]
        for (rawValue, expected) in legacy {
            #expect(
                try decoder.decode(
                    AgentToolDescriptor.ApprovalPolicy.self,
                    from: Data("\"\(rawValue)\"".utf8)
                ) == expected
            )
        }

        for obsolete in [
            "locallyReadOnly", "locallyContained", "requiresAuthorization",
            "notRequired", "required",
        ] {
            #expect(throws: (any Error).self) {
                try decoder.decode(
                    AgentToolDescriptor.ApprovalPolicy.self,
                    from: Data("\"\(obsolete)\"".utf8)
                )
            }
        }
    }

    @Test
    func approveBypassesEveryPermissionMode() async {
        let manual = ApprovalProbe()
        let broker = AgentApprovalBroker(
            reviewer: nil,
            manualApproval: { request in await manual.allow(request) }
        )

        for mode in AgentPermissionMode.allCases {
            let decision = await broker.authorize(Self.request(.approve), mode: mode)
            #expect(decision == .allow, "\(mode)")
        }
        #expect(await manual.count == 0)
    }

    @Test
    func askUsesTheSelectedPermissionMode() async {
        let manual = ApprovalProbe()
        let reviewer = ReviewProbe()
        let broker = AgentApprovalBroker(
            reviewer: reviewer,
            manualApproval: { request in await manual.allow(request) }
        )

        #expect(await broker.authorize(Self.request(.ask), mode: .askForApproval) == .allow)
        #expect(await broker.authorize(Self.request(.ask), mode: .approveForMe) == .allow)
        #expect(await broker.authorize(Self.request(.ask), mode: .fullAccess) == .allow)
        #expect(await manual.count == 1)
        #expect(await reviewer.count == 1)
    }

    @Test
    func denyRefusesEveryPermissionModeWithoutReview() async {
        let manual = ApprovalProbe()
        let reviewer = ReviewProbe()
        let broker = AgentApprovalBroker(
            reviewer: reviewer,
            manualApproval: { request in await manual.allow(request) }
        )

        for mode in AgentPermissionMode.allCases {
            let decision = await broker.authorize(Self.request(.deny), mode: mode)
            guard case .deny = decision else {
                Issue.record("\(mode) unexpectedly allowed a denied tool")
                continue
            }
        }
        #expect(await manual.count == 0)
        #expect(await reviewer.count == 0)
    }

    @Test
    func reviewerReadOnlyApprovalNeverEscalatesAnAsk() async {
        let approval = ReviewerReadOnlyApproval()
        let decision = await approval.authorize(Self.request(.ask), mode: .approveForMe)
        guard case .deny = decision else {
            Issue.record("Reviewer investigation unexpectedly escaped its read-only gate")
            return
        }
    }

    @Test
    func repeatedAdverseBatchesOpenTheRunLocalCircuit() async {
        let reviewer = DenyingReviewProbe()
        let broker = AgentApprovalBroker(
            reviewer: reviewer,
            manualApproval: { _ in .deny("manual unavailable") }
        )
        for index in 0..<4 {
            var request = Self.request(.ask)
            request.invocation.sourceMessageID = UUID()
            request.invocation.createdAt = Date(timeIntervalSince1970: Double(index))
            guard case .deny = await broker.authorize(request, mode: .approveForMe) else {
                Issue.record("Adverse batch unexpectedly ran")
                return
            }
        }
        #expect(await reviewer.count == 3)
    }

    @Test
    func deniedToolNeverStartsAndReturnsADeniedResult() async {
        let execution = ExecutionProbe()
        let tool = AnyAgentTool(
            descriptor: Self.request(.deny).descriptor,
            execute: { invocation, _ in await execution.run(callID: invocation.call.id) }
        )
        let channel = AgentEventChannel(repository: InMemoryAgentRunRepository())
        let executor = AgentToolExecutor(
            tools: AgentToolRegistry([tool]),
            approval: AgentApprovalBroker(
                reviewer: nil,
                manualApproval: { _ in .allow }
            ),
            hooks: AgentLoopHooks([]), channel: channel,
            secretBroker: SecretBroker(), userInteraction: UnavailableAgentUserInteraction(),
            runID: UUID(), permissionMode: .fullAccess, userIntent: "Test denial."
        )
        let call = AgentToolCall(id: "denied", name: "probe", arguments: .object([:]))
        let result = await executor.execute(executor.plan(call))

        #expect(result.isError)
        #expect(result.isApprovalPolicyDenied)
        #expect(await execution.count == 0)
    }

    @Test
    func deniedMCPToolsRemainRegisteredAndHintsStillTightenConcurrency() async throws {
        var destructive = MCPTool(id: "destroy", accessPolicy: .ask)
        destructive.annotations.destructiveHint = true
        let server = MCPServer(
            name: "Gateway",
            tools: [
                MCPTool(id: "denied", accessPolicy: .deny),
                MCPTool(id: "approved", accessPolicy: .approve),
                destructive,
            ]
        )

        let tools = AgentMCPTools.make(servers: [(server, nil)])
        let descriptors = tools.map(\.descriptor)
        #expect(descriptors.count == 3)
        #expect(descriptors.first { $0.name == "denied" }?.approvalPolicy == .deny)
        #expect(descriptors.first { $0.name == "approved" }?.approvalPolicy == .approve)
        #expect(descriptors.first { $0.name == "destroy" }?.concurrency == .sequential)

        let destructiveTool = try #require(tools.first { $0.descriptor.name == "destroy" })
        let preflight = try await destructiveTool.preflight(
            AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(id: "destroy", name: "destroy", arguments: .object([:]))
            )
        )
        #expect(preflight.approvalPolicy == .ask)
        #expect(preflight.reasons.contains { $0.contains("destructive") })
    }

    @Test
    func planModeHostDecisionRunsBeforeTheApprovalDefault() async {
        let request = Self.request(.ask)
        let context = AgentToolCallContext(
            invocation: request.invocation, descriptor: request.descriptor,
            userIntent: request.userIntent, permissionMode: .askForApproval
        )
        let defaultHook = AgentPlanModeHook(isPlanning: true)
        #expect(await defaultHook.willExecute(context) != .proceed)

        var hostHook = AgentPlanModeHook(isPlanning: true)
        hostHook.hostDecision = { _ in .proceed }
        #expect(await hostHook.willExecute(context) == .proceed)
    }

    private static func request(
        _ approvalPolicy: AgentToolDescriptor.ApprovalPolicy
    ) -> AgentApprovalRequest {
        AgentApprovalRequest(
            invocation: AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(id: UUID().uuidString, name: "probe", arguments: .object([:]))
            ),
            descriptor: AgentToolDescriptor(
                name: "probe", summary: "Probe approval policy.",
                inputSchema: .object([:]), target: .local,
                approvalPolicy: approvalPolicy
            ),
            userIntent: "Test approval policy."
        )
    }
}
