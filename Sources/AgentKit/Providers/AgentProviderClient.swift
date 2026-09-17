import Foundation

/// Provider-neutral streaming client. It keeps each provider's native message/tool
/// envelope at the boundary while exposing one event stream to AgentRuntime.
public nonisolated struct AgentProviderClient: AgentModelStreaming, Sendable {
    private let provider: ModelProvider
    private let model: AIModel
    private let secret: String
    private let reasoning: ReasoningEffort
    /// Ask the provider to run web search on its own servers this turn.
    ///
    /// Off by default so the short, tool-free callers — titling, compaction,
    /// Guardian — cannot acquire it by accident. Turn it on only after
    /// checking both the model's ability and
    /// `ModelProvider.supportsNativeWebSearch`.
    private let webSearch: Bool
    private let session: URLSession
    private let promptCacheKey: String?

    public init(
        provider: ModelProvider,
        model: AIModel,
        secret: String,
        reasoning: ReasoningEffort = .medium,
        webSearch: Bool = false,
        promptCacheKey: String? = nil,
        session: URLSession? = nil
    ) {
        self.provider = provider
        self.model = model
        self.secret = secret
        self.reasoning = reasoning
        self.webSearch = webSearch
        self.promptCacheKey = promptCacheKey.map { String($0.prefix(64)) }
        self.session = session ?? Self.shared
    }

    /// One session for every agent request.
    ///
    /// A `URLSession` keeps itself alive until it is invalidated, and a client
    /// is built per run — and again per Guardian — so making one here
    /// leaked a session, its connection pool, and its delegate queue on every
    /// turn. Sharing it also lets a multi-turn run reuse the connection it
    /// already has open.
    private static let shared = ProviderNetworking.session(timeout: 120)

    public func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await receive(request, buffered: false) { item in
                        continuation.yield(item)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func shouldRetry(after error: any Error) -> Bool {
        if let error = error as? URLError {
            return Self.retryableURLCodes.contains(error.code)
        }
        if let error = error as? AgentProviderStreamFailure {
            return error.isRetryable
        }
        if let error = error as? AgentProviderError {
            if case .http(let status, _) = error {
                return status == 408 || status == 429 || (500..<600).contains(status)
            }
            return false
        }
        if let error = error as? GoogleAuthError {
            if case .transport = error { return true }
        }
        return false
    }

    private static let retryableURLCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .networkConnectionLost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .resourceUnavailable,
        .internationalRoamingOff,
        .callIsActive,
        .dataNotAllowed,
        .backgroundSessionWasDisconnected,
    ]

    /// Uses streaming transport even when the caller needs one complete result.
    /// Partial results are discarded on cancellation, malformed data, or a dropped stream.
    public func complete(_ request: AgentModelRequest) async throws -> [AgentModelStreamEvent] {
        var events: [AgentModelStreamEvent] = []
        try await receive(request, buffered: true) { events.append($0) }
        try Task.checkCancellation()
        return events
    }

    private static let maximumResponseBytes = 16 * 1024 * 1024

    /// One transport and provider parser for live events and buffered results.
    /// Only buffered SSE results have a total byte cap and require a terminal event.
    /// Parsing state is recreated per request, including provider retries.
    private func receive(
        _ request: AgentModelRequest, buffered: Bool,
        emit: (AgentModelStreamEvent) -> Void
    ) async throws {
        try Task.checkCancellation()
        let toolNames = AgentProviderToolNameMap.flat(request.tools)
        var parser = AgentProviderResponseParser(
            format: provider.apiFormat, wireNames: toolNames.wireToQualified, buffered: buffered
        )
        var urlRequest = try buildRequest(request, streaming: true)
        try await ProviderNetworking.authorize(
            &urlRequest, provider: provider, secret: secret, omittingEmptyCredential: true
        )
        let (bytes, response) = try await session.bytes(for: urlRequest)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw AgentProviderError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentProviderError.http(
                http.statusCode, await Self.errorBody(bytes)
            )
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("application/json") || contentType.contains("+json") {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else {
                    throw AgentProviderError.responseTooLarge
                }
                data.append(byte)
            }
            let events = try parser.parseResponse(data)
            if buffered, !parser.isTerminated {
                throw AgentProviderError.invalidResponse
            }
            for event in events { emit(event) }
            return
        }

        do {
            try await SSEStream.consume(
                from: bytes, maximumBytes: buffered ? Self.maximumResponseBytes : nil
            ) { event in
                for item in try parser.consume(event) { emit(item) }
                return parser.shouldStop
            }
        } catch SSEStream.ReadError.responseTooLarge {
            throw AgentProviderError.responseTooLarge
        }
        if buffered, !parser.isTerminated { throw AgentProviderError.invalidResponse }
    }

    /// Reads only as much of a failed response as the message will show.
    ///
    /// The success paths are capped; this one drained the whole body first and
    /// then took its first 4 KB, so a gateway answering an error with an endless
    /// stream could be read until the process ran out of memory.
    private static func errorBody<Bytes: AsyncSequence & Sendable>(
        _ bytes: Bytes
    ) async -> String where Bytes.Element == UInt8 {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 4_096 { break }
            }
        } catch {
            // A truncated error body still describes the failure better than
            // the transport error that interrupted reading it.
        }
        return String(decoding: data, as: UTF8.self)
    }

    private var requestEncoder: AgentProviderRequestEncoder {
        AgentProviderRequestEncoder(
            provider: provider, model: model, reasoning: reasoning,
            webSearch: webSearch, promptCacheKey: promptCacheKey
        )
    }

    public func buildRequest(_ input: AgentModelRequest, streaming: Bool) throws -> URLRequest {
        try requestEncoder.buildRequest(input, streaming: streaming)
    }

    public func body(_ request: AgentModelRequest) -> [String: Any] {
        body(request, streaming: true)
    }

    public func body(_ request: AgentModelRequest, streaming: Bool) -> [String: Any] {
        requestEncoder.body(request, streaming: streaming)
    }

    /// The per-turn ceiling used by Anthropic's native search tool.
    public static let nativeWebSearchMaxUses = AgentProviderRequestEncoder.nativeWebSearchMaxUses
}

