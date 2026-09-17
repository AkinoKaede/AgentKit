import Foundation
import Testing

@testable import AgentKit

/// Framing tests, not field tests.
///
/// The bug these exist for: the streaming entry point framed on
/// `URLSession.AsyncBytes.lines`, and `AsyncLineSequence` discards empty lines.
/// A blank line is the only thing that dispatches an SSE event, so every chat
/// response arrived as one undelimited blob — no text, no tool calls, and an
/// agent turn that ended after one request. Nothing caught it because the
/// parser tests all called `parse*` on already-framed dictionaries, and the
/// buffered entry point framed lines a different way.
@Suite
struct SSEStreamTests {
    @Test
    func aStreamOfChatChunksDoesNotCollapseIntoOneEvent() async throws {
        let body = """
            data: {"choices":[{"delta":{"content":"Let me check."}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"list_hosts","arguments":""}}]}}]}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]


            """
        let events = try await stream(body)

        #expect(events.count == 4)
        #expect(events.last?.data == "[DONE]")

        // The framing is what the agent loop depends on: one JSON object per
        // event, so the tool call survives to the runtime.
        var callIDs: [Int: String] = [:]
        var parsed: [AgentModelStreamEvent] = []
        for event in events where event.data != "[DONE]" {
            let root = try #require(
                try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any]
            )
            parsed += AgentProviderClient.parseChat(root, callIDs: &callIDs)
        }
        #expect(parsed.contains { if case .textDelta("Let me check.") = $0 { true } else { false } })
        #expect(
            parsed.contains {
                if case .toolCallDelta(let id, let name, _) = $0 {
                    id == "call_1" && name == "list_hosts"
                } else {
                    false
                }
            })
        #expect(parsed.contains { if case .finished(.toolCalls) = $0 { true } else { false } })
    }

    struct FramingFixture: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let body: String
        let expected: [SSEEvent]
    }

    @Test(arguments: [
        FramingFixture(
            testDescription: "LF dispatch", body: "data: one\n\ndata: two\n\n",
            expected: [SSEEvent(data: "one"), SSEEvent(data: "two")]),
        FramingFixture(
            testDescription: "CRLF dispatch", body: "data: one\r\n\r\ndata: two\r\n\r\n",
            expected: [SSEEvent(data: "one"), SSEEvent(data: "two")]),
        FramingFixture(
            testDescription: "bare CR dispatch", body: "data: one\r\rdata: two\r\r",
            expected: [SSEEvent(data: "one"), SSEEvent(data: "two")]),
        FramingFixture(
            testDescription: "EOF after line", body: "data: only\n", expected: [SSEEvent(data: "only")]),
        FramingFixture(
            testDescription: "EOF inside line", body: "data: only", expected: [SSEEvent(data: "only")]),
        FramingFixture(
            testDescription: "heartbeats and unknown fields", body: ": ping\n\nretry: 500\nx-vendor: 1\ndata: real\n\n",
            expected: [SSEEvent(data: "real")]),
        FramingFixture(
            testDescription: "multiline data preserves leading space", body: "data: first\ndata:  second\n\n",
            expected: [SSEEvent(data: "first\n second")]),
        FramingFixture(
            testDescription: "event fields do not leak", body: "event: endpoint\nid: 42\ndata: /post\n\ndata: next\n\n",
            expected: [SSEEvent(event: "endpoint", data: "/post", id: "42"), SSEEvent(data: "next")]),
        FramingFixture(
            testDescription: "fragmented UTF-8", body: "data: 主机列表 🌐\n\ndata: 完成\n\n",
            expected: [SSEEvent(data: "主机列表 🌐"), SSEEvent(data: "完成")]),
        FramingFixture(testDescription: "empty source", body: "", expected: []),
        FramingFixture(testDescription: "heartbeat without data", body: ": ping\n\n", expected: []),
    ])
    func streamedAndBufferedFramingMatchExpectedEvents(_ fixture: FramingFixture) async throws {
        // Assert both paths against independent expectations, not just each other:
        // a shared framing regression must not make two wrong results pass.
        #expect(try await stream(fixture.body) == fixture.expected)
        #expect(SSEStream.events(in: Data(fixture.body.utf8)) == fixture.expected)
    }

    @Test
    func transportFailureIsThrownRatherThanReadAsAnEndOfStream() async {
        let bytes = AsyncThrowingStream<UInt8, any Error> { continuation in
            for byte in Array("data: partial\n\ndata: ".utf8) { continuation.yield(byte) }
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }

        var events: [SSEEvent] = []
        var thrown: (any Error)?
        do {
            for try await event in SSEStream.events(from: bytes) { events.append(event) }
        } catch { thrown = error }

        #expect(events.map(\.data) == ["partial"])
        #expect((thrown as? URLError)?.code == .networkConnectionLost)
    }

    @Test
    func aTerminalEventDoesNotReadAhead() async throws {
        let bytes = ReadProbeBytes("data: done\n\n", failAtEnd: true)
        var events: [SSEEvent] = []
        try await SSEStream.consume(from: bytes) { event in
            events.append(event)
            return true
        }
        #expect(events.map(\.data) == ["done"])
    }

    @Test
    func byteBudgetIncludesFramingAndAllowsTheExactLimit() async throws {
        let body = "data: 主机\n\n"
        var events: [SSEEvent] = []
        try await SSEStream.consume(from: ReadProbeBytes(body), maximumBytes: body.utf8.count) { event in
            events.append(event)
            return false
        }
        #expect(events.map(\.data) == ["主机"])
        await #expect(throws: SSEStream.ReadError.self) {
            try await SSEStream.consume(from: ReadProbeBytes(body), maximumBytes: body.utf8.count - 1) { _ in false }
        }
    }

    @Test(arguments: ["", "\n", "\r\n", "\r"])
    func lineBudgetIsEnforcedEvenAtEOF(_ ending: String) async throws {
        var events: [SSEEvent] = []
        try await SSEStream.consume(
            from: ReadProbeBytes("data: abc" + ending), maximumLineBytes: 9
        ) { event in
            events.append(event)
            return false
        }
        #expect(events.map(\.data) == ["abc"])
        await #expect(throws: SSEStreamError.self) {
            try await SSEStream.consume(
                from: ReadProbeBytes("data: abcd" + ending), maximumLineBytes: 9
            ) { _ in false }
        }
    }

    @Test
    func callbackFailurePropagatesWithoutReadingAhead() async {
        await #expect(throws: AgentProviderError.self) {
            try await SSEStream.consume(from: ReadProbeBytes("data: malformed\n\n", failAtEnd: true)) { _ in
                throw AgentProviderError.invalidResponse
            }
        }
    }

    @Test
    func cancellationIsCheckedBeforeReadingEvenAnEmptySource() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await SSEStream.consume(from: ReadProbeBytes("", failAtEnd: true)) { _ in false }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func stream(_ body: String) async throws -> [SSEEvent] {
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in Array(body.utf8) { continuation.yield(byte) }
            continuation.finish()
        }
        var events: [SSEEvent] = []
        for try await event in SSEStream.events(from: bytes) { events.append(event) }
        return events
    }
}

/// Throws on a read past the fixture when the consumer must stop early.
private struct ReadProbeBytes: AsyncSequence, AsyncIteratorProtocol, Sendable {
    typealias Element = UInt8
    private let bytes: [UInt8]
    private let failAtEnd: Bool
    private var index = 0

    init(_ body: String, failAtEnd: Bool = false) {
        bytes = Array(body.utf8)
        self.failAtEnd = failAtEnd
    }

    func makeAsyncIterator() -> Self { self }

    mutating func next() async throws -> UInt8? {
        guard index < bytes.count else {
            if failAtEnd { throw URLError(.networkConnectionLost) }
            return nil
        }
        defer { index += 1 }
        return bytes[index]
    }
}
