import Foundation

/// Public configuration only. Client secrets and grants belong to the host's credential store.
public nonisolated struct MCPOAuthConfiguration: Codable, Hashable, Sendable {
    public var issuer: String
    public var clientID: String

    public init(issuer: String = "", clientID: String = "") {
        self.issuer = issuer
        self.clientID = clientID
    }
}

public nonisolated struct MCPAuthorizationRequest: Sendable, Identifiable {
    public let id: UUID
    public let serverID: UUID
    public let serverName: String
    public var invocationID: UUID?
    public let issuer: URL
    public let scopes: [String]
    /// Ephemeral browser input. Never persist this URL or include it in model-visible data.
    public let url: URL
    public let redirectURI: URL

    public init(
        id: UUID = UUID(), serverID: UUID, serverName: String, issuer: URL, scopes: [String], url: URL,
        redirectURI: URL
    ) {
        self.id = id
        self.serverID = serverID
        self.serverName = serverName
        self.issuer = issuer
        self.scopes = scopes
        self.url = url
        self.redirectURI = redirectURI
    }
}

public nonisolated struct MCPAuthorizationInteraction: Sendable {
    public var authorize: @Sendable (MCPAuthorizationRequest) async throws -> URL

    public init(authorize: @escaping @Sendable (MCPAuthorizationRequest) async throws -> URL) {
        self.authorize = authorize
    }
}

extension AgentToolServiceKey where Service == MCPAuthorizationInteraction {
    public static let mcpAuthorization = Self("agentkit.mcp.authorization")
}

/// One issuer-bound grant. Implementations must store the entire value securely and atomically.
public nonisolated struct MCPOAuthCredential: Codable, Equatable, Sendable {
    public var resource: String
    public var issuer: String
    public var configuration: MCPOAuthConfiguration
    public var clientID: String
    public var clientSecret: String?
    public var isDynamicRegistration: Bool
    public var tokenEndpoint: URL
    public var revocationEndpoint: URL?
    public var tokenAuthMethod: String
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scopes: [String]

    public init(
        resource: String, issuer: String, configuration: MCPOAuthConfiguration, clientID: String,
        clientSecret: String? = nil, isDynamicRegistration: Bool = false, tokenEndpoint: URL,
        revocationEndpoint: URL? = nil, tokenAuthMethod: String = "none", accessToken: String? = nil,
        refreshToken: String? = nil, expiresAt: Date? = nil, scopes: [String] = []
    ) {
        self.resource = resource
        self.issuer = issuer
        self.configuration = configuration
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.isDynamicRegistration = isDynamicRegistration
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.tokenAuthMethod = tokenAuthMethod
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }
}

public nonisolated protocol MCPOAuthCredentialStoring: Sendable {
    func credentials(for serverID: UUID) async throws -> [MCPOAuthCredential]
    func save(_ credentials: [MCPOAuthCredential], for serverID: UUID) async throws
    func clientSecret(for server: MCPServer) async throws -> String?
    func saveRefreshed(_ credentials: [MCPOAuthCredential], for serverID: UUID) async throws
}

extension MCPOAuthCredentialStoring {
    public func saveRefreshed(_ credentials: [MCPOAuthCredential], for serverID: UUID) async throws {
        try await save(credentials, for: serverID)
    }
}

public nonisolated protocol MCPAuthorizationProviding: Sendable {
    func token(
        for server: MCPServer, challenge: MCPAuthorizationChallenge?, rejectedToken: String?,
        interaction: MCPAuthorizationInteraction?
    ) async throws -> String?
}

