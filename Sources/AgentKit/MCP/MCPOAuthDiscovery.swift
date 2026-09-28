import Foundation

nonisolated struct MCPOAuthResourceMetadata: Decodable, Sendable {
    let resource: String
    let authorizationServers: [String]
    let scopesSupported: [String]?
}

nonisolated struct MCPOAuthServerMetadata: Decodable, Sendable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?
    let revocationEndpoint: URL?
    let codeChallengeMethodsSupported: [String]?
    let tokenEndpointAuthMethodsSupported: [String]?
    let clientIdMetadataDocumentSupported: Bool?
    let authorizationResponseIssParameterSupported: Bool?
    let scopesSupported: [String]?
}

nonisolated struct MCPOAuthHTTP: Sendable {
    let session: URLSession

    init(session: URLSession?) {
        let configuration = session?.configuration ?? URLSessionConfiguration.ephemeral
        // A transport's ambient headers, cookies and HTTP credentials must never reach discovery or an issuer.
        configuration.httpAdditionalHeaders = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        if session == nil {
            configuration.timeoutIntervalForRequest = 30
            configuration.waitsForConnectivity = false
        }
        self.session = URLSession(configuration: configuration)
    }

    static func secure(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil, url.fragment == nil
        else { throw MCPOAuthError.insecureEndpoint }
    }

    static func resource(_ server: MCPServer) throws -> String {
        guard let url = URL(string: server.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MCPOAuthError.insecureEndpoint
        }
        try secure(url)
        return canonical(url)
    }

    static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.port == 443, components.scheme == "https" { components.port = nil }
        if components.path == "/" { components.path = "" }
        return components.string ?? ""
    }

    func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw MCPOAuthError.insecureEndpoint }
        try Self.secure(url)
        try Task.checkCancellation()
        let (data, raw) = try await session.data(for: request, delegate: MCPRedirectGuard.shared)
        try Task.checkCancellation()
        guard let response = raw as? HTTPURLResponse else { throw MCPOAuthError.invalidMetadata }
        guard !(300..<400).contains(response.statusCode) else { throw MCPOAuthError.unsafeRedirect }
        guard data.count <= 1_048_576 else { throw MCPOAuthError.invalidMetadata }
        return (data, response)
    }

    func metadata<Value: Decodable>(_ type: Value.Type, at url: URL) async throws -> Value? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MCPClient.preferredVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        let (data, response) = try await self.request(request)
        if [404, 405].contains(response.statusCode) { return nil }
        guard response.statusCode == 200 else { throw MCPOAuthError.invalidMetadata }
        return try Self.decode(type, data: data)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(type, from: data) } catch { throw MCPOAuthError.invalidMetadata }
    }

    func resourceMetadata(
        server: MCPServer, challenge: MCPAuthorizationChallenge
    ) async throws -> MCPOAuthResourceMetadata {
        let resource = try Self.resource(server)
        let endpoint = URL(string: resource)!
        var candidates: [URL] = []
        if let address = challenge.resourceMetadata {
            guard let url = URL(string: address) else { throw MCPOAuthError.invalidMetadata }
            candidates = [url]
        } else {
            var origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            let resourcePath = origin.percentEncodedPath
            origin.path = ""
            origin.query = nil
            if !resourcePath.isEmpty, resourcePath != "/" {
                origin.percentEncodedPath = "/.well-known/oauth-protected-resource" + resourcePath
                candidates.append(origin.url!)
            }
            origin.path = "/.well-known/oauth-protected-resource"
            candidates.append(origin.url!)
        }
        for url in candidates {
            guard let metadata = try await metadata(MCPOAuthResourceMetadata.self, at: url) else { continue }
            guard let identifier = URL(string: metadata.resource), Self.canonical(identifier) == resource else {
                throw MCPOAuthError.resourceMismatch
            }
            guard !metadata.authorizationServers.isEmpty else { throw MCPOAuthError.invalidMetadata }
            for issuer in metadata.authorizationServers {
                guard let issuer = URL(string: issuer) else { throw MCPOAuthError.invalidMetadata }
                try Self.secure(issuer)
            }
            return metadata
        }
        throw MCPOAuthError.invalidMetadata
    }

    func serverMetadata(issuer: String) async throws -> MCPOAuthServerMetadata {
        guard let url = URL(string: issuer), url.query == nil else { throw MCPOAuthError.invalidMetadata }
        try Self.secure(url)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = components.percentEncodedPath == "/" ? "" : components.percentEncodedPath
        let paths =
            [
                "/.well-known/oauth-authorization-server" + path,
                "/.well-known/openid-configuration" + path,
            ] + (path.isEmpty ? [] : [path + "/.well-known/openid-configuration"])
        for path in paths {
            components.percentEncodedPath = path
            guard let value = try await metadata(MCPOAuthServerMetadata.self, at: components.url!) else { continue }
            guard value.issuer == issuer else { throw MCPOAuthError.issuerMismatch }
            try Self.secure(value.authorizationEndpoint)
            try Self.secure(value.tokenEndpoint)
            if let endpoint = value.registrationEndpoint { try Self.secure(endpoint) }
            if let endpoint = value.revocationEndpoint { try Self.secure(endpoint) }
            guard value.codeChallengeMethodsSupported?.contains("S256") == true else {
                throw MCPOAuthError.pkceUnsupported
            }
            return value
        }
        throw MCPOAuthError.invalidMetadata
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let text = values.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)!
                + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        return Data(text.utf8)
    }
}
