import AgentKit
import Foundation
import ScrubberKit

/// A ready-made `AgentWebFetching` and `AgentWebSearching`, backed by
/// [ScrubberKit](https://github.com/Lakr233/ScrubberKit).
///
/// In its own product because the core deliberately has no opinion about how a
/// page becomes readable text, and no adopter should inherit WebKit for a
/// decision they may want to make differently. Take it when you want `fetch` and
/// `web_search` to work today; write your own conformance when you have a
/// reader, a proxy, or a search API of your own.
///
/// It is not a default in any sense the runtime knows about. A model that can
/// search on the provider's own servers should usually be allowed to — that
/// search is better and costs no round trip — and `web_search` is for the models
/// and deployments where that is not available.
///
/// The injectable closures keep tool tests deterministic without replacing the
/// package or reaching the public web. The live implementation is MainActor-only
/// because ScrubberKit owns `WKWebView` instances internally.
public nonisolated struct ScrubberWebClient: AgentWebFetching, AgentWebSearching, Sendable {
    public typealias DocumentLoader = @Sendable (URL) async throws -> AgentWebDocument
    public typealias SearchLoader = @Sendable (String, Int) async throws -> [AgentWebDocument]

    private let documentLoader: DocumentLoader
    private let searchLoader: SearchLoader

    public init() {
        documentLoader = { try await Self.loadDocument($0) }
        searchLoader = { try await Self.runSearch(query: $0, count: $1) }
    }

    public init(document: @escaping DocumentLoader, search: @escaping SearchLoader) {
        documentLoader = document
        searchLoader = search
    }

    /// Call once, before the first fetch. ScrubberKit configures process-wide
    /// state, so this belongs at launch rather than at the first tool call.
    @MainActor
    public static func setup() {
        ScrubberConfiguration.setup()
    }

    public func document(for rawURL: String) async throws -> AgentWebDocument {
        let url = try AgentWebAddress.validated(rawURL)
        try Task.checkCancellation()
        let document = try await documentLoader(url)
        try Task.checkCancellation()
        return document
    }

    public func search(_ query: String, count: Int) async throws -> [AgentWebDocument] {
        try Task.checkCancellation()
        let documents = try await searchLoader(query, count)
        try Task.checkCancellation()
        return documents
    }

    @MainActor
    private static func loadDocument(_ url: URL) async throws -> AgentWebDocument {
        let document: Scrubber.Document? = await withCheckedContinuation { continuation in
            Scrubber.document(for: url) { continuation.resume(returning: $0) }
        }
        guard let document else { throw AgentWebError.emptyDocument }
        return AgentWebDocument(
            engine: document.engine?.rawValue,
            title: document.title,
            url: document.url,
            markdown: document.markdownDocument,
            original: document.document
        )
    }

    @MainActor
    private static func runSearch(query: String, count: Int) async throws
        -> [AgentWebDocument]
    {
        let scrubber = Scrubber(
            query: query,
            options: .init(urlsReranker: URLsReranker(question: query))
        )
        return await withTaskCancellationHandler {
            let documents: [Scrubber.Document] = await withCheckedContinuation { continuation in
                scrubber.run(limitation: count) { continuation.resume(returning: $0) }
            }
            return documents.prefix(count).map {
                AgentWebDocument(
                    engine: $0.engine?.rawValue,
                    title: $0.title,
                    url: $0.url,
                    markdown: $0.markdownDocument,
                    original: $0.document
                )
            }
        } onCancel: {
            Task { @MainActor in scrubber.cancel() }
        }
    }
}