/// Only public challenge fields are retained; remote descriptions are deliberately excluded.
public nonisolated struct MCPAuthorizationChallenge: Equatable, Sendable {
    public let status: Int
    public let error: String?
    public let resourceMetadata: String?
    public let scopes: [String]?

    public init(status: Int, header: String?) throws {
        self.status = status
        let parameters = try Self.bearerParameters(header ?? "")
        error = parameters["error"]
        resourceMetadata = parameters["resource_metadata"]
        scopes = parameters["scope"].map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
    }

    /// Splits commas only outside quoted strings, including escaped quotes and mixed auth schemes.
    private static func bearerParameters(_ header: String) throws -> [String: String] {
        var parts: [String] = []
        var part = ""
        var quoted = false
        var escaped = false
        for character in header {
            if escaped {
                part.append(character)
                escaped = false
            } else if character == "\\", quoted {
                part.append(character)
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                part.append(character)
            } else if character == ",", !quoted {
                parts.append(part)
                part = ""
            } else {
                part.append(character)
            }
        }
        guard !quoted, !escaped else { throw MCPOAuthError.invalidChallenge }
        parts.append(part)
        var bearer = false
        var result: [String: String] = [:]
        for raw in parts {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let first = value.prefix { !$0.isWhitespace && $0 != "=" }
            let tail = value.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
            if !tail.hasPrefix("=") {
                bearer = first.lowercased() == "bearer"
                value = tail
            }
            guard bearer, !value.isEmpty, let equals = value.firstIndex(of: "=") else { continue }
            let name = value[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var content = value[value.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("\""), content.hasSuffix("\"") {
                content.removeFirst()
                content.removeLast()
                var unescaped = ""
                var escape = false
                for character in content {
                    if escape {
                        unescaped.append(character)
                        escape = false
                    } else if character == "\\" {
                        escape = true
                    } else {
                        unescaped.append(character)
                    }
                }
                content = unescaped
            }
            guard result[name] == nil else { throw MCPOAuthError.invalidChallenge }
            result[name] = content
        }
        return result
    }
}

public nonisolated enum MCPOAuthError: Error, LocalizedError, Equatable, Sendable {
    case authorizationRequired
    case clientRegistrationRequired
    case invalidChallenge
    case invalidMetadata
    case insecureEndpoint
    case issuerMismatch
    case resourceMismatch
    case pkceUnsupported
    case invalidCallback
    case authorizationDenied
    case tokenExchangeFailed
    case invalidGrant
    case unsupportedClientAuthentication
    case unsafeRedirect

    public var errorDescription: String? {
        switch self {
        case .authorizationRequired: String(localized: "Sign in to this MCP server to continue.", bundle: .module)
        case .clientRegistrationRequired:
            String(localized: "This MCP server requires a registered OAuth client ID.", bundle: .module)
        case .invalidChallenge: String(localized: "The MCP authorization challenge is invalid.", bundle: .module)
        case .invalidMetadata:
            String(localized: "The OAuth server metadata is invalid or unavailable.", bundle: .module)
        case .insecureEndpoint: String(localized: "OAuth requires secure HTTPS endpoints.", bundle: .module)
        case .issuerMismatch: String(localized: "The OAuth authorization server identity changed.", bundle: .module)
        case .resourceMismatch: String(localized: "The OAuth resource does not match this MCP server.", bundle: .module)
        case .pkceUnsupported: String(localized: "The OAuth server does not support PKCE S256.", bundle: .module)
        case .invalidCallback: String(localized: "The OAuth callback could not be verified.", bundle: .module)
        case .authorizationDenied: String(localized: "OAuth authorization was declined.", bundle: .module)
        case .tokenExchangeFailed: String(localized: "The OAuth token request failed.", bundle: .module)
        case .invalidGrant: String(localized: "The OAuth session expired. Sign in again to continue.", bundle: .module)
        case .unsupportedClientAuthentication:
            String(localized: "The OAuth client authentication method is not supported.", bundle: .module)
        case .unsafeRedirect: String(localized: "The MCP request attempted an unsafe redirect.", bundle: .module)
        }
    }
}

/// OAuth material must never follow an HTTP redirect, even in a caller-supplied URLSession.
nonisolated final class MCPRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = MCPRedirectGuard()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
