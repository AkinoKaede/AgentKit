import Foundation
import Synchronization
import Testing

@testable import AgentKit

private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let body: String
        var status = 200
    }

    struct State: Sendable {
        var replies: [Reply] = []
        var requests: [URLRequest] = []
    }

    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "catalog.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.state.withLock { state in
            let index = state.requests.count
            state.requests.append(request)
            return state.replies[min(index, state.replies.count - 1)]
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct ModelCatalogPaginationTests {
    private func session(_ replies: [CatalogURLProtocol.Reply]) -> URLSession {
        precondition(!replies.isEmpty)
        CatalogURLProtocol.state.withLock { $0 = CatalogURLProtocol.State(replies: replies) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func provider(_ format: ModelAPIFormat) -> ModelProvider {
        ModelProvider(name: "Catalog", apiFormat: format, baseURL: "https://catalog.test/v1")
    }

    private func page(id: String, hasMore: Bool, cursor: String?) throws -> String {
        var body: [String: Any] = [
            "data": [["id": id]],
            "models": [["name": "models/\(id)", "supportedGenerationMethods": ["generateContent"]]],
            "has_more": hasMore,
        ]
        if let cursor {
            body["last_id"] = cursor
            body["nextPageToken"] = cursor
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    private func assertAuthorization(_ requests: [URLRequest], format: ModelAPIFormat) {
        for request in requests {
            switch format {
            case .messages:
                #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
                #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            case .generateContent:
                #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "secret")
            case .chatCompletions, .responses:
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            }
        }
    }

    @Test(arguments: [ModelAPIFormat.messages, .generateContent])
    func followsEachPageCursorAndPreservesPageOrder(_ format: ModelAPIFormat) async throws {
        let firstCursor = "first /+&=?"
        let secondCursor = "second /+&=?"
        let session = session([
            .init(body: try page(id: "first", hasMore: true, cursor: firstCursor)),
            .init(body: try page(id: "second", hasMore: true, cursor: secondCursor)),
            .init(body: try page(id: "third", hasMore: false, cursor: nil)),
        ])
        defer { session.invalidateAndCancel() }
        let models = try await ModelCatalogClient(session: session).models(for: provider(format), secret: "secret")
        #expect(models.map(\.id) == ["first", "second", "third"])
        let requests = CatalogURLProtocol.state.withLock { $0.requests }
        #expect(requests.count == 3)
        let size = format == .messages ? "limit" : "pageSize"
        let cursor = format == .messages ? "after_id" : "pageToken"
        let expectedCursors: [String?] = [nil, firstCursor, secondCursor]
        for (request, expectedCursor) in zip(requests, expectedCursors) {
            let url = try #require(request.url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var expected = [URLQueryItem(name: size, value: "100")]
            if let value = expectedCursor { expected.append(URLQueryItem(name: cursor, value: value)) }
            #expect(items == expected)
        }
        assertAuthorization(requests, format: format)
    }

    @Test(arguments: ModelAPIFormat.allCases, [false, true])
    func cursorRulesAndTwentyPageCapRemainProviderSpecific(_ format: ModelAPIFormat, _ hasMore: Bool) async throws {
        let cursors: [String?] = [nil, "", "repeated"]
        for cursor in cursors {
            let session = session([.init(body: try page(id: "same", hasMore: hasMore, cursor: cursor))])
            defer { session.invalidateAndCancel() }
            let models = try await ModelCatalogClient(session: session).models(for: provider(format), secret: "secret")
            let expectedCount: Int
            switch format {
            case .messages: expectedCount = hasMore && cursor != nil ? 20 : 1
            case .generateContent: expectedCount = cursor?.isEmpty == false ? 20 : 1
            case .chatCompletions, .responses: expectedCount = 1
            }
            let requests = CatalogURLProtocol.state.withLock { $0.requests }
            #expect(requests.count == expectedCount)
            #expect(models.map(\.id) == Array(repeating: "same", count: expectedCount))
            assertAuthorization(requests, format: format)
            if format == .messages, hasMore, cursor == "", requests.count > 1 {
                let url = try #require(requests[1].url)
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                #expect(items?.contains(URLQueryItem(name: "after_id", value: "")) == true)
            }
        }
    }

    @Test(arguments: [ModelAPIFormat.messages, .generateContent])
    func laterPageFailureThrowsInsteadOfReturningPartialModels(_ format: ModelAPIFormat) async throws {
        let session = session([
            .init(body: try page(id: "first", hasMore: true, cursor: "next")),
            .init(body: #"{"error":"unauthorized"}"#, status: 401),
        ])
        defer { session.invalidateAndCancel() }
        await #expect(throws: ModelCatalogError.self) {
            try await ModelCatalogClient(session: session).models(for: provider(format), secret: "secret")
        }
        let requests = CatalogURLProtocol.state.withLock { $0.requests }
        #expect(requests.count == 2)
        assertAuthorization(requests, format: format)
    }
}
