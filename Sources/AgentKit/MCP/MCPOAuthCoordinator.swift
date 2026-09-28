import CryptoKit
import Foundation

/// Owns grants and single-flight refresh/authorization. Browser presentation and secure persistence are host ports.
public actor MCPOAuthCoordinator: MCPAuthorizationProviding {
    private struct Flight {
        let id: UUID
        let fingerprint: String
        let task: Task<String?, any Error>
    }

    private let store: any MCPOAuthCredentialStoring
    private let http: MCPOAuthHTTP
    private let redirectURI: URL
    private let clientMetadataURL: URL?
    private let clientName: String
    private let now: @Sendable () -> Date
    private var flights: [UUID: Flight] = [:]
    private var generations: [UUID: UUID] = [:]

    public init(
        store: any MCPOAuthCredentialStoring, redirectURI: URL, clientMetadataURL: URL? = nil,
        clientName: String = "AgentKit", session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.redirectURI = redirectURI
        self.clientMetadataURL = clientMetadataURL
        self.clientName = clientName
        self.http = MCPOAuthHTTP(session: session)
        self.now = now
    }

    public func token(
        for server: MCPServer, challenge: MCPAuthorizationChallenge? = nil, rejectedToken: String? = nil,
        interaction: MCPAuthorizationInteraction? = nil
    ) async throws -> String? {
        try Task.checkCancellation()
        let resource = try MCPOAuthHTTP.resource(server)
        let configuration = server.oauth ?? .init()
        let fingerprint = resource + "\n" + configuration.issuer + "\n" + configuration.clientID
        if let active = flights[server.id], active.fingerprint != fingerprint {
            active.task.cancel()
            flights[server.id] = nil
            generations[server.id] = UUID()
        }
        if let active = flights[server.id] {
            let token = try await wait(active, serverID: server.id)
            if challenge == nil { return token }
            if challenge?.status == 401, let token, token != rejectedToken { return token }
            // A refresh cannot satisfy a scope upgrade. Re-evaluate against the grant it just saved.
            let credentials = try await store.credentials(for: server.id)
            if challenge?.error == "insufficient_scope", let token,
                let value = credentials.first(where: { $0.accessToken == token }),
                Set(challenge?.scopes ?? []).isSubset(of: Set(value.scopes))
            {
                return token
            }
        }
        let id = UUID()
        let generation = generations[server.id] ?? UUID()
        generations[server.id] = generation
        let task = Task {
            try await self.resolve(
                server: server, resource: resource, challenge: challenge, rejectedToken: rejectedToken,
                interaction: interaction, generation: generation)
        }
        let flight = Flight(id: id, fingerprint: fingerprint, task: task)
        flights[server.id] = flight
        defer { if flights[server.id]?.id == id { flights[server.id] = nil } }
        return try await wait(flight, serverID: server.id)
    }

    private func wait(_ flight: Flight, serverID: UUID) async throws -> String? {
        try await withTaskCancellationHandler {
            let result = try await flight.task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            // No abandoned prompt may save a late grant. Other waiters can retry explicitly.
            flight.task.cancel()
        }
    }

    public func cancel(serverID: UUID) {
        generations[serverID] = UUID()
        flights.removeValue(forKey: serverID)?.task.cancel()
    }

    public func signOut(serverID: UUID) async throws {
        cancel(serverID: serverID)
        let credentials = try await store.credentials(for: serverID)
        // Local sign-out must succeed even if revocation is unavailable or the network is offline.
        try await store.save([], for: serverID)
        await revoke(credentials)
    }

    /// Best-effort revocation after the host has removed a server or invalidated its binding.
    public func revoke(_ credentials: [MCPOAuthCredential]) async {
        for credential in credentials {
            guard let endpoint = credential.revocationEndpoint,
                let token = credential.refreshToken ?? credential.accessToken
            else { continue }
            let request = try? tokenRequest(
                endpoint: endpoint, credential: credential,
                values: [
                    "token": token,
                    "token_type_hint": credential.refreshToken == nil ? "access_token" : "refresh_token",
                ])
            if let request { _ = try? await http.request(request) }
        }
    }

    private func resolve(
        server: MCPServer, resource: String, challenge: MCPAuthorizationChallenge?, rejectedToken: String?,
        interaction: MCPAuthorizationInteraction?, generation: UUID
    ) async throws -> String? {
        let configuration = server.oauth ?? .init()
        let stored = try await store.credentials(for: server.id)
        let matches = stored.filter {
            $0.resource == resource && $0.configuration == configuration
                && (configuration.issuer.isEmpty || $0.issuer == configuration.issuer)
        }
        if challenge == nil, let credential = matches.first(where: { $0.accessToken != nil }) {
            if credential.expiresAt.map({ $0.timeIntervalSince(now()) > 60 }) ?? true {
                return credential.accessToken
            }
            if credential.refreshToken != nil {
                return try await refresh(credential, server: server, generation: generation)
            }
            return nil
        }
        guard let challenge else { return nil }
        let resourceMetadata = try await http.resourceMetadata(server: server, challenge: challenge)
        let issuer: String
        if !configuration.issuer.isEmpty {
            guard resourceMetadata.authorizationServers.contains(configuration.issuer) else {
                throw MCPOAuthError.issuerMismatch
            }
            issuer = configuration.issuer
        } else {
            issuer =
                matches.first(where: { resourceMetadata.authorizationServers.contains($0.issuer) })?.issuer
                ?? resourceMetadata.authorizationServers[0]
        }
        let metadata = try await http.serverMetadata(issuer: issuer)
        var credential = matches.first { $0.issuer == issuer }
        if challenge.status == 401, let existing = credential {
            if let token = existing.accessToken, token != rejectedToken,
                existing.expiresAt.map({ $0.timeIntervalSince(now()) > 60 }) ?? true
            {
                return token
            }
            if existing.refreshToken != nil,
                let token = try await refresh(existing, server: server, generation: generation, metadata: metadata)
            {
                return token
            }
            credential?.accessToken = nil
            credential?.refreshToken = nil
        }
        guard let interaction else { throw MCPOAuthError.authorizationRequired }
        if credential == nil {
            if !configuration.clientID.isEmpty,
                stored.contains(where: {
                    $0.resource == resource && $0.configuration == configuration && $0.issuer != issuer
                })
            {
                throw MCPOAuthError.issuerMismatch
            }
            credential = try await register(server: server, resource: resource, metadata: metadata)
        }
        var grant = credential!
        grant.tokenEndpoint = metadata.tokenEndpoint
        grant.revocationEndpoint = metadata.revocationEndpoint
        var scopes = Set(challenge.scopes ?? resourceMetadata.scopesSupported ?? [])
        scopes.formUnion(grant.scopes)
        if metadata.scopesSupported?.contains("offline_access") == true { scopes.insert("offline_access") }
        let requestedScopes = scopes.sorted()
        try MCPOAuthHTTP.secure(redirectURI)
        let verifier = Self.random()
        let state = Self.random()
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        let parameters: [String: String] = [
            "response_type": "code", "client_id": grant.clientID, "redirect_uri": redirectURI.absoluteString,
            "code_challenge": Self.challenge(verifier), "code_challenge_method": "S256", "state": state,
            "resource": resource,
        ].merging(requestedScopes.isEmpty ? [:] : ["scope": requestedScopes.joined(separator: " ")]) { _, new in new }
        guard !(components.queryItems ?? []).contains(where: { parameters[$0.name] != nil }) else {
            throw MCPOAuthError.invalidMetadata
        }
        components.queryItems =
            (components.queryItems ?? [])
            + parameters.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        let callback = try await interaction.authorize(
            MCPAuthorizationRequest(
                serverID: server.id, serverName: server.name, issuer: URL(string: issuer)!, scopes: requestedScopes,
                url: components.url!, redirectURI: redirectURI))
        try check(server.id, generation)
        let code = try Self.authorizationCode(
            callback: callback, redirectURI: redirectURI, state: state, issuer: issuer,
            requiresIssuer: metadata.authorizationResponseIssParameterSupported == true)
        let response = try await exchange(
            grant,
            values: [
                "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                "redirect_uri": redirectURI.absoluteString, "resource": resource,
            ])
        apply(response, to: &grant, scopes: requestedScopes)
        try await save(grant, server: server, generation: generation)
        return grant.accessToken
    }

    private func refresh(
        _ credential: MCPOAuthCredential, server: MCPServer, generation: UUID,
        metadata: MCPOAuthServerMetadata? = nil
    ) async throws -> String? {
        guard let refreshToken = credential.refreshToken else { return nil }
        let resolved: MCPOAuthServerMetadata
        if let metadata {
            resolved = metadata
        } else {
            resolved = try await http.serverMetadata(issuer: credential.issuer)
        }
        let metadata = resolved
        var grant = credential
        grant.tokenEndpoint = metadata.tokenEndpoint
        grant.revocationEndpoint = metadata.revocationEndpoint
        do {
            let response = try await exchange(
                grant,
                values: [
                    "grant_type": "refresh_token", "refresh_token": refreshToken, "resource": grant.resource,
                ])
            apply(response, to: &grant, scopes: grant.scopes)
            try await save(grant, server: server, generation: generation, isRefresh: true)
            return grant.accessToken
        } catch MCPOAuthError.invalidGrant {
            grant.accessToken = nil
            grant.refreshToken = nil
            grant.expiresAt = nil
            try await save(grant, server: server, generation: generation, isRefresh: true)
            return nil
        }
    }

    private func register(
        server: MCPServer, resource: String, metadata: MCPOAuthServerMetadata
    ) async throws -> MCPOAuthCredential {
        let config = server.oauth ?? .init()
        var clientID = config.clientID
        var secret: String?
        var dynamic = false
        var method = "none"
        if !clientID.isEmpty {
            secret = try await store.clientSecret(for: server)
            if let secret, !secret.isEmpty {
                let methods = metadata.tokenEndpointAuthMethodsSupported ?? ["client_secret_basic"]
                guard let supported = ["client_secret_basic", "client_secret_post"].first(where: methods.contains)
                else {
                    throw MCPOAuthError.unsupportedClientAuthentication
                }
                method = supported
            }
        } else if metadata.clientIdMetadataDocumentSupported == true, let clientMetadataURL {
            try MCPOAuthHTTP.secure(clientMetadataURL)
            guard !clientMetadataURL.path.isEmpty, clientMetadataURL.path != "/" else {
                throw MCPOAuthError.invalidMetadata
            }
            clientID = clientMetadataURL.absoluteString
        } else if let endpoint = metadata.registrationEndpoint {
            try MCPOAuthHTTP.secure(redirectURI)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_name": clientName, "redirect_uris": [redirectURI.absoluteString],
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                "token_endpoint_auth_method": "none", "application_type": "native",
            ])
            let (data, response) = try await http.request(request)
            guard (200..<300).contains(response.statusCode),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let registered = object["client_id"] as? String, !registered.isEmpty
            else {
                throw MCPOAuthError.clientRegistrationRequired
            }
            guard (object["token_endpoint_auth_method"] as? String ?? "none") == "none" else {
                throw MCPOAuthError.unsupportedClientAuthentication
            }
            clientID = registered
            dynamic = true
        } else {
            throw MCPOAuthError.clientRegistrationRequired
        }
        return MCPOAuthCredential(
            resource: resource, issuer: metadata.issuer, configuration: config, clientID: clientID,
            clientSecret: secret, isDynamicRegistration: dynamic, tokenEndpoint: metadata.tokenEndpoint,
            revocationEndpoint: metadata.revocationEndpoint, tokenAuthMethod: method)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let tokenType: String
        let refreshToken: String?
        let expiresIn: Double?
        let scope: String?
    }

    private func exchange(_ credential: MCPOAuthCredential, values: [String: String]) async throws -> TokenResponse {
        let request = try tokenRequest(endpoint: credential.tokenEndpoint, credential: credential, values: values)
        let (data, response) = try await http.request(request)
        if !(200..<300).contains(response.statusCode) {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if object?["error"] as? String == "invalid_grant" { throw MCPOAuthError.invalidGrant }
            throw MCPOAuthError.tokenExchangeFailed
        }
        let value = try MCPOAuthHTTP.decode(TokenResponse.self, data: data)
        guard !value.accessToken.isEmpty, value.tokenType.lowercased() == "bearer",
            value.expiresIn.map({ $0.isFinite && $0 >= 0 }) ?? true
        else { throw MCPOAuthError.tokenExchangeFailed }
        return value
    }

    private func tokenRequest(
        endpoint: URL, credential: MCPOAuthCredential, values: [String: String]
    ) throws -> URLRequest {
        var values = values
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch credential.tokenAuthMethod {
        case "none": values["client_id"] = credential.clientID
        case "client_secret_post":
            guard let secret = credential.clientSecret else { throw MCPOAuthError.unsupportedClientAuthentication }
            values["client_id"] = credential.clientID
            values["client_secret"] = secret
        case "client_secret_basic":
            guard let secret = credential.clientSecret else { throw MCPOAuthError.unsupportedClientAuthentication }
            func encoded(_ text: String) -> String {
                String(decoding: MCPOAuthHTTP.form(["v": text]), as: UTF8.self).dropFirst(2).description
            }
            let basic = Data((encoded(credential.clientID) + ":" + encoded(secret)).utf8).base64EncodedString()
            request.setValue("Basic " + basic, forHTTPHeaderField: "Authorization")
        default: throw MCPOAuthError.unsupportedClientAuthentication
        }
        request.httpBody = MCPOAuthHTTP.form(values)
        return request
    }

    private func apply(_ response: TokenResponse, to credential: inout MCPOAuthCredential, scopes: [String]) {
        credential.accessToken = response.accessToken
        credential.refreshToken = response.refreshToken ?? credential.refreshToken
        credential.expiresAt = response.expiresIn.map { now().addingTimeInterval($0) }
        credential.scopes = response.scope.map { $0.split(separator: " ").map(String.init) } ?? scopes
    }

    private func save(_ credential: MCPOAuthCredential, server: MCPServer, generation: UUID, isRefresh: Bool = false)
        async throws
    {
        try check(server.id, generation)
        var all = try await store.credentials(for: server.id)
        try check(server.id, generation)
        all.removeAll { $0.resource == credential.resource && $0.issuer == credential.issuer }
        all.append(credential)
        if isRefresh {
            try await store.saveRefreshed(all, for: server.id)
        } else {
            try await store.save(all, for: server.id)
        }
        try check(server.id, generation)
    }

    private func check(_ serverID: UUID, _ generation: UUID) throws {
        try Task.checkCancellation()
        guard generations[serverID] == generation else { throw CancellationError() }
    }

    static func random() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URL
    }

    static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    static func authorizationCode(
        callback: URL, redirectURI: URL, state: String, issuer: String, requiresIssuer: Bool
    ) throws -> String {
        guard var callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false),
            callbackComponents.fragment == nil
        else { throw MCPOAuthError.invalidCallback }
        callbackComponents.percentEncodedQuery = callbackComponents.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%20")
        let items = callbackComponents.queryItems ?? []
        callbackComponents.query = nil
        guard callbackComponents.url == redirectURI else { throw MCPOAuthError.invalidCallback }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value else { throw MCPOAuthError.invalidCallback }
            // Query values in OAuth callbacks use form encoding, where a literal plus means space.
            values[item.name] = value
        }
        guard values["state"] == state else { throw MCPOAuthError.invalidCallback }
        if let received = values["iss"] {
            guard received == issuer else { throw MCPOAuthError.issuerMismatch }
        } else if requiresIssuer {
            throw MCPOAuthError.issuerMismatch
        }
        if values["error"] != nil { throw MCPOAuthError.authorizationDenied }
        guard let code = values["code"], !code.isEmpty else { throw MCPOAuthError.invalidCallback }
        return code
    }
}

extension Data {
    fileprivate var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
