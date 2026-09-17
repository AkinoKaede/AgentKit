import Foundation

/// Per-response decoding state, independent of HTTP transport. Live SSE and
/// mislabeled, buffered SSE must resolve tool identities through the same path.
nonisolated struct AgentProviderResponseParser {
    let format: ModelAPIFormat
    let wireNames: [String: String]
    let buffered: Bool

    private var chatCallIDs: [Int: String] = [:]
    private var anthropicState = AnthropicStreamState()
    private var responseCallIDs: [String: String] = [:]
    private var responseCallNames: [String: String] = [:]
    private var reachedEndMarker = false
    private(set) var hasFinished = false

    init(format: ModelAPIFormat, wireNames: [String: String], buffered: Bool) {
        self.format = format
        self.wireNames = wireNames
        self.buffered = buffered
    }

    /// Live Chat Completions can report usage after finish_reason. Only a
    /// buffered caller stops there; live callers keep reading until [DONE].
    var shouldStop: Bool { reachedEndMarker || (buffered && hasFinished) }
    var isTerminated: Bool { reachedEndMarker || hasFinished }

    mutating func consume(_ event: SSEEvent) throws -> [AgentModelStreamEvent] {
        guard !event.data.isEmpty else { return [] }
        if event.data == "[DONE]" {
            reachedEndMarker = true
            return []
        }
        guard let root = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
            if buffered { throw AgentProviderError.invalidResponse }
            return []
        }
        // Gateways commonly omit the SSE event field and use the JSON type.
        let eventType = AgentProviderResponseDecoder.streamEventType(event, root: root)
        if eventType == "error" || eventType == "response.failed" {
            throw Self.streamFailure(in: root)
        }
        let events: [AgentModelStreamEvent]
        switch format {
        case .responses:
            if eventType == "response.completed", root["response"] as? [String: Any] == nil {
                throw AgentProviderError.invalidResponse
            }
            events = AgentProviderResponseDecoder.parseResponses(
                eventType, root, callIDs: &responseCallIDs, callNames: &responseCallNames
            )
        case .chatCompletions:
            events = AgentProviderResponseDecoder.parseChat(root, callIDs: &chatCallIDs, wireNames: wireNames)
        case .messages:
            events = AgentProviderResponseDecoder.parseAnthropic(
                eventType, root, state: &anthropicState, wireNames: wireNames
            )
        case .generateContent:
            events = AgentProviderResponseDecoder.parseGoogle(root, wireNames: wireNames)
        }
        recordTermination(in: events)
        return events
    }

    /// Some gateways accept streaming requests but return JSON, or label an SSE
    /// body as JSON. Keep the same state and validation for that fallback.
    mutating func parseResponse(_ data: Data) throws -> [AgentModelStreamEvent] {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let failure = Self.explicitFailure(in: root) { throw failure }
            let events: [AgentModelStreamEvent]
            switch format {
            case .responses: events = AgentProviderResponseDecoder.parseCompletedResponses(root)
            case .chatCompletions: events = AgentProviderResponseDecoder.parseChat(root, wireNames: wireNames)
            case .messages: events = AgentProviderResponseDecoder.parseCompletedAnthropic(root, wireNames: wireNames)
            case .generateContent: events = AgentProviderResponseDecoder.parseGoogle(root, wireNames: wireNames)
            }
            recordTermination(in: events)
            return events
        }

        var output: [AgentModelStreamEvent] = []
        for event in SSEStream.events(in: data) {
            output += try consume(event)
            if shouldStop { break }
        }
        guard !output.isEmpty else { throw AgentProviderError.invalidResponse }
        return output
    }

    private mutating func recordTermination(in events: [AgentModelStreamEvent]) {
        if events.contains(where: { if case .finished = $0 { true } else { false } }) {
            hasFinished = true
        }
    }

    private static func explicitFailure(in root: [String: Any]) -> AgentProviderStreamFailure? {
        let response = root["response"] as? [String: Any]
        guard
            root["type"] as? String == "error"
                || root["type"] as? String == "response.failed"
                || response?["status"] as? String == "failed"
                || root["error"] != nil
        else { return nil }
        return streamFailure(in: root)
    }

    private static func streamFailure(in root: [String: Any]) -> AgentProviderStreamFailure {
        let response = root["response"] as? [String: Any]
        let error = (response?["error"] ?? root["error"]) as? [String: Any]
        let code = (error?["code"] ?? error?["type"] ?? root["code"]) as? String
        let message =
            error?["message"] as? String
            ?? response?["error"] as? String
            ?? root["message"] as? String
            ?? String(localized: "The model provider failed to complete the response.", bundle: .module)
        return AgentProviderStreamFailure(code: code, message: message)
    }
}

nonisolated struct AgentProviderStreamFailure: LocalizedError, Sendable {
    let code: String?
    let message: String

    var isRetryable: Bool {
        guard let code = code?.lowercased() else { return false }
        return [
            "api_error",
            "internal_error",
            "internal_server_error",
            "overloaded_error",
            "rate_limit_error",
            "rate_limit_exceeded",
            "server_error",
            "temporarily_unavailable",
        ].contains(code)
    }

    var errorDescription: String? { message }
}
