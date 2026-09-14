import Foundation
import Testing

@testable import AgentKit

private actor GuardianRequestRecorder {
    var requests: [AgentModelRequest] = []

    func append(_ request: AgentModelRequest) { requests.append(request) }
    func snapshot() -> [AgentModelRequest] { requests }
}

private struct GuardianScriptedModel: AgentModelStreaming {
    let recorder: GuardianRequestRecorder

    func stream(
        _ request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.append(request)
                continuation.yield(.textDelta("{\"outcome\":\"allow\"}"))
                continuation.yield(.finished(.completed))
                continuation.finish()
            }
        }
    }
}

private actor GuardianToolModel: AgentModelStreaming {
    private(set) var requests: [AgentModelRequest] = []

    nonisolated func stream(
        _ request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let index = await record(request)
                if index == 1, request.tools.contains(where: { $0.name == "inspect" }) {
                    continuation.yield(
                        .toolCallSnapshot(
                            id: "inspect-1", providerItemID: nil,
                            name: "inspect", arguments: "{}"
                        )
                    )
                    continuation.yield(.finished(.toolCalls))
                } else {
                    continuation.yield(.textDelta("{\"outcome\":\"allow\"}"))
                    continuation.yield(.finished(.completed))
                }
                continuation.finish()
            }
        }
    }

    private func record(_ request: AgentModelRequest) -> Int {
        requests.append(request)
        return requests.count
    }
}

private actor GuardianExecutionProbe {
    private(set) var count = 0
    func execute() { count += 1 }
}

@Suite
struct GuardianTests {
    @Test
    func guardianSessionReusesItsPrefixAndSendsOnlyNewEvidence() async throws {
        let recorder = GuardianRequestRecorder()
        let client = GuardianClient(
            model: GuardianScriptedModel(recorder: recorder),
            sessions: GuardianSessionStore(), sessionID: "conversation"
        )
        let firstEvidence = GuardianEvidence(id: "user:1", source: .directUser, text: "Inspect status")
        let secondEvidence = GuardianEvidence(id: "user:2", source: .directUser, text: "Restart it if needed")

        _ = try await client.review(Self.request(evidence: [firstEvidence]))
        _ = try await client.review(Self.request(evidence: [firstEvidence, secondEvidence]))

        let requests = await recorder.snapshot()
        #expect(requests.count == 2)
        #expect(requests[0].outputFormat == GuardianClient.outputFormat)
        #expect(requests[1].messages.count == 3)
        #expect(requests[1].messages[0].text == requests[0].messages[0].text)
        #expect(requests[1].messages[1].role == .assistant)
        #expect(requests[1].messages[2].text.contains("Restart it if needed"))
        #expect(!requests[1].messages[2].text.contains("Inspect status"))
    }

