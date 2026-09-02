import Foundation

/// A remote MCP server the agent can ask for tools.
///
/// The client side, not the server side: this is the record of somebody else's
/// server that `MCPClient` connects to and `AgentMCPTools` turns into tools. An
/// app that also *hosts* an MCP server owns that separately; nothing here is
/// involved in it.
///
/// HTTP only — there is no stdio transport, and that is a property of the
/// intended host rather than an omission. A sandboxed app cannot launch an
/// arbitrary local process, so every server reached from here is one that
/// already exists at a URL.
///
/// Nothing secret is stored. `credentialRef` files the bearer token the way
/// `Identity.credentialRef` files a password; `headers` is for the things that
/// are not secrets, and the editor says so rather than leaving it to be assumed.
public nonisolated struct MCPServer: Identifiable, Hashable, Sendable {
    /// The two HTTP transports MCP has defined.
    ///
    /// `streamableHTTP` is the current one; `sse` is the 2024-11-05 transport it
    /// replaced, kept because a great many deployed servers still only speak it
    /// and the specification gives it a twelve-month deprecation window.
    public nonisolated enum Transport: String, Codable, Sendable, CaseIterable, Identifiable {
        case streamableHTTP
        case sse

        public nonisolated var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .streamableHTTP: String(localized: "Streamable HTTP", bundle: .module)
            case .sse: String(localized: "SSE (legacy)", bundle: .module)
            }
        }

        public var detail: String {
            switch self {
            case .streamableHTTP:
                String(localized: "The current transport, using one endpoint for POST and GET.", bundle: .module)
            case .sse:
                String(localized: "Legacy transport using a GET stream and a separate POST endpoint.", bundle: .module)
            }
        }
    }

    public var id: UUID = UUID()
    public var name: String
    /// Stable model-facing namespace. An empty value is used only while a new
    /// server draft is still deriving its ID from `name`.
    public var namespaceID: String
    public var transport: Transport = .streamableHTTP
    /// The MCP endpoint. One URL for Streamable HTTP; for SSE this is the URL
    /// the stream is opened on, and the POST endpoint arrives on that stream.
    public var url: String = ""
    public var isEnabled: Bool = true
    /// A bearer token, by reference. Most authenticated servers want exactly
    /// this one header, so it gets a field of its own rather than being one row
    /// among the custom headers where it would be stored in the clear.
    public var credentialRef: String = ""
    /// Non-secret extras — a tenant id, an API version.
    public var headers: [MCPHeader] = []
    /// What the last successful connection reported. Emptied by a failure, so
    /// a stale list cannot be mistaken for a live one.
    public var tools: [MCPTool] = []
    /// The protocol version the server agreed to, once it has said.
    public var negotiatedVersion: String = ""
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(), name: String, namespaceID: String? = nil,
        transport: Transport = .streamableHTTP, url: String = "",
        isEnabled: Bool = true, credentialRef: String = "",
        headers: [MCPHeader] = [], tools: [MCPTool] = [],
        negotiatedVersion: String = "", lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.namespaceID = namespaceID ?? MCPToolNaming.namespaceID(from: name)
        self.transport = transport
        self.url = url
        self.isEnabled = isEnabled
        self.credentialRef = credentialRef
        self.headers = headers
        self.tools = tools
        self.negotiatedVersion = negotiatedVersion
        self.lastConnectedAt = lastConnectedAt
    }

    /// The locked namespace, or the live derived value for an unlocked draft.
    public var effectiveNamespaceID: String {
        namespaceID.isEmpty ? MCPToolNaming.namespaceID(from: name) : namespaceID
    }

    public var enabledTools: [MCPTool] {
        tools.filter { $0.accessPolicy != .disabled }
    }

    public var isReachable: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

}

/// Shared naming rules for MCP namespaces and their model-visible functions.
public nonisolated enum MCPToolNaming {
    public static func namespaceID(from name: String) -> String {
        normalize(name, emptyFallback: "")
    }

    public static func functionName(from remoteName: String) -> String {
        normalize(remoteName, emptyFallback: "tool")
    }

    /// Returns stable, unique leaf names keyed by the server-reported tool ID.
    public static func functionNames(for tools: [MCPTool]) -> [String: String] {
        var taken = Set<String>()
        var result: [String: String] = [:]
        for tool in tools.sorted(by: { $0.id < $1.id }) {
            let base = functionName(from: tool.id)
            var candidate = base
            var suffix = 2
            while taken.contains(candidate) {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            taken.insert(candidate)
            result[tool.id] = candidate
        }
        return result
    }

    public static func qualifiedName(namespace: String, function: String) -> String {
        "\(namespace).\(function)"
    }

    private static func normalize(_ value: String, emptyFallback: String) -> String {
        var result = ""
        var pendingSeparator = false
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let isUppercase = (65...90).contains(code)
            let isLowercase = (97...122).contains(code)
            let isDigit = (48...57).contains(code)
            if isUppercase || isLowercase || isDigit || code == 95 || code == 45 {
                if pendingSeparator, !result.isEmpty,
                    result.last != "_", result.last != "-"
                {
                    result.append("_")
                }
                pendingSeparator = false
                if isUppercase {
                    result.unicodeScalars.append(UnicodeScalar(code + 32)!)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            } else {
                pendingSeparator = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_-")).isEmpty
            ? emptyFallback
            : result.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }
}

/// One custom HTTP header sent with every request to a server.
///
/// Deliberately not where a token goes. Values here are held in the clear
/// alongside the rest of the configuration, which is fine for
/// `X-Tenant: acme` and wrong for `Authorization: Bearer …` — that is what
/// `MCPServer.credentialRef` is for.
public nonisolated struct MCPHeader: Identifiable, Hashable, Sendable, Codable {
    public init(
        id: UUID = UUID(),
        name: String = "",
        value: String = ""
    ) {
        self.id = id
        self.name = name
        self.value = value
    }

    public var id: UUID = UUID()
    public var name: String = ""
    public var value: String = ""

    public var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// One tool a server offers.
///
/// `accessPolicy` defaults to `alwaysAsk`, and that default is the point rather
/// than caution. An MCP tool is a command fetched over the network from a server
/// the model can talk to, so a newly discovered tool must not silently inherit a
/// more permissive conversation setting.
public nonisolated struct MCPTool: Identifiable, Hashable, Sendable, Codable {
    public init(
        id: String,
        title: String = "",
        summary: String = "",
        inputSchema: AgentJSONValue = .object([
            "type": .string("object"), "properties": .object([:]),
        ]),
        annotations: MCPToolAnnotations = MCPToolAnnotations(),
        accessPolicy: AccessPolicy = .alwaysAsk
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.accessPolicy = accessPolicy
    }

    public nonisolated enum AccessPolicy: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
        case disabled
        case alwaysAsk
        case followPermissions

        public nonisolated var id: String { rawValue }
    }

    /// The tool name as the server reports it. Its identity, since MCP names
    /// are unique per server.
    public var id: String
    public var title: String = ""
    public var summary: String = ""
    public var inputSchema: AgentJSONValue = .object([
        "type": .string("object"), "properties": .object([:]),
    ])
    public var annotations: MCPToolAnnotations = MCPToolAnnotations()
    public var accessPolicy: AccessPolicy = .alwaysAsk

}

/// Hints supplied by the remote MCP server. They inform risk signals but can
/// never prove a call safe or bypass the local approval policy.
public nonisolated struct MCPToolAnnotations: Hashable, Sendable, Codable {
    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?
}
