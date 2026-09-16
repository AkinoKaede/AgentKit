import Foundation
import Synchronization
import Testing

@testable import AgentKit

private final class CompletionURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var chunks: [Data] = []
        var contentType = "text/event-stream"
        var status = 200
        var failure: URLError?
        var leaveOpen = false
        var requests: [URLRequest] = []
        var started: AsyncStream<Void>.Continuation?
        var stopped: AsyncStream<Void>.Continuation?
    }

    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "completion.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            recorded.httpBody = data
        }
        let fixture = Self.state.withLock { state in
            state.requests.append(recorded)
            return state
        }
        let body = recorded.httpBody.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        let streaming = body?["stream"] as? Bool == true || request.url!.path.contains(":streamGenerateContent")
        let status = streaming ? fixture.status : 400
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": fixture.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        fixture.started?.yield(())
        fixture.started?.finish()
        if !streaming {
            client?.urlProtocol(self, didLoad: Data(#"{"detail":"Stream must be set to true"}"#.utf8))
        } else {
            for chunk in fixture.chunks { client?.urlProtocol(self, didLoad: chunk) }
        }
        if let failure = fixture.failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else if !fixture.leaveOpen {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        let stopped = Self.state.withLock { $0.stopped }
        stopped?.yield(())
        stopped?.finish()
    }
}

private struct CompletionEndpoint {
    let session: URLSession
    let started: AsyncStream<Void>
    let stopped: AsyncStream<Void>

    init(
        _ body: String, contentType: String = "text/event-stream", status: Int = 200,
        failure: URLError? = nil, leaveOpen: Bool = false, splitBytes: Bool = false
    ) {
        let start = AsyncStream<Void>.makeStream()
        let stop = AsyncStream<Void>.makeStream()
        started = start.stream
        stopped = stop.stream
        let data = Data(body.utf8)
        CompletionURLProtocol.state.withLock {
            $0 = CompletionURLProtocol.State(
                chunks: splitBytes ? data.map { Data([$0]) } : [data],
                contentType: contentType, status: status, failure: failure, leaveOpen: leaveOpen,
                started: start.continuation, stopped: stop.continuation
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        session = URLSession(configuration: configuration)
    }

    func client(_ format: ModelAPIFormat = .chatCompletions) -> AgentProviderClient {
        let url =
            format == .generateContent
            ? "https://completion.test/v1beta/models/{model}:generateContent"
            : "https://completion.test/v1/responses"
        return AgentProviderClient(
            provider: ModelProvider(name: "Streaming only", apiFormat: format, inferenceURL: url),
            model: AIModel(id: "test-model"), secret: "test-secret", session: session
        )
    }

    var requests: [URLRequest] { CompletionURLProtocol.state.withLock { $0.requests } }
}

@Suite(.serialized)
struct AgentProviderCompletionTests {
    private static let request = AgentModelRequest(systemPrompt: "Summarize", messages: [], tools: [])

    private static func sse(_ payloads: String...) -> String {
        payloads.map { "data: \($0)\n\n" }.joined()
    }

    private static func chat(_ text: String, reason: String = "stop") throws -> String {
        let chunk = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": text]]]])
        return sse(
            String(decoding: chunk, as: UTF8.self),
            #"{"choices":[{"delta":{},"finish_reason":"\#(reason)"}]}"#
        )
    }

    @Test(arguments: ModelAPIFormat.allCases)
    func everyProviderCompletesUsingStreamingTransport(_ format: ModelAPIFormat) async throws {
        let body: String
        switch format {
        case .chatCompletions: body = try Self.chat("你好🌏")
        case .responses:
            body = Self.sse(
                #"{"type":"response.output_text.delta","delta":"wrong"}"#,
                #"{"type":"response.completed","response":{"object":"response","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"你好🌏"}]}]}}"#
            )
        case .messages:
            body = Self.sse(
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好🌏"}}"#,
                #"{"type":"message_stop"}"#
            )
        case .generateContent:
            body = Self.sse(#"{"candidates":[{"content":{"parts":[{"text":"你好🌏"}]},"finishReason":"STOP"}]}"#)
        }
        let endpoint = CompletionEndpoint(body, splitBytes: true)
        defer { endpoint.session.invalidateAndCancel() }

        let result = try await endpoint.client(format).collectText(Self.request)

        #expect(result.text == "你好🌏")
        #expect(result.stopReason == .completed)
        let request = try #require(endpoint.requests.first)
        #expect(endpoint.requests.count == 1)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        if format == .generateContent {
            #expect(request.url?.path.contains(":streamGenerateContent") == true)
            #expect(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
                    URLQueryItem(name: "alt", value: "sse")) == true)
        } else {
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(body["stream"] as? Bool == true)
        }
    }

    @Test(arguments: ModelAPIFormat.allCases, ["application/json", "application/vnd.gateway+json"])
    func acceptsCompleteJSONFromAStreamingRequest(_ format: ModelAPIFormat, _ contentType: String) async throws {
        let body: String
        switch format {
        case .chatCompletions:
            body = #"{"choices":[{"message":{"content":"summary"},"finish_reason":"stop"}]}"#
        case .responses:
            body =
                #"{"object":"response","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"summary"}]}]}"#
        case .messages:
            body = #"{"type":"message","content":[{"type":"text","text":"summary"}],"stop_reason":"end_turn"}"#
        case .generateContent:
            body = #"{"candidates":[{"content":{"parts":[{"text":"summary"}]},"finishReason":"STOP"}]}"#
        }
        let endpoint = CompletionEndpoint(body, contentType: contentType)
        defer { endpoint.session.invalidateAndCancel() }
        let result = try await endpoint.client(format).collectText(Self.request)
        #expect(result.text == "summary")
        #expect(result.stopReason == .completed)
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func sharedFramingSupportsLineEndingsAndTrailingEvents(_ ending: String) async throws {
        let body = try Self.chat("summary").replacingOccurrences(of: "\n", with: ending)
            .trimmingCharacters(in: .newlines)
        let endpoint = CompletionEndpoint(body)
        defer { endpoint.session.invalidateAndCancel() }
        let result = try await endpoint.client().collectText(Self.request)
        #expect(result.text == "summary")
        #expect(result.stopReason == .completed)
    }

    @Test(arguments: [false, true])
    func terminalMarkersFinishWithoutWaitingForTheConnectionToClose(_ done: Bool) async throws {
        let body =
            done ? Self.sse(#"{"choices":[{"delta":{"content":"summary"}}]}"#, "[DONE]") : try Self.chat("summary")
        let endpoint = CompletionEndpoint(body + "data: invalid trailing data\n\n", leaveOpen: true)
        defer { endpoint.session.invalidateAndCancel() }
        let result = try await endpoint.client().collectText(Self.request)
        #expect(result.text == "summary")
        for await _ in endpoint.stopped { break }
    }

    @Test(arguments: ["text/event-stream", "application/json"])
    func fragmentedToolCallsShareOneIdentityAcrossResponseEncodings(_ contentType: String) async throws {
        let endpoint = CompletionEndpoint(
            Self.sse(
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"lookup","arguments":"{\"key\":"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#
            ), contentType: contentType)
        defer { endpoint.session.invalidateAndCancel() }
        let events = try await endpoint.client().complete(Self.request)
        var ids: [String] = []
        var names: [String] = []
        var arguments = ""
        for event in events {
            if case .toolCallDelta(let id, let name, let fragment) = event {
                ids.append(id)
                if let name { names.append(name) }
                arguments += fragment
            }
        }
        #expect(ids == ["call-1", "call-1"])
        #expect(names == ["lookup"])
        #expect(try AgentJSONValue.decode(Data(arguments.utf8)) == .object(["key": .number(1)]))
    }

    @Test(arguments: ["text/event-stream", "application/json"])
    func mislabeledSSEUsesTheSameTerminalAndValidationRules(_ contentType: String) async throws {
        let endpoint = CompletionEndpoint(
            try Self.chat("answer") + "data: malformed after completion\n\n", contentType: contentType)
        defer { endpoint.session.invalidateAndCancel() }
        #expect(try await endpoint.client().collectText(Self.request).text == "answer")
    }

    @Test(arguments: ["text/event-stream", "application/json"])
    func malformedEventsBeforeCompletionAreRejectedForBothEncodings(_ contentType: String) async throws {
        let endpoint = CompletionEndpoint(
            "data: malformed\n\n" + (try Self.chat("answer")), contentType: contentType)
        defer { endpoint.session.invalidateAndCancel() }
        await #expect(throws: AgentProviderError.self) {
            try await endpoint.client().complete(Self.request)
        }
    }

    @Test
    func preservesLengthStopReason() async throws {
        let endpoint = CompletionEndpoint(try Self.chat("partial summary", reason: "length"))
        defer { endpoint.session.invalidateAndCancel() }
        let result = try await endpoint.client().collectText(Self.request)
        #expect(result.stopReason == .length)
    }

    @Test(arguments: [
        "data: not-json\n\n",
        #"data: {"choices":[{"delta":{"content":"partial"}}]}"# + "\n\n",
        "",
    ])
    func malformedOrUnterminatedStreamsDoNotReturnPartialSuccess(_ body: String) async {
        let endpoint = CompletionEndpoint(body)
        defer { endpoint.session.invalidateAndCancel() }
        await #expect(throws: AgentProviderError.self) {
            try await endpoint.client().complete(Self.request)
        }
    }

    @Test
    func transportFailureDiscardsThePartialResult() async {
        let endpoint = CompletionEndpoint(
            Self.sse(#"{"choices":[{"delta":{"content":"partial"}}]}"#),
            failure: URLError(.networkConnectionLost)
        )
        defer { endpoint.session.invalidateAndCancel() }
        await #expect(throws: URLError.self) {
            try await endpoint.client().complete(Self.request)
        }
    }

    @Test
    func cancellationClosesTheTransport() async throws {
        let endpoint = CompletionEndpoint("", leaveOpen: true)
        defer { endpoint.session.invalidateAndCancel() }
        let task = Task { try await endpoint.client().complete(Self.request) }
        for await _ in endpoint.started { break }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation returned a successful result")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        for await _ in endpoint.stopped { break }
    }

    @Test
    func httpFailuresAreNotRetried() async throws {
        let endpoint = CompletionEndpoint(#"{"detail":"bad request"}"#, contentType: "application/json", status: 400)
        defer { endpoint.session.invalidateAndCancel() }
        do {
            _ = try await endpoint.client().complete(Self.request)
            Issue.record("HTTP 400 returned a successful result")
        } catch let error as AgentProviderError {
            guard case .http(let status, let body) = error else {
                Issue.record("Expected the original HTTP error")
                return
            }
            #expect(status == 400)
            #expect(body.contains("bad request"))
        }
        #expect(endpoint.requests.count == 1)
    }

    @Test(arguments: ["text/event-stream", "application/json"])
    func rawResponseBytesAreBounded(_ contentType: String) async {
        let limit = 16 * 1024 * 1024
        let body =
            contentType == "text/event-stream"
            ? String(repeating: ": keepalive\n\n", count: limit / 13 + 1)
            : String(repeating: " ", count: limit + 1)
        let endpoint = CompletionEndpoint(body, contentType: contentType)
        defer { endpoint.session.invalidateAndCancel() }
        do {
            _ = try await endpoint.client().complete(Self.request)
            Issue.record("An oversized response was accepted")
        } catch let error as AgentProviderError {
            guard case .responseTooLarge = error else {
                Issue.record("Expected the response byte limit")
                return
            }
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test
    func collectTextStillRejectsToolCalls() async {
        let endpoint = CompletionEndpoint(
            Self.sse(
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"run","arguments":"{}"}}]}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#
            ))
        defer { endpoint.session.invalidateAndCancel() }
        await #expect(throws: AgentBufferedTextError.self) {
            try await endpoint.client().collectText(Self.request)
        }
    }

    @Test
    func compactionWorksAgainstAStreamingOnlyEndpoint() async throws {
        let endpoint = CompletionEndpoint(try Self.chat("## Goal\n继续检查磁盘空间"))
        defer { endpoint.session.invalidateAndCancel() }
        let summary = try await AgentCompactionService().summarize(
            [AgentTranscriptMessage(role: .user, text: "检查磁盘空间")], model: endpoint.client()
        )
        #expect(summary == "## Goal\n继续检查磁盘空间")
        #expect(endpoint.requests.count == 1)
    }

    @Test(arguments: ["", "   "])
    func compactionRejectsEmptyStreamedSummaries(_ text: String) async throws {
        let endpoint = CompletionEndpoint(try Self.chat(text))
        defer { endpoint.session.invalidateAndCancel() }
        await #expect(throws: AgentCompactionError.self) {
            try await AgentCompactionService().summarize(
                [AgentTranscriptMessage(role: .user, text: "history")], model: endpoint.client()
            )
        }
    }

    @Test
    func titlesWorkAgainstAStreamingOnlyEndpoint() async throws {
        let endpoint = CompletionEndpoint(try Self.chat(#"{"title":"Disk usage"}"#))
        defer { endpoint.session.invalidateAndCancel() }
        let title = try await ConversationTitleService().summarize(
            context: ConversationTitleContext(firstUserMessage: "Check disk", firstAssistantMessage: "Checking"),
            model: endpoint.client()
        )
        #expect(title == "Disk usage")
        #expect(endpoint.requests.count == 1)
    }

    @Test
    func providerFailureDoesNotReturnPartialSuccess() async {
        let endpoint = CompletionEndpoint(
            Self.sse(
                #"{"choices":[{"delta":{"content":"partial"}}]}"#,
                #"{"type":"error","error":{"type":"api_error","message":"provider failed"}}"#
            ))
        defer { endpoint.session.invalidateAndCancel() }
        await #expect(throws: (any Error).self) {
            try await endpoint.client().complete(Self.request)
        }
    }

    @Test
    func liveStreamingKeepsUsageEventsAfterTheFinishReason() async throws {
        let endpoint = CompletionEndpoint(
            try Self.chat("answer")
                + Self.sse(
                    #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#, "[DONE]"
                ))
        defer { endpoint.session.invalidateAndCancel() }
        var text = ""
        var usage: AgentTokenUsage?
        for try await event in endpoint.client().stream(Self.request) {
            if case .textDelta(let delta) = event { text += delta }
            if case .usage(let value) = event { usage = value }
        }
        #expect(text == "answer")
        #expect(usage?.inputTokens == 10)
        #expect(usage?.outputTokens == 2)
    }
}
