import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentCacheReplayTests {
    private func replay(_ messages: [AgentTranscriptMessage]) -> [AgentTranscriptMessage] {
        AgentContextSnapshotReplay().transform(.init(systemPrompt: "stable", messages: messages, tools: [])).messages
    }

    @Test
    func sessionChangesAppendWithoutRewritingEarlierRequests() throws {
        var history: [AgentTranscriptMessage] = []
        var previous: [AgentTranscriptMessage] = []
        let contexts: [String?] = [
            "host A; cwd /a", "host A; cwd /a", "host A; cwd /b", "host B", nil, "host A; cwd /a",
        ]
        for (index, context) in contexts.enumerated() {
            let prompt = AgentTranscriptMessage(
                role: .user, text: "turn \(index)",
                contextSnapshot: .init(sessionContext: context)
            )
            history.append(prompt)
            let sent = replay(history)
            #expect(Array(sent.prefix(previous.count)) == previous)
            previous = sent
            history.append(.init(role: .assistant, text: "answer \(index)"))
        }
        #expect(previous.filter { $0.text == "host A; cwd /a" }.count == 2)
        #expect(previous.contains { $0.text.contains("no active session") })
        let restored = try JSONDecoder().decode([AgentTranscriptMessage].self, from: JSONEncoder().encode(history))
        #expect(replay(restored) == replay(history))
    }

    @Test
    func modeAndSkillRemovalAreExplicitAndCompactionRebases() {
        let planning = AgentTranscriptMessage(
            role: .user, text: "plan",
            contextSnapshot: .init(sessionContext: "A", skillCatalog: "skills", planContract: "PLAN")
        )
        let acting = AgentTranscriptMessage(role: .user, text: "act", contextSnapshot: .init(sessionContext: "A"))
        let sent = replay([planning, .init(role: .assistant, text: "plan ready"), acting])
        #expect(sent.contains { $0.text == "PLAN" })
        #expect(sent.contains { $0.text.contains("Plan mode is off") })
        #expect(sent.contains { $0.text == "No skills are enabled for this run." })
        #expect(replay([.init(role: .user, text: "summary", isCompaction: true), acting]).contains { $0.text == "A" })
        #expect(AgentCompaction.serialized([planning]).contains("[Context at this message] A"))
    }

    @Test(arguments: ModelAPIFormat.allCases)
    func everyWireFormatPreservesHistoryWhenTheTerminalChanges(format: ModelAPIFormat) throws {
        let client = AgentProviderClient(
            provider: .init(name: "test", apiFormat: format), model: .init(id: "test"), secret: "test")
        let first = AgentTranscriptMessage(
            role: .user, text: "inspect", contextSnapshot: .init(sessionContext: "host A"))
        let second = AgentTranscriptMessage(
            role: .user, text: "continue", contextSnapshot: .init(sessionContext: "host B"))
        func wire(_ messages: [AgentTranscriptMessage]) throws -> [AgentJSONValue] {
            let body = client.body(.init(systemPrompt: "stable", messages: replay(messages), tools: []))
            let key = format == .responses ? "input" : format == .generateContent ? "contents" : "messages"
            // Cache hints move forward; they do not change the cached content.
            func strip(_ value: AgentJSONValue) -> AgentJSONValue {
                switch value {
                case .object(var fields):
                    fields.removeValue(forKey: "cache_control")
                    return .object(fields.mapValues(strip))
                case .array(let values): return .array(values.map(strip))
                default: return value
                }
            }
            let data = try JSONSerialization.data(withJSONObject: body[key]!)
            return try #require(strip(AgentJSONValue.decode(data)).arrayValue)
        }
        let before = try wire([first])
        let after = try wire([first, .init(role: .assistant, text: "done"), second])
        #expect(Array(after.prefix(before.count)) == before)
    }

    @Test
    func onlyOfficialOpenAIReceivesTheStableCacheKey() {
        for format in [ModelAPIFormat.responses, .chatCompletions] {
            for host in ["api.openai.com", "gateway.example", "api.openai.com.example"] {
                let client = AgentProviderClient(
                    provider: .init(name: "test", apiFormat: format, inferenceURL: "https://\(host)/v1/responses"),
                    model: .init(id: "test"), secret: "test", promptCacheKey: "conversation-id"
                )
                let body = client.body(.init(systemPrompt: "s", messages: [], tools: []))
                #expect((body["prompt_cache_key"] as? String) == (host == "api.openai.com" ? "conversation-id" : nil))
                #expect(body["prompt_cache_retention"] == nil)
            }
        }
    }

    @Test
    func toolOutputIsFrozenAndTheCaptureCanBeRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(conversationID: UUID(), base: directory)
        let invocation = AgentToolInvocation(
            runID: UUID(), call: .init(id: "call", name: "inspect", arguments: .object([:])))
        let content = (1...40).map { "line \($0) 中文" }.joined(separator: "\n")
        let raw = AgentToolResult(callID: "call", content: content, isError: true)
        let result = await AgentToolOutputProjection(workspace: workspace, maximumBytes: 120, maximumLines: 8).project(
            raw, invocation: invocation)
        #expect(result.content == content)
        #expect(result.isError)
        let text = try #require(result.modelContent)
        #expect(text.contains("captured_output_path"))
        let saved = try await workspace.read("tool-output-\(invocation.id.uuidString).txt")
        #expect(saved.content == content)
        let tool = AgentTranscriptMessage(
            role: .tool, text: content, toolCallID: "call", toolName: "inspect", modelText: text)
        #expect(replay([tool]).first?.text == text)
        #expect(replay([tool, .init(role: .assistant, text: "older now")]).first?.text == text)
        let noWorkspace = await AgentToolOutputProjection(maximumBytes: 120).project(raw, invocation: invocation)
        #expect(noWorkspace.modelContent?.contains("No scratch workspace") == true)
    }

    @Test
    func surfaceAvailabilityBlocksExecutionWithoutRemovingTheSchema() async throws {
        let model = ReplayModel()
        let tool = AnyAgentTool(
            descriptor: .init(
                name: "surface_tool", summary: "surface", inputSchema: .object(["type": .string("object")]),
                target: .local, approvalPolicy: .approve
            )
        ) { _, _ in
            Issue.record("An unavailable tool must not execute")
            return AgentToolResult(callID: "call", content: "unexpected")
        }
        let user = AgentTranscriptMessage(
            role: .user, text: "retry", contextSnapshot: .init(toolAvailability: ["surface_tool": false]))
        let runtime = AgentRuntime(
            model: model, tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }))
        var results: [AgentToolResult] = []
        for await event in await runtime.start(
            .init(
                conversationID: UUID(), promptID: user.id, prompt: user.text,
                permissionMode: .fullAccess, priorMessages: [user], contextSnapshot: user.contextSnapshot))
        {
            if case .toolFinished(_, let result) = event { results.append(result) }
        }
        let requests = await model.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.tools.map(\.name) == ["surface_tool"] })
        #expect(requests.allSatisfy { $0.messages.filter { $0.id == user.id }.count == 1 })
        #expect(results.first?.isError == true)
    }

    @Test
    func cacheWritesAreCountedSeparatelyAndStreamingReportsMergeOnce() throws {
        let events = AgentProviderClient.parseCompletedResponses([
            "object": "response", "status": "completed", "output": [],
            "usage": [
                "input_tokens": 1000, "output_tokens": 30,
                "input_tokens_details": ["cached_tokens": 600, "cache_write_tokens": 300],
            ],
        ])
        let usage = try #require(
            events.compactMap { event -> AgentTokenUsage? in
                if case .usage(let value) = event { return value }
                return nil
            }.first)
        #expect(usage.inputTokens == 1000)
        #expect(usage.cacheWriteInputTokens == 300)
        #expect(usage.merging(usage) == usage)
    }
}

private actor ReplayModel: AgentModelStreaming {
    var requests: [AgentModelRequest] = []
    nonisolated func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await reply(request) { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
    private func reply(_ request: AgentModelRequest) -> [AgentModelStreamEvent] {
        requests.append(request)
        if requests.count == 1 {
            return [
                .toolCallSnapshot(id: "call", providerItemID: nil, name: "surface_tool", arguments: "{}"),
                .finished(.toolCalls),
            ]
        }
        return [.textDelta("done"), .finished(.completed)]
    }
}