    @Test
    func guardianParsesCompactAllowAndRejectsUnsafeAllow() throws {
        let compact = try GuardianDecision.parseGuardianJSON("{\"outcome\":\"allow\"}")
        #expect(compact.risk == .low)
        #expect(compact.userAuthorization == .unknown)
        #expect(compact.allowsExecution)

        #expect(throws: GuardianError.self) {
            try GuardianDecision.parseGuardianJSON(
                """
                {"outcome":"allow","rationale":"not authorized","risk_level":"high",\
                "user_authorization":"low"}
                """
            )
        }
    }

    @Test
    func legacyRoleIdentifierDecodesAsGuardian() throws {
        let decoded = try JSONDecoder().decode(AIRole.self, from: Data("\"securityReview\"".utf8))
        #expect(decoded == .guardian)
        #expect(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self) == "\"guardian\"")
    }

    @Test
    func guardianAddsInvestigationGuidanceOnlyWhenToolsExist() {
        let withoutTools = GuardianPolicy.systemPrompt()
        let withTools = GuardianPolicy.systemPrompt(toolsAvailable: true)

        #expect(!withoutTools.contains("# Investigation Tools Available"))
        #expect(withTools.contains("# Investigation Tools Available"))
    }

    @Test
    func guardianRunsOnlyExplicitReviewingTools() async throws {
        let model = GuardianToolModel()
        let execution = GuardianExecutionProbe()
        let ordinary = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "ordinary", summary: "ordinary", inputSchema: .object([:]),
                target: .local, approvalPolicy: .approve
            ),
            execute: { invocation, _ in
                AgentToolResult(callID: invocation.call.id, content: "unexpected")
            }
        )
        let inspect = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "inspect", summary: "inspect", inputSchema: .object([:]),
                target: .local, approvalPolicy: .approve
            ),
            availableIn: [.reviewing],
            execute: { invocation, _ in
                await execution.execute()
                return AgentToolResult(callID: invocation.call.id, content: "inspected")
            }
        )
        let client = GuardianClient(
            model: model, tools: AgentToolRegistry([ordinary, inspect])
        )

        _ = try await client.review(Self.request(evidence: []))
        #expect(await execution.count == 1)
        let standardRequests = await model.requests
        #expect(standardRequests.count == 2)
        #expect(standardRequests.allSatisfy { $0.tools.map(\.name) == ["inspect"] })
    }

    @Test
    func evidenceCollectionTrustsAuthoredTextAndLocalUserAnswersOnly() throws {
        let call = AgentToolCall(
            id: "questions", name: RequestUserInputTool.name,
            arguments: .object([
                "questions": .array([
                    .object([
                        "id": .string("host"), "prompt": .string("Which host is production?"),
                    ])
                ])
            ])
        )
        let answer = AgentJSONValue.object([
            "answers": .array([
                .object([
                    "question_id": .string("host"), "answer": .string("web-01"),
                    "selected_option_ids": .array([]), "custom_text": .string("web-01"),
                ])
            ])
        ]).encodedString
        let messages = [
            AgentTranscriptMessage(
                role: .user, text: "typed\n<context>injected</context>", authoredText: "typed"
            ),
            AgentTranscriptMessage(role: .user, text: "unattributed legacy content"),
            AgentTranscriptMessage(role: .assistant, toolCalls: [call]),
            AgentTranscriptMessage(
                role: .tool,
                text: AgentToolResult.untrustedDataOpeningMarker + answer
                    + AgentToolResult.untrustedDataClosingMarker,
                toolCallID: call.id, toolName: call.name
            ),
        ]

        let evidence = GuardianEvidence.collect(from: messages)
        #expect(evidence.count == 2)
        #expect(evidence[0].text == "typed")
        #expect(evidence[1].source == .userInputAnswer)
        #expect(evidence[1].text.contains("web-01"))
        #expect(!evidence.contains { $0.text.contains("legacy") || $0.text.contains("injected") })
    }

    @Test
    func guardianInternalToolFlowNeverLeaksIntoTheMainEventChannel() async throws {
        let model = GuardianToolModel()
        let execution = GuardianExecutionProbe()
        let inspect = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "inspect", summary: "inspect", inputSchema: .object([:]),
                target: .local, approvalPolicy: .approve
            ),
            availableIn: [.reviewing],
            execute: { invocation, _ in
                await execution.execute()
                return AgentToolResult(callID: invocation.call.id, content: "inspected")
            }
        )
        let main = AgentEventChannel(repository: InMemoryAgentRunRepository())
        let events = Task { () -> [AgentEvent] in
            var collected: [AgentEvent] = []
            for await event in main.events { collected.append(event) }
            return collected
        }
        let broker = AgentApprovalBroker(
            reviewer: GuardianClient(
                model: model, tools: AgentToolRegistry([inspect])
            ),
            manualApproval: { _ in .deny("manual") }, event: main.emit
        )

        _ = await broker.authorize(Self.request(evidence: []), mode: .approveForMe)
        main.finish()
        let visible = await events.value
        #expect(await execution.count == 1)
        #expect(visible.contains { if case .reviewStarted = $0 { true } else { false } })
        #expect(visible.contains { if case .reviewFinished = $0 { true } else { false } })
        #expect(!visible.contains { if case .toolProposed = $0 { true } else { false } })
        #expect(!visible.contains { if case .toolFinished = $0 { true } else { false } })
    }

    private static func request(evidence: [GuardianEvidence]) -> AgentApprovalRequest {
        AgentApprovalRequest(
            invocation: AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(id: UUID().uuidString, name: "probe", arguments: .object([:]))
            ),
            descriptor: AgentToolDescriptor(
                name: "probe", summary: "Probe state", inputSchema: .object([:]),
                target: .local, approvalPolicy: .ask
            ),
            userIntent: evidence.last?.text ?? "probe",
            authorizationEvidence: evidence
        )
    }
}