extension AgentProviderClient: AgentModelCompleting {}

// Preserve the public adapter APIs while keeping protocol decoding independent
// of the HTTP client. New runtime code uses AgentProviderResponseParser.
nonisolated extension AgentProviderClient {
    /// Converts semantic optionals to OpenAI's required-but-nullable wire schema.
    /// The provider-neutral schema is left unchanged for local validation.
    public static func openAIStrictSchema(_ schema: AgentJSONValue) -> AgentJSONValue {
        AgentProviderRequestEncoder.openAIStrictSchema(schema)
    }

    public static func streamEventType(_ event: SSEEvent, root: [String: Any]) -> String {
        AgentProviderResponseDecoder.streamEventType(event, root: root)
    }

    public static func parseResponses(_ type: String, _ root: [String: Any]) -> [AgentModelStreamEvent] {
        AgentProviderResponseDecoder.parseResponses(type, root)
    }

    public static func parseResponses(
        _ type: String, _ root: [String: Any],
        callIDs: inout [String: String], callNames: inout [String: String]
    ) -> [AgentModelStreamEvent] {
        AgentProviderResponseDecoder.parseResponses(type, root, callIDs: &callIDs, callNames: &callNames)
    }

    public static func parseCompletedResponses(_ root: [String: Any]) -> [AgentModelStreamEvent] {
        AgentProviderResponseDecoder.parseCompletedResponses(root)
    }

    public static func parseChat(
        _ root: [String: Any], wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        AgentProviderResponseDecoder.parseChat(root, wireNames: wireNames)
    }

    public static func parseChat(
        _ root: [String: Any], callIDs: inout [Int: String], wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        AgentProviderResponseDecoder.parseChat(root, callIDs: &callIDs, wireNames: wireNames)
    }

    public static func parseCompletedAnthropic(
        _ root: [String: Any], wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        AgentProviderResponseDecoder.parseCompletedAnthropic(root, wireNames: wireNames)
    }

    public static func parseAnthropic(_ type: String, _ root: [String: Any]) -> [AgentModelStreamEvent] {
        AgentProviderResponseDecoder.parseAnthropic(type, root)
    }

    public static func parseAnthropic(
        _ type: String, _ root: [String: Any], state: inout AnthropicStreamState,
        wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        AgentProviderResponseDecoder.parseAnthropic(type, root, state: &state, wireNames: wireNames)
    }

    public static func parseGoogle(
        _ root: [String: Any], wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        AgentProviderResponseDecoder.parseGoogle(root, wireNames: wireNames)
    }
}

public nonisolated enum AgentProviderError: LocalizedError, Sendable {
    case badURL, notHTTP, invalidResponse, responseTooLarge
    case http(Int, String)
    public var errorDescription: String? {
        switch self {
        case .badURL: String(localized: "The model endpoint URL is invalid.", bundle: .module)
        case .notHTTP: String(localized: "The model endpoint did not return HTTP.", bundle: .module)
        case .invalidResponse:
            String(localized: "The model endpoint returned an unsupported response format.", bundle: .module)
        case .responseTooLarge:
            String(localized: "The model response exceeded the size limit.", bundle: .module)
        case .http(let status, let body):
            String(localized: "The model endpoint returned \(status): \(body)", bundle: .module)
        }
    }
}
