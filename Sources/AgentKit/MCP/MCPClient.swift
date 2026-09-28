import Foundation

/// What one successful `Connect` learned about a server.
public nonisolated struct MCPDiscovery: Sendable {
    public init(
        protocolVersion: String,
        serverName: String,
        tools: [MCPTool]
    ) {
        self.protocolVersion = protocolVersion
        self.serverName = serverName
        self.tools = tools
    }

    public var protocolVersion: String
    public var serverName: String
    public var tools: [MCPTool]
}

public nonisolated struct MCPCallResult: Hashable, Sendable {
    public init(
        value: AgentJSONValue,
        isError: Bool
    ) {
        self.value = value
        self.isError = isError
    }

    public var value: AgentJSONValue
    public var isError: Bool
}

/// Connects to an MCP server and asks what tools it has.
///
/// Discovery only. This runs the handshake and `tools/list`, and stops there —
/// actually *calling* a tool belongs with the chat loop in P3, and it will go
/// through the same approval gate an AI-proposed command does. That gate is why
/// a discovered `MCPTool` arrives with its access policy set to ask.
///
/// Two transports, both HTTP. There is no stdio here: a sandboxed app cannot
/// launch a local process, so every server this reaches is one that already
/// exists at a URL — see `MCPServer`.
public nonisolated struct MCPClient: Sendable {
    /// The name and version this client reports in `initialize`.
    public nonisolated struct ClientInfo: Hashable, Sendable {
        public var name: String
        public var version: String

        public init(name: String = "AgentKit", version: String = "0") {
            self.name = name
            self.version = version
        }
    }

    public static let preferredVersion = "2026-07-28"
    public static let legacyVersion = "2024-11-05"
    public static let supportedVersions = [preferredVersion, "2025-11-25", "2025-06-18", legacyVersion]

    private let session: URLSession
    /// How this client introduces itself in `initialize`.
    ///
    /// A parameter rather than the app's bundle identity, because a server
    /// operator reading their logs wants the name of the thing that connected —
    /// which is the app, not the library it happens to use.
    private let clientInfo: ClientInfo

    public init(clientInfo: ClientInfo = .init(), session: URLSession? = nil) {
        self.clientInfo = clientInfo
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Longer than the catalog client's: this is a multi-step exchange,
            // and an SSE stream that pauses between our own requests must not
            // be mistaken for a dead one.
            configuration.timeoutIntervalForRequest = 30
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func discover(_ server: MCPServer, bearerToken: String?) async throws -> MCPDiscovery {
        let trimmed = server.url.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw MCPError.badURL(trimmed)
        }

        switch server.transport {
        case .streamableHTTP:
            return try await discoverStreamable(at: url, server: server, bearerToken: bearerToken)
        case .sse:
            return try await discoverSSE(at: url, server: server, bearerToken: bearerToken)
        }
    }

    public func call(
        _ server: MCPServer, tool name: String, arguments: AgentJSONValue,
        bearerToken: String?
    ) async throws -> MCPCallResult {
        guard arguments.objectValue != nil else {
            throw MCPError.malformedResponse("tools/call arguments")
        }
        let trimmed = server.url.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw MCPError.badURL(trimmed)
        }
        switch server.transport {
        case .streamableHTTP:
            return try await callStreamable(
                at: url, server: server, name: name, arguments: arguments,
                bearerToken: bearerToken
            )
        case .sse:
            return try await callSSE(
                at: url, server: server, name: name, arguments: arguments,
                bearerToken: bearerToken
            )
        }
    }

    // MARK: - Streamable HTTP

    /// POST `initialize` → POST `notifications/initialized` → POST `tools/list`.
    ///
    /// Each POST may be answered as `application/json` or as an SSE stream
    /// carrying the same response, and the specification requires clients to
    /// handle both — so `send` branches on the content type rather than
    /// assuming the shape a particular server happened to use last time.
    private func discoverStreamable(
        at url: URL, server: MCPServer, bearerToken: String?
    ) async throws -> MCPDiscovery {
        let negotiated: (RequestContext, String)
        do {
            negotiated = try await negotiate(at: url, server: server, bearerToken: bearerToken)
        } catch MCPError.wrongTransport {
            return try await discoverSSE(at: url, server: server, bearerToken: bearerToken)
        }
        var (context, serverName) = negotiated
        do {
            let tools = try await listTools(context: &context)
            await endSession(context)
            return MCPDiscovery(protocolVersion: context.version, serverName: serverName, tools: tools)
        } catch {
            await endSession(context)
            throw error
        }
    }

    private func callStreamable(
        at url: URL, server: MCPServer, name: String, arguments: AgentJSONValue,
        bearerToken: String?
    ) async throws -> MCPCallResult {
        var context: RequestContext
        do {
            (context, _) = try await negotiate(at: url, server: server, bearerToken: bearerToken)
        } catch MCPError.wrongTransport {
            return try await callSSE(
                at: url, server: server, name: name, arguments: arguments, bearerToken: bearerToken)
        }
        do {
            if context.version == Self.preferredVersion {
                let tools = try await listTools(context: &context)
                guard let tool = tools.first(where: { $0.id == name }),
                    let headers = Self.parameterHeaders(schema: tool.inputSchema, arguments: arguments)
                else {
                    throw MCPError.malformedResponse("tools/call: invalid tool schema")
                }
                context.parameterHeaders = headers
            }
            let called: ToolsCallResult = try await send(
                .toolsCall(name: name, arguments: arguments), id: 100, context: &context)
            await endSession(context)
            return MCPCallResult(value: called.value, isError: called.isError ?? false)
        } catch {
            await endSession(context)
            throw error
        }
    }

    /// Probe only before execution. Never replay a tool call following a transport failure.
    private func negotiate(at url: URL, server: MCPServer, bearerToken: String?) async throws -> (
        RequestContext, String
    ) {
        var context = RequestContext(
            url: url, version: Self.preferredVersion, sessionID: nil,
            server: server, bearerToken: bearerToken)
        var fallbackVersion = "2025-11-25"
        do {
            let discovered: DiscoverResult = try await send(.discover, id: 1, context: &context)
            guard let version = Self.supportedVersions.first(where: discovered.supportedVersions.contains) else {
                throw MCPError.malformedResponse("server/discover: no supported version")
            }
            if version == Self.preferredVersion {
                return (
                    context,
                    discovered._meta?["io.modelcontextprotocol/serverInfo"]?.objectValue?["name"]?.stringValue
                        ?? server.name
                )
            }
            fallbackVersion = version
        } catch MCPError.unsupportedVersion(let supported) {
            guard let version = Self.supportedVersions.first(where: supported.contains),
                version != Self.preferredVersion
            else {
                throw MCPError.unsupportedVersion(supported)
            }
            fallbackVersion = version
        } catch MCPError.http(let status) where [400, 404, 405].contains(status) {
            // An older endpoint cannot understand the per-request metadata probe.
        } catch MCPError.rpc(let method, let code, _) where (code == -32601 && method != "HTTP") || code == -32002 {
            // Legacy servers commonly report method-not-found or not-initialized.
        }
        context.version = fallbackVersion
        context.sessionID = nil
        do {
            let initialized: InitializeResult = try await send(
                .initialize(version: fallbackVersion, clientInfo: clientInfo), id: 1, context: &context)
            guard let version = initialized.protocolVersion,
                Self.supportedVersions.dropFirst().contains(version)
            else {
                throw MCPError.malformedResponse("initialize: unsupported protocol version")
            }
            context.version = version
            try await notify(.initialized, context: context)
            return (context, initialized.serverInfo?.name ?? server.name)
        } catch MCPError.http(let status) where [400, 404, 405].contains(status) {
            throw MCPError.wrongTransport(status: status)
        }
    }

    /// One JSON-RPC request, and its response.
    ///
    /// Also the only place `Mcp-Session-Id` is read. A server that assigns one
    /// at initialization rejects every later request that omits it, so it is
    /// captured here rather than at the call sites that would each have to
    /// remember.
    private func send<Result: Decodable>(
        _ call: Call, id: Int, context: inout RequestContext
    ) async throws -> Result {
        var request = URLRequest(url: context.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Both, always: the server picks which one it answers with.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        context.apply(to: &request)
        request.httpBody = try call.body(id: id, modern: context.version == Self.preferredVersion ? clientInfo : nil)
        if context.version == Self.preferredVersion {
            request.setValue(context.version, forHTTPHeaderField: "MCP-Protocol-Version")
            for (name, value) in context.parameterHeaders { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue(call.method, forHTTPHeaderField: "Mcp-Method")
            if case .toolsCall(let name, _) = call {
                request.setValue(Self.headerValue(name), forHTTPHeaderField: "Mcp-Name")
            }
            request.setValue(nil, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (data, response) = try await perform(request)

        if context.version != Self.preferredVersion,
            let assigned = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !assigned.isEmpty
        {
            context.sessionID = assigned
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let payload: Data
        if contentType.contains("text/event-stream") {
            guard let found = JSONRPC.firstMessage(id: id, inSSE: data) else {
                throw MCPError.noResponse(call.method)
            }
            payload = found
        } else {
            payload = data
        }

        guard JSONRPC.id(of: payload) == id else { throw MCPError.malformedResponse(call.method) }
        if context.version == Self.preferredVersion {
            let envelope = try? AgentJSONValue.decode(payload).objectValue
            if let result = envelope?["result"]?.objectValue, result["resultType"]?.stringValue != "complete" {
                throw MCPError.malformedResponse(call.method)
            }
        }
        return try JSONRPC.result(Result.self, from: payload, method: call.method)
    }

    /// A notification. The server owes no answer, only a 202.
    private func notify(_ call: Call, context: RequestContext) async throws {
        var request = URLRequest(url: context.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        context.apply(to: &request)
        request.httpBody = try call.body(id: nil)
        _ = try await perform(request)
    }

    /// Best-effort session teardown. A server may refuse with 405, which the
    /// specification allows and which is not a failure of anything the user did.
    private func endSession(_ context: RequestContext) async {
        guard context.sessionID != nil else { return }
        var request = URLRequest(url: context.url)
        request.httpMethod = "DELETE"
        context.apply(to: &request)
        _ = try? await session.data(for: request)
    }

    // MARK: - Legacy HTTP+SSE

    /// The 2024-11-05 transport: a GET that stays open, plus a POST endpoint the
    /// stream itself names.
    ///
    /// Nothing here answers the request it was sent on. Every response — and the
    /// endpoint address itself — arrives on the GET stream, in whatever order
    /// the server chooses, interleaved with notifications addressed to nobody.
    /// So the stream is drained by one task into `LegacySSESession`, which hands
    /// each message to whichever request is waiting for that id.
    private func discoverSSE(
        at url: URL, server: MCPServer, bearerToken: String?
    ) async throws -> MCPDiscovery {
        var context = RequestContext(
            url: url,
            version: Self.legacyVersion,
            sessionID: nil,
            server: server,
            bearerToken: bearerToken
        )

        var streamRequest = URLRequest(url: url)
        streamRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        context.apply(to: &streamRequest)

        let bytes: URLSession.AsyncBytes
        do {
            let (stream, raw) = try await session.bytes(for: streamRequest)
            guard let http = raw as? HTTPURLResponse else { throw MCPError.notHTTP }
            guard (200..<300).contains(http.statusCode) else {
                throw MCPError.http(status: http.statusCode)
            }
            bytes = stream
        } catch let error as URLError {
            throw MCPError.transport(error.localizedDescription)
        }

        let events = LegacySSESession()
        await events.start(SSEStream.events(from: bytes))
        // The stream is a resource, not a value: leaving it open would hold a
        // connection for the life of the process.
        defer { Task { await events.cancel() } }

        // The first thing the server says is where to POST. Usually a relative
        // path, which is why it is resolved against the stream's own URL.
        let endpoint = try await events.endpointURL()
        guard let postURL = URL(string: endpoint, relativeTo: url) else {
            throw MCPError.noEndpointEvent
        }
        context.url = postURL.absoluteURL

        let initialize: InitializeResult = try await exchange(
            .initialize(version: Self.legacyVersion, clientInfo: clientInfo),
            id: 1, context: context, events: events)
        guard initialize.protocolVersion == Self.legacyVersion else {
            throw MCPError.malformedResponse("initialize: unsupported legacy version")
        }
        context.version = Self.legacyVersion

        try await notify(.initialized, context: context)

        var tools: [MCPTool] = []
        var cursor: String?
        var id = 2
        for _ in 0..<Self.pageLimit {
            let page: ToolsListResult = try await exchange(
                .toolsList(cursor: cursor), id: id, context: context, events: events)
            tools += (page.tools ?? []).compactMap { row in
                let tool = row.tool()
                if context.version == Self.preferredVersion,
                    Self.parameterHeaders(schema: tool.inputSchema, arguments: .object([:])) == nil
                {
                    return nil
                }
                return tool
            }
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
            id += 1
        }

        return MCPDiscovery(
            protocolVersion: context.version,
            serverName: initialize.serverInfo?.name ?? server.name,
            tools: tools
        )
    }

    private func callSSE(
        at url: URL, server: MCPServer, name: String, arguments: AgentJSONValue,
        bearerToken: String?
    ) async throws -> MCPCallResult {
        var context = RequestContext(
            url: url, version: Self.legacyVersion, sessionID: nil,
            server: server, bearerToken: bearerToken
        )
        var streamRequest = URLRequest(url: url)
        streamRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        context.apply(to: &streamRequest)
        let (stream, raw) = try await session.bytes(for: streamRequest)
        guard let http = raw as? HTTPURLResponse else { throw MCPError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(status: http.statusCode)
        }
        let events = LegacySSESession()
        await events.start(SSEStream.events(from: stream))
        defer { Task { await events.cancel() } }
        let endpoint = try await events.endpointURL()
        guard let postURL = URL(string: endpoint, relativeTo: url) else {
            throw MCPError.noEndpointEvent
        }
        context.url = postURL.absoluteURL
        let initialize: InitializeResult = try await exchange(
            .initialize(version: Self.legacyVersion, clientInfo: clientInfo),
            id: 1, context: context, events: events
        )
        guard initialize.protocolVersion == Self.legacyVersion else {
            throw MCPError.malformedResponse("initialize: unsupported legacy version")
        }
        context.version = Self.legacyVersion
        try await notify(.initialized, context: context)
        let called: ToolsCallResult = try await exchange(
            .toolsCall(name: name, arguments: arguments), id: 2,
            context: context, events: events
        )
        return MCPCallResult(value: called.value, isError: called.isError ?? false)
    }

    /// POST a request, then wait for its answer to come back on the stream.
    private func exchange<Result: Decodable>(
        _ call: Call,
        id: Int,
        context: RequestContext,
        events: LegacySSESession
    ) async throws -> Result {
        var request = URLRequest(url: context.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        context.apply(to: &request)
        request.httpBody = try call.body(id: id)
        _ = try await perform(request)

        let payload = try await events.response(id: id)
        return try JSONRPC.result(Result.self, from: payload, method: call.method)
    }

    // MARK: - Shared

    /// Validate annotations even when the corresponding argument is absent.
    static func parameterHeaders(schema: AgentJSONValue, arguments: AgentJSONValue) -> [String: String]? {
        var headers: [String: String] = [:]
        var names = Set<String>()
        func walk(_ schema: AgentJSONValue, _ value: AgentJSONValue?, reachable: Bool, root: Bool = false) -> Bool {
            guard let object = schema.objectValue else { return true }
            if let annotation = object["x-mcp-header"] {
                guard reachable, let name = annotation.stringValue, !name.isEmpty,
                    name.utf8.allSatisfy({ byte in
                        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                            || "!#$%&'*+-.^_`|~".utf8.contains(byte)
                    }), names.insert(name.lowercased()).inserted,
                    let type = object["type"]?.stringValue, ["string", "integer", "boolean"].contains(type)
                else { return false }
                if let value, value != .null {
                    let rendered: String
                    switch (type, value) {
                    case ("string", .string(let string)): rendered = string
                    case ("boolean", .bool(let bool)): rendered = bool ? "true" : "false"
                    case ("integer", .number(let number))
                    where number.isFinite && number.rounded() == number && abs(number) <= 9_007_199_254_740_991:
                        rendered = String(Int64(number))
                    default: return false
                    }
                    headers["Mcp-Param-" + name] = headerValue(rendered)
                }
            }
            for (key, child) in object where key != "x-mcp-header" {
                if key == "properties", let properties = child.objectValue {
                    for (name, property) in properties {
                        if !walk(property, value?.objectValue?[name], reachable: reachable || root) { return false }
                    }
                } else if ["$defs", "definitions", "patternProperties", "dependentSchemas", "dependencies"].contains(
                    key),
                    let children = child.objectValue
                {
                    for child in children.values where !walk(child, nil, reachable: false) { return false }
                } else if [
                    "items", "additionalItems", "additionalProperties", "unevaluatedProperties", "unevaluatedItems",
                    "propertyNames", "contains", "not", "if", "then", "else", "contentSchema",
                ].contains(key) {
                    if !walk(child, nil, reachable: false) { return false }
                    for child in child.arrayValue ?? [] where !walk(child, nil, reachable: false) { return false }
                } else if ["allOf", "anyOf", "oneOf", "prefixItems"].contains(key), let children = child.arrayValue {
                    for child in children where !walk(child, nil, reachable: false) { return false }
                }
            }
            return true
        }
        return walk(schema, arguments, reachable: false, root: true) ? headers : nil
    }

    static func headerValue(_ value: String) -> String {
        let safe = value.utf8.allSatisfy { $0 == 9 || (32...126).contains($0) }
        if safe && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !(value.hasPrefix("=?base64?") && value.hasSuffix("?="))
        {
            return value
        }
        return "=?base64?" + Data(value.utf8).base64EncodedString() + "?="
    }

    private static let pageLimit = 20

    private func listTools(context: inout RequestContext) async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        var id = 2

        for _ in 0..<Self.pageLimit {
            let page: ToolsListResult = try await send(
                .toolsList(cursor: cursor), id: id, context: &context)
            tools += (page.tools ?? []).compactMap { row in
                let tool = row.tool()
                if context.version == Self.preferredVersion,
                    Self.parameterHeaders(schema: tool.inputSchema, arguments: .object([:])) == nil
                {
                    return nil
                }
                return tool
            }
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
            id += 1
        }

        return tools
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, raw) = try await session.data(for: request)
            guard let http = raw as? HTTPURLResponse else { throw MCPError.notHTTP }
            guard (200..<300).contains(http.statusCode) else {
                if ![401, 403].contains(http.statusCode),
                    let envelope = try? JSONDecoder().decode(JSONRPC.Envelope<AgentJSONValue>.self, from: data),
                    let error = envelope.error
                {
                    if error.code == -32022, let supported = error.data?["supported"]?.arrayValue {
                        throw MCPError.unsupportedVersion(supported.compactMap(\.stringValue))
                    }
                    let modernError =
                        [-32020, -32021, -32022].contains(error.code ?? 0)
                        || (http.statusCode == 404 && error.code == -32601)
                    if !modernError, [400, 404, 405].contains(http.statusCode) {
                        throw MCPError.http(status: http.statusCode)
                    }
                    throw MCPError.rpc(method: "HTTP", code: error.code ?? 0, message: error.message ?? "")
                }
                throw MCPError.http(status: http.statusCode)
            }
            return (data, http)
        } catch let error as URLError {
            throw MCPError.transport(error.localizedDescription)
        }
    }

    /// Everything a request needs that is not its body.
    ///
    /// `url` is a `var` because the legacy transport moves it: the stream is
    /// opened on the configured URL and every POST afterwards goes wherever the
    /// `endpoint` event pointed.
    nonisolated private struct RequestContext {
        var url: URL
        var version: String
        var sessionID: String?
        let server: MCPServer
        let bearerToken: String?
        var parameterHeaders: [String: String] = [:]

        func apply(to request: inout URLRequest) {
            request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            if let bearerToken, !bearerToken.isEmpty {
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }
            // Last, so a user who really does need to override one of the above
            // can. They configured it on purpose; we should not quietly win.
            for header in server.headers where header.isComplete {
                request.setValue(header.value, forHTTPHeaderField: header.name)
            }
        }
    }
}

// MARK: - Calls

/// The three JSON-RPC messages discovery needs.
nonisolated private enum Call {
    case discover
    case initialize(version: String, clientInfo: MCPClient.ClientInfo)
    case initialized
    case toolsList(cursor: String?)
    case toolsCall(name: String, arguments: AgentJSONValue)

    var method: String {
        switch self {
        case .discover: "server/discover"
        case .initialize: "initialize"
        case .initialized: "notifications/initialized"
        case .toolsList: "tools/list"
        case .toolsCall: "tools/call"
        }
    }

    /// `id` is nil for notifications, which is what makes them notifications.
    func body(id: Int?, modern: MCPClient.ClientInfo? = nil) throws -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { object["id"] = id }

        switch self {
        case .discover:
            object["params"] = [String: Any]()
        case .initialize(let version, let clientInfo):
            object["params"] = [
                "protocolVersion": version,
                // This client consumes tools and offers the server nothing back
                // — no roots, no sampling. Declaring capabilities we do not
                // implement would invite requests we would have to fail.
                "capabilities": [String: Any](),
                "clientInfo": ["name": clientInfo.name, "version": clientInfo.version],
            ]
        case .initialized:
            object["params"] = [String: Any]()
        case .toolsList(let cursor):
            object["params"] = cursor.map { ["cursor": $0] } ?? [:]
        case .toolsCall(let name, let arguments):
            object["params"] = [
                "name": name,
                "arguments": try JSONSerialization.jsonObject(with: arguments.encodedData),
            ]
        }

        if let modern {
            var params = object["params"] as? [String: Any] ?? [:]
            params["_meta"] = [
                "io.modelcontextprotocol/protocolVersion": MCPClient.preferredVersion,
                "io.modelcontextprotocol/clientInfo": ["name": modern.name, "version": modern.version],
                "io.modelcontextprotocol/clientCapabilities": [String: Any](),
            ]
            object["params"] = params
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

// MARK: - Wire shapes

nonisolated private struct DiscoverResult: Decodable {
    var supportedVersions: [String]
    var _meta: [String: AgentJSONValue]?
}

nonisolated private struct InitializeResult: Decodable {
    var protocolVersion: String?
    var serverInfo: ServerInfo?

    nonisolated struct ServerInfo: Decodable {
        var name: String?
        var version: String?
    }
}

nonisolated private struct ToolsListResult: Decodable {
    var tools: [ToolRow]?
    var nextCursor: String?

    nonisolated struct ToolRow: Decodable {
        var name: String
        var title: String?
        var description: String?
        var inputSchema: AgentJSONValue?
        var annotations: MCPToolAnnotations?

        /// Arrives with the ask policy. See `MCPTool`.
        func tool() -> MCPTool {
            MCPTool(
                id: name, title: title ?? "", summary: description ?? title ?? "",
                inputSchema: inputSchema
                    ?? .object([
                        "type": .string("object"), "properties": .object([:]),
                    ]),
                annotations: annotations ?? MCPToolAnnotations()
            )
        }
    }
}

nonisolated private struct ToolsCallResult: Decodable {
    var content: AgentJSONValue?
    var structuredContent: AgentJSONValue?
    var isError: Bool?

    var value: AgentJSONValue {
        .object([
            "content": content ?? .array([]),
            "structuredContent": structuredContent ?? .null,
        ])
    }
}

/// The little bit of JSON-RPC framing this file needs.
nonisolated private enum JSONRPC {
    /// The `id` of a response, if it has one and it is a number.
    ///
    /// This client only ever sends integer ids, so a response carrying anything else
    /// is not answering us and correlating it would be a guess.
    static func id(of data: Data) -> Int? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["id"] as? Int
    }

    /// Finds our response inside an SSE body.
    ///
    /// A server answering a POST with a stream may send notifications ahead of
    /// the response — progress, logging — so this scans for the id rather than
    /// taking the first message.
    ///
    /// Framing is left to `SSEStream` rather than re-split here. Two SSE
    /// parsers in one codebase is one too many, and this is the copy that would
    /// have drifted.
    static func firstMessage(id: Int, inSSE data: Data) -> Data? {
        for event in SSEStream.events(in: data) {
            guard let bytes = event.data.data(using: .utf8), Self.id(of: bytes) == id else { continue }
            return bytes
        }
        return nil
    }

    nonisolated struct Envelope<R: Decodable>: Decodable {
        var result: R?
        var error: RPCError?
    }

    nonisolated struct RPCError: Decodable {
        var code: Int?
        var message: String?
        var data: [String: AgentJSONValue]?
    }

    /// Unwraps `{"result": …}`, or turns `{"error": …}` into a thrown error.
    static func result<T: Decodable>(_ type: T.Type, from data: Data, method: String) throws -> T {
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw MCPError.malformedResponse(method)
        }
        if let error = envelope.error {
            if error.code == -32022, let supported = error.data?["supported"]?.arrayValue {
                throw MCPError.unsupportedVersion(supported.compactMap(\.stringValue))
            }
            throw MCPError.rpc(
                method: method,
                code: error.code ?? 0,
                message: error.message ?? String(localized: "no reason given", bundle: .module)
            )
        }
        guard let result = envelope.result else { throw MCPError.malformedResponse(method) }
        return result
    }
}

// MARK: - Errors

public nonisolated enum MCPError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedVersion([String])
    case badURL(String)
    case notHTTP
    case http(status: Int)
    case transport(String)
    case wrongTransport(status: Int)
    case noEndpointEvent
    case streamClosed
    case noResponse(String)
    case malformedResponse(String)
    case rpc(method: String, code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            String(
                localized: "The server's answer to \("protocol version negotiation") was not valid MCP.",
                bundle: .module)
        case .badURL(let value):
            String(localized: "\(value) is not an http or https URL.", bundle: .module)
        case .notHTTP:
            String(localized: "The server did not answer with HTTP.", bundle: .module)
        case .http(let status):
            String(localized: "The server answered \(status).", bundle: .module)
        case .transport(let message):
            message
        case .wrongTransport(let status):
            String(
                localized:
                    "The server answered \(status) to a Streamable HTTP request. It may only speak the legacy SSE transport — try switching Transport."
            )
        case .noEndpointEvent:
            String(
                localized:
                    "The stream opened but never named a POST endpoint. This may be a Streamable HTTP server — try switching Transport."
            )
        case .streamClosed:
            String(localized: "The server closed the stream before answering.", bundle: .module)
        case .noResponse(let method):
            String(localized: "The server never answered \(method).", bundle: .module)
        case .malformedResponse(let method):
            String(localized: "The server's answer to \(method) was not valid MCP.", bundle: .module)
        case .rpc(let method, let code, let message):
            String(localized: "\(method) failed (\(code)): \(message)", bundle: .module)
        }
    }
}

// MARK: - Reading the legacy stream

/// Drains a legacy SSE stream and matches what arrives to what is waiting.
///
/// An actor with a pump task rather than an iterator passed between functions,
/// and for two reasons that point the same way.
///
/// The design reason: on this transport a POST does not carry its own answer.
/// Responses come back on a stream that was opened *before* the request went
/// out, out of order, mixed in with notifications nobody asked for. Correlating
/// by JSON-RPC id is the transport's actual contract, and this is that contract
/// written down.
///
/// The concurrency reason: an `AsyncIterator` is not `Sendable`, so it cannot be
/// pulled one event at a time across `async` calls without the compiler
/// objecting — rightly, since the caller could touch it across a suspension. A
/// `for try await` loop inside one task has no such problem, and the actor gives
/// the results somewhere safe to land.
private actor LegacySSESession {
    /// Where to POST, once the server has said.
    private var endpoint: String?
    private var endpointWaiter: CheckedContinuation<String, any Error>?

    /// Responses that arrived before anyone asked — which happens whenever the
    /// server is quicker than the caller's next line.
    private var delivered: [Int: Data] = [:]
    private var waiters: [Int: CheckedContinuation<Data, any Error>] = [:]

    /// Set once the stream ends, for any reason. Every later wait fails with it
    /// immediately rather than hanging on a stream that is not coming back.
    private var failure: (any Error)?

    private var pump: Task<Void, Never>?

    func start(_ stream: AsyncThrowingStream<SSEEvent, any Error>) {
        // Inherits this actor's isolation, so `receive` and `finish` need no
        // hop and the mutable state below has exactly one writer.
        pump = Task { [self] in
            do {
                for try await event in stream {
                    receive(event)
                }
                // A stream that closes cleanly has still stopped answering.
                finish(MCPError.streamClosed)
            } catch {
                finish(error)
            }
        }
    }

    func cancel() {
        pump?.cancel()
        pump = nil
    }

    func endpointURL() async throws -> String {
        if let endpoint { return endpoint }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { continuation in
            endpointWaiter = continuation
        }
    }

    func response(id: Int) async throws -> Data {
        if let ready = delivered.removeValue(forKey: id) { return ready }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
        }
    }

    private func receive(_ event: SSEEvent) {
        if event.event == "endpoint" {
            endpoint = event.data
            endpointWaiter?.resume(returning: event.data)
            endpointWaiter = nil
            return
        }

        // Anything without an integer id is a notification or a response to
        // somebody else. This client only ever sends integer ids, so correlating
        // anything else would be a guess.
        guard let data = event.data.data(using: .utf8), let id = JSONRPC.id(of: data) else { return }

        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: data)
        } else {
            delivered[id] = data
        }
    }

    private func finish(_ error: any Error) {
        guard failure == nil else { return }
        failure = error

        endpointWaiter?.resume(throwing: error)
        endpointWaiter = nil
        for (_, waiter) in waiters { waiter.resume(throwing: error) }
        waiters.removeAll()
    }
}
