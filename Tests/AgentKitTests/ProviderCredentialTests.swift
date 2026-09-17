import Foundation
import Synchronization
import Testing

@testable import AgentKit

private final class CredentialURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "credentials.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let status = Int(request.url!.pathComponents[1]) ?? 200
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        // Each adapter reads its own response shape from this combined fixture.
        let body = """
            {"data":[{"id":"test"}],
             "models":[{"name":"models/test","supportedGenerationMethods":["generateContent"]}],
             "object":"response","status":"completed",
             "output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}],
             "type":"message","content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn",
             "choices":[{"message":{"content":"OK"},"finish_reason":"stop"}],
             "candidates":[{"content":{"parts":[{"text":"OK"}]},"finishReason":"STOP"}]}
            """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct ProviderCredentialTests {
    private func session() -> URLSession {
        CredentialURLProtocol.requests.withLock { $0.removeAll() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func provider(_ format: ModelAPIFormat, status: Int = 200) -> ModelProvider {
        ModelProvider(
            name: "Gateway", apiFormat: format,
            inferenceURL: "http://credentials.test/\(status)/models/test:generateContent",
            baseURL: "http://credentials.test/\(status)"
        )
    }

    @Test(arguments: ModelAPIFormat.allCases, ["", "test-secret"])
    func discoveryProbeAndInferenceUseOnlyExplicitCredentials(_ format: ModelAPIFormat, _ secret: String) async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = provider(format)
        #expect(!provider.hasCredential)
        #expect(provider.canFetchModels)
        let models = try await ModelCatalogClient(session: session).models(for: provider, secret: secret)
        #expect(models.map(\.id) == ["test"])
        let probe = try await ChatProbe(session: session).run(model: AIModel(id: "test"), on: provider, secret: secret)
        #expect(probe.reply == "OK")
        let client = AgentProviderClient(
            provider: provider, model: AIModel(id: "test"), secret: secret, session: session)
        let input = AgentModelRequest(systemPrompt: "Hello", messages: [], tools: [])
        #expect(try await client.collectText(input).text == "OK")
        var streamed = ""
        for try await event in client.stream(input) {
            if case .textDelta(let text) = event { streamed += text }
            if case .textSnapshot(let text) = event { streamed = text }
        }
        #expect(streamed == "OK")
        let requests = CredentialURLProtocol.requests.withLock { $0 }
        #expect(requests.count == 4)
        for request in requests {
            let bearer = !secret.isEmpty && (format == .chatCompletions || format == .responses)
            #expect(request.value(forHTTPHeaderField: "Authorization") == (bearer ? "Bearer \(secret)" : nil))
            #expect(
                request.value(forHTTPHeaderField: "x-api-key")
                    == (!secret.isEmpty && format == .messages ? secret : nil))
            #expect(
                request.value(forHTTPHeaderField: "x-goog-api-key")
                    == (!secret.isEmpty && format == .generateContent ? secret : nil))
            if format == .messages {
                #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            }
        }
    }

    @Test(arguments: [401, 403], ["", "test-secret"])
    func authenticationFailuresDoNotRetryWithoutCredentials(_ status: Int, _ secret: String) async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = provider(.chatCompletions, status: status)
        await #expect(throws: ModelCatalogError.self) {
            try await ModelCatalogClient(session: session).models(for: provider, secret: secret)
        }
        await #expect(throws: ModelCatalogError.self) {
            try await ChatProbe(session: session).run(model: AIModel(id: "test"), on: provider, secret: secret)
        }
        let client = AgentProviderClient(
            provider: provider, model: AIModel(id: "test"), secret: secret, session: session)
        await #expect(throws: AgentProviderError.self) {
            try await client.complete(AgentModelRequest(systemPrompt: "Hello", messages: [], tools: []))
        }
        #expect(!client.shouldRetry(after: AgentProviderError.http(status, "")))
        #expect(CredentialURLProtocol.requests.withLock { $0.count } == 3)
    }

    @Test func vertexStillRequiresServiceAccountAuthentication() async {
        var provider = provider(.generateContent)
        provider.usesVertex = true
        #expect(!provider.canFetchModels)
        await #expect(throws: GoogleAuthError.self) {
            var request = URLRequest(url: URL(string: "https://credentials.test")!)
            try await ProviderNetworking.authorize(
                &request, provider: provider, secret: "", omittingEmptyCredential: true)
        }
    }
}
