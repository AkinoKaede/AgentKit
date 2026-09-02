import Foundation

public nonisolated struct FetchTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.fetch", present: present
    )
    private let web: any AgentWebFetching
    public init(web: any AgentWebFetching) { self.web = web }

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "fetch",
            "Read an HTTP(S) webpage, including private-network pages. Returns Markdown by "
                + "default, or the original HTML when format is original.",
            properties: [
                "url": Self.string(max: 8_192),
                "format": Self.enumeration(["markdown", "original"]),
            ],
            required: ["url"], target: .network, safety: .locallyReadOnly,
            concurrency: .parallel,
            presentation: .init(
                symbol: "globe", activity: .semanticArgument(key: "url", fallback: .url),
                output: .field("content"), actionKind: .fetch
            )
        )
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        _ = try AgentWebAddress.validated(Arguments(invocation).string("url"))
        return AgentToolPreflight(invocation: invocation, safety: .locallyReadOnly)
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        let document = try await web.document(for: arguments.string("url"))
        let format = arguments.optionalString("format") ?? "markdown"
        let selected = format == "original" ? document.original : document.markdown
        let content = AgentToolSupport.bounded(selected, maximumBytes: 256 * 1_024)
        return Self.result(
            invocation,
            .object([
                "title": .string(document.title), "url": .string(document.url.absoluteString),
                "format": .string(format), "content": .string(content.text),
                "truncated": .bool(content.truncated),
            ]), truncated: content.truncated)
    }
}

public nonisolated struct WebSearchTool: AgentToolDefinition, AgentToolSchemaBuilding {
    public static let presenter = AgentToolDetailPresenter(
        id: "builtin.web_search", present: present
    )
    public static var presentation: AgentToolDescriptor.Presentation {
        .init(
            symbol: "magnifyingglass",
            activity: .semanticArgument(key: "query", fallback: .web), output: .json,
            presenterID: presenter.id, actionKind: .search
        )
    }
    private let web: any AgentWebSearching
    public init(web: any AgentWebSearching) { self.web = web }

    public var descriptor: AgentToolDescriptor {
        Self.descriptor(
            "web_search",
            "Search Google, Bing, DuckDuckGo, and Yahoo, then return readable Markdown from the "
                + "result pages.",
            properties: ["query": Self.string(max: 1_024), "count": Self.integer(min: 1, max: 5)],
            required: ["query"], target: .network, safety: .locallyReadOnly,
            concurrency: .parallel,
            presentation: Self.presentation
        )
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        _ = try Self.query(Arguments(invocation))
        return AgentToolPreflight(invocation: invocation, safety: .locallyReadOnly)
    }

    /// Rejected here rather than inside whichever client the host supplied: a
    /// blank query is a malformed call, and the answer to one is the same
    /// wherever the search would have gone.
    private static func query(_ arguments: Arguments) throws -> String {
        let trimmed = try arguments.string("query")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentWebError.emptyQuery }
        return trimmed
    }

    public func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult
    {
        let arguments = try Arguments(invocation)
        let rows = try await web.search(
            Self.query(arguments), count: arguments.optionalInt("count") ?? 5
        )
        let limit = 32 * 1_024
        return Self.result(
            invocation,
            .array(
                rows.map { row in
                    let markdown = AgentToolSupport.bounded(row.markdown, maximumBytes: limit)
                    return .object([
                        "engine": row.engine.map(AgentJSONValue.string) ?? .null,
                        "title": .string(row.title), "url": .string(row.url.absoluteString),
                        "markdown": .string(markdown.text), "truncated": .bool(markdown.truncated),
                    ])
                }), truncated: rows.contains { $0.markdown.utf8.count > limit })
    }
}
nonisolated

    extension FetchTool
{
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            if let title = F.nonempty(object["title"]?.stringValue) {
                items.append(F.field("Title", title, locale: input.locale))
            }
            if let url = F.nonempty(object["url"]?.stringValue) {
                items.append(
                    .field(
                        .init(
                            label: F.localized("URL", locale: input.locale), value: url,
                            isMonospaced: true, url: url
                        )))
            }
            let format = object["format"]?.stringValue ?? "markdown"
            let content = object["content"]?.stringValue ?? ""
            items.append(
                content.isEmpty
                    ? .message(F.localized("No readable page content", locale: input.locale), .secondary)
                    : .text(
                        .init(
                            title: F.localized(
                                format == "original" ? "Original HTML" : "Markdown",
                                locale: input.locale),
                            text: content, style: .plain
                        )))
            return items
        }
    }
}
nonisolated

    extension WebSearchTool
{
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        return F.arrayItems(input) { values in
            let rows = values.compactMap { entry -> AgentToolDetail.ListRow? in
                guard let object = entry.objectValue else { return nil }
                let url = F.nonempty(object["url"]?.stringValue)
                let title =
                    F.nonempty(object["title"]?.stringValue) ?? url
                    ?? F.localized("Untitled result", locale: input.locale)
                let engine = F.nonempty(object["engine"]?.stringValue)
                let truncated =
                    object["truncated"]?.boolValue == true
                    ? F.localized("Truncated", locale: input.locale) : nil
                return .init(
                    title: title, subtitle: url,
                    detail: [engine, truncated].compactMap { $0 }.joined(separator: " · "),
                    symbol: "link", url: url
                )
            }
            return [
                .message(String(localized: "\(rows.count) results", bundle: .module, locale: input.locale), .secondary),
                .list(
                    .init(
                        title: nil, rows: rows,
                        emptyMessage: F.localized("No results", locale: input.locale)
                    )),
            ]
        }
    }
}
nonisolated

    extension AgentToolSupport
{
    fileprivate static func bounded(
        _ text: String, maximumBytes: Int
    ) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maximumBytes else { return (text, false) }
        return (String(decoding: text.utf8.prefix(maximumBytes), as: UTF8.self), true)
    }
}
