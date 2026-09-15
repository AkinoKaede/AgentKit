import Foundation

/// A provider-neutral request for schema-constrained final text.
///
/// Adapters that know the selected model supports structured output translate
/// this to their native wire shape. Other models simply receive the prompt and
/// remain protected by the caller's local decoder.
public nonisolated struct AgentModelOutputFormat: Hashable, Sendable {
    public init(name: String, schema: AgentJSONValue, strict: Bool = false) {
        self.name = name
        self.schema = schema
        self.strict = strict
    }

    public var name: String
    public var schema: AgentJSONValue
    public var strict: Bool
}

public nonisolated struct AgentModelRequest: Sendable {
    public init(
        systemPrompt: String,
        messages: [AgentTranscriptMessage],
        tools: [AgentToolDescriptor],
        outputFormat: AgentModelOutputFormat? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.outputFormat = outputFormat
    }

    public var systemPrompt: String
    public var messages: [AgentTranscriptMessage]
    public var tools: [AgentToolDescriptor]
    public var outputFormat: AgentModelOutputFormat?
}

public nonisolated enum AgentModelStreamEvent: Sendable {
    case textDelta(String)
    /// Authoritative complete text used by buffered/final provider responses.
    case textSnapshot(String)
    /// Provider-authored reasoning summary/thinking, distinct from answer text.
    case reasoningDelta(String)
    /// Authoritative complete reasoning text used by buffered/final responses.
    case reasoningSnapshot(String)
    case toolCallDelta(id: String, name: String?, arguments: String)
    /// The authoritative completed tool call. Arguments replace, rather than
    /// append to, the partial streaming buffer.
    case toolCallSnapshot(
        id: String, providerItemID: String?, name: String, arguments: String
    )
    case providerItem(AgentJSONValue)
    /// A search the provider ran itself. Distinct from `providerItem`, which is
    /// the *replay* channel and must stay byte-shaped the way its provider
    /// sent it; this one is normalized for display and is never sent back.
    case webSearch(AgentWebSearchActivity)
    /// What this round trip cost. Providers report it at different moments and
    /// more than once — see `AgentTokenUsage.merging(_:)`, which is how a reader
    /// folds several of these into one turn's answer.
    case usage(AgentTokenUsage)
    case finished(AgentStopReason)
}

/// Backoff applied when one logical model turn loses its provider connection.
///
/// Each duration is one retry after the initial request. An empty list disables
/// retries, which is the default for callers that use `AgentTurnDriver`
/// directly rather than through `AgentRuntime`.
public nonisolated struct AgentModelRetryPolicy: Equatable, Sendable {
    public var delays: [Duration]

    public init(
        delays: [Duration] = [
            .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16),
        ]
    ) {
        self.delays = delays
    }

    public static let disabled = AgentModelRetryPolicy(delays: [])

    public func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt > 0, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

/// Ephemeral progress for a provider retry inside one logical model turn.
public nonisolated struct AgentModelRetryProgress: Hashable, Sendable {
    public var runID: UUID
    public var messageID: AgentTranscriptMessage.ID
    public var attempt: Int
    public var maximumAttempts: Int

    public init(
        runID: UUID,
        messageID: AgentTranscriptMessage.ID,
        attempt: Int,
        maximumAttempts: Int
    ) {
        self.runID = runID
        self.messageID = messageID
        self.attempt = attempt
        self.maximumAttempts = maximumAttempts
    }
}

/// The provider boundary — Pi's `streamFn`. Everything above it works in
/// `AgentTranscriptMessage`; everything below it speaks one vendor's wire
/// format. Swapping providers, proxying through a server, or scripting a run in
/// a test are all the same substitution.
public nonisolated protocol AgentModelStreaming: Sendable {
    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error>
    /// Whether dispatching the same request again can recover this failure.
    func shouldRetry(after error: any Error) -> Bool
}

nonisolated extension AgentModelStreaming {
    public func shouldRetry(after _: any Error) -> Bool { false }
}

/// A single buffered model response. Short, tool-free features use this path so
/// their success does not depend on SSE framing or a provider-specific [DONE]
/// event.
public nonisolated protocol AgentModelCompleting: Sendable {
    func complete(_ request: AgentModelRequest) async throws -> [AgentModelStreamEvent]
}

public nonisolated struct AgentBufferedTextResponse: Sendable {
    public init(
        text: String,
        stopReason: AgentStopReason? = nil
    ) {
        self.text = text
        self.stopReason = stopReason
    }

    public var text: String
    public var stopReason: AgentStopReason?
}

public nonisolated enum AgentBufferedTextError: Error, Sendable {
    case toolCall
    case responseTooLarge
}
nonisolated

    extension AgentModelCompleting
{
    public func collectText(
        _ request: AgentModelRequest, maximumBytes: Int? = nil
    ) async throws -> AgentBufferedTextResponse {
        var response = AgentBufferedTextResponse(text: "", stopReason: nil)
        for event in try await complete(request) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
                if let maximumBytes,
                    response.text.utf8.count + delta.utf8.count > maximumBytes
                {
                    throw AgentBufferedTextError.responseTooLarge
                }
                response.text += delta
            case .textSnapshot(let snapshot):
                if let maximumBytes, snapshot.utf8.count > maximumBytes {
                    throw AgentBufferedTextError.responseTooLarge
                }
                response.text = snapshot
            case .toolCallDelta, .toolCallSnapshot:
                throw AgentBufferedTextError.toolCall
            case .finished(let reason):
                response.stopReason = reason
            case .reasoningDelta, .reasoningSnapshot, .providerItem, .webSearch, .usage:
                continue
            }
        }
        return response
    }
}
