import Foundation

/// One readable page, however it was obtained.
///
/// `markdown` is what `fetch` returns by default and what `web_search` returns
/// per hit; `original` is the untransformed body, for the caller that asked for
/// it. Both are carried rather than one being derived here, because deriving
/// Markdown from HTML well is exactly the job of whichever client the host
/// supplied.
public nonisolated struct AgentWebDocument: Hashable, Sendable {
    public init(
        engine: String? = nil,
        title: String,
        url: URL,
        markdown: String,
        original: String
    ) {
        self.engine = engine
        self.title = title
        self.url = url
        self.markdown = markdown
        self.original = original
    }

    public var engine: String? = nil
    public var title: String
    public var url: URL
    public var markdown: String
    public var original: String
}

public nonisolated enum AgentWebError: LocalizedError, Sendable {
    case invalidURL
    case emptyDocument
    case emptyQuery

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The webpage URL must be an HTTP or HTTPS URL without embedded credentials."
        case .emptyDocument:
            "No readable content could be extracted from the webpage."
        case .emptyQuery:
            "query is required."
        }
    }
}

/// The URL rule the web tools enforce before anything is dialed.
///
/// Local, and ahead of the client rather than inside it: a host that plugs in
/// its own fetcher inherits the same refusal of non-HTTP schemes and of
/// credentials smuggled into the authority, because the tool checks before it
/// ever calls out.
public nonisolated enum AgentWebAddress {
    public static func validated(_ rawURL: String) throws -> URL {
        guard let url = URL(string: rawURL),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            url.host?.isEmpty == false, url.user == nil, url.password == nil
        else { throw AgentWebError.invalidURL }
        return url
    }
}

/// How `fetch` and `scratch_fetch` reach a page.
///
/// A protocol because there is no one right answer: a headless renderer, a
/// readability extractor, and a plain `URLSession` GET are all defensible, and
/// which one an app wants depends on what its users point it at. The runtime
/// ships no implementation for the same reason — the tools are offered only when
/// a host supplies one.
public nonisolated protocol AgentWebFetching: Sendable {
    func document(for rawURL: String) async throws -> AgentWebDocument
}

/// How `web_search` reaches a search engine.
///
/// Separate from fetching, and separately optional, because most providers now
/// search on their own servers. A run that uses the provider's native search
/// supplies a fetcher and no searcher, and `web_search` is simply absent from
/// its registry rather than present and redundant.
public nonisolated protocol AgentWebSearching: Sendable {
    func search(_ query: String, count: Int) async throws -> [AgentWebDocument]
}
