import Foundation
import Synchronization
import Testing

@testable import AgentKit

private actor OAuthTestStore: MCPOAuthCredentialStoring {
    var values: [UUID: [MCPOAuthCredential]] = [:]
    var secret: String?
    func credentials(for serverID: UUID) -> [MCPOAuthCredential] { values[serverID] ?? [] }
    func save(_ credentials: [MCPOAuthCredential], for serverID: UUID) { values[serverID] = credentials }
    func clientSecret(for server: MCPServer) -> String? { secret }
    func setSecret(_ value: String) { secret = value }
}

private final class OAuthFixture: URLProtocol, @unchecked Sendable {
    struct State {
        var mode = "cimd"
        var resource: String?
        var requests: [URLRequest] = []
        var bodies: [String] = []
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, data.isEmpty {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size <= 0 { break }
                data.append(contentsOf: buffer.prefix(size))
            }
        }
        let body = String(decoding: data, as: UTF8.self)
        let mode = Self.state.withLock {
            $0.requests.append(request)
            $0.bodies.append(body)
            return $0.mode
        }
        let path = request.url!.path
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var object: [String: Any] = [:]
        if path == "/sse" {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("event: endpoint\ndata: https://other.test/messages\n\n".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if path.contains("oauth-protected-resource") {
            if mode == "root-discovery" || mode.hasPrefix("origin-resource"), path.hasSuffix("/mcp") { status = 404 }
            object = [
                "resource": OAuthFixture.state.withLock { $0.resource }
                    ?? (mode.hasPrefix("origin-resource")
                        ? "https://mcp.test/"
                        : mode == "bad-resource" ? "https://other.test/mcp" : "https://mcp.test/mcp"),
                "authorization_servers": ["https://auth.test/tenant"], "scopes_supported": ["read"],
            ]
        } else if path.contains(".well-known") {
            object = [
                "issuer": mode == "bad-issuer" ? "https://other.test" : "https://auth.test/tenant",
                "authorization_endpoint": "https://auth.test/authorize", "token_endpoint": "https://auth.test/token",
                "code_challenge_methods_supported": mode == "no-pkce" ? ["plain"] : ["S256"],
                "authorization_response_iss_parameter_supported": true,
                "token_endpoint_auth_methods_supported": ["none", "client_secret_basic"],
                "client_id_metadata_document_supported": !mode.hasSuffix("dcr") && mode != "manual-required",
            ]
            if mode.hasSuffix("dcr") { object["registration_endpoint"] = "https://auth.test/register" }
            if mode == "oidc", path.contains("oauth-authorization-server") { status = 404 }
            if mode == "redirect" {
                status = 302
                headers["Location"] = "https://other.test/metadata"
            }
        } else if path == "/register" {
            object = ["client_id": "dynamic-client", "token_endpoint_auth_method": "none"]
        } else if path == "/token" {
            if mode == "invalid-grant", body.contains("refresh_token") {
                status = 400
                object = ["error": "invalid_grant"]
            } else {
                object = [
                    "access_token": "access", "token_type": "Bearer", "refresh_token": "rotated-refresh",
                    "expires_in": 3600,
                ]
            }
        } else if path == "/mcp" {
            if mode == "forbidden" {
                status = 403
            } else if mode == "network-failure" {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            } else if request.value(forHTTPHeaderField: "Authorization") != "Bearer access" || mode == "always-401" {
                status = 401
                headers["WWW-Authenticate"] =
                    "Bearer resource_metadata=\"https://mcp.test/.well-known/oauth-protected-resource"
                    + (mode.hasPrefix("origin-resource") ? "" : "/mcp") + "\", scope=\"read\""
            } else {
                let rpc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                switch rpc["method"] as? String {
                case "server/discover":
                    object = [
                        "jsonrpc": "2.0", "id": 1,
                        "result": ["resultType": "complete", "supportedVersions": ["2025-03-26"]],
                    ]
                case "initialize":
                    object = ["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": "2025-03-26"]]
                case "notifications/initialized": status = 202
                case "tools/list":
                    object = ["jsonrpc": "2.0", "id": rpc["id"] ?? 2, "result": ["tools": []]]
                default: status = 202
                }
            }
        } else {
            status = 404
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct MCPOAuthTests {
    let server = MCPServer(name: "Example", url: "https://mcp.test/mcp")
    let callback = URL(string: "https://client.test/oauth/callback/")!
    let clientID = URL(string: "https://client.test/oauth/client.json")!

    func session(_ mode: String = "cimd") -> URLSession {
        OAuthFixture.state.withLock { $0 = OAuthFixture.State(mode: mode) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthFixture.self]
        return URLSession(configuration: config)
    }

    private func coordinator(_ store: OAuthTestStore, session: URLSession) -> MCPOAuthCoordinator {
        MCPOAuthCoordinator(store: store, redirectURI: callback, clientMetadataURL: clientID, session: session)
    }

    var challenge: MCPAuthorizationChallenge {
        get throws { try MCPAuthorizationChallenge(status: 401, header: "Bearer scope=\"read\"") }
    }

    static func accepted(_ request: MCPAuthorizationRequest) -> URL {
        let state = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!.first {
            $0.name == "state"
        }!.value!
        var components = URLComponents(url: request.redirectURI, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "state", value: state), .init(name: "code", value: "auth-code"),
            .init(name: "iss", value: request.issuer.absoluteString),
        ]
        return components.url!
    }

    var interaction: MCPAuthorizationInteraction { .init { Self.accepted($0) } }

    @Test func cimdAuthorizationConnectsMarch2025AndDoesNotLeakHeaders() async throws {
        let store = OAuthTestStore()
        let session = session()
        let oauth = coordinator(store, session: session)
        var server = server
        server.headers = [MCPHeader(name: "X-Tenant", value: "private-tenant")]
        let result = try await MCPClient(session: session, authorization: oauth)
            .discover(server, bearerToken: nil, interaction: interaction)
        #expect(result.protocolVersion == "2025-03-26")
        let requests = OAuthFixture.state.withLock { $0.requests }
        let auxiliary = requests.filter { $0.url?.path != "/mcp" }
        #expect(auxiliary.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(auxiliary.allSatisfy { $0.value(forHTTPHeaderField: "X-Tenant") == nil })
        let credential = try #require(await store.credentials(for: server.id).first)
        #expect(credential.clientID == clientID.absoluteString)
        #expect(credential.scopes == ["read"])
        #expect(credential.refreshToken == "rotated-refresh")
        let bodies = OAuthFixture.state.withLock { $0.bodies }
        #expect(
            bodies.contains { $0.contains("resource=https%3A%2F%2Fmcp.test%2Fmcp") && $0.contains("code_verifier=") })
    }

    @Test(arguments: ["dcr", "root-discovery", "oidc"])
    func discoveryAndRegistrationFallbacks(_ mode: String) async throws {
        let store = OAuthTestStore()
        let oauth = coordinator(store, session: session(mode))
        #expect(try await oauth.token(for: server, challenge: challenge, interaction: interaction) == "access")
        let value = try #require(await store.credentials(for: server.id).first)
        #expect(value.isDynamicRegistration == (mode == "dcr"))
        if mode == "dcr" {
            #expect(value.clientID == "dynamic-client")
            #expect(OAuthFixture.state.withLock { $0.bodies.contains { $0.contains("native") } })
        }
    }

    @Test func resourceDiscoveryPreservesEncodedSegmentsAndTrailingSlash() async throws {
        let session = session()
        let http = MCPOAuthHTTP(session: session)
        let server = MCPServer(name: "Encoded", url: "https://mcp.test/a%2Fb/")
        await #expect(throws: MCPOAuthError.resourceMismatch) {
            try await http.resourceMetadata(server: server, challenge: challenge)
        }
        let url = try #require(OAuthFixture.state.withLock { $0.requests.first?.url })
        #expect(url.absoluteString == "https://mcp.test/.well-known/oauth-protected-resource/a%2Fb/")
    }

    @Test(arguments: ["origin-resource", "origin-resource-dcr"])
    func originResourceAuthorizesAndRefreshesWhileRemainingBoundToTheMCPEndpoint(_ mode: String) async throws {
        let store = OAuthTestStore()
        let session = session(mode)
        let oauth = coordinator(store, session: session)
        let interaction = MCPAuthorizationInteraction { request in
            let parameters = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
            #expect(parameters?.first { $0.name == "resource" }?.value == "https://mcp.test/")
            return Self.accepted(request)
        }
        let result = try await MCPClient(session: session, authorization: oauth)
            .discover(server, bearerToken: nil, interaction: interaction)
        #expect(result.protocolVersion == "2025-03-26")
        var grant = try #require(await store.credentials(for: server.id).first)
        #expect(grant.resource == server.url)
        #expect(grant.authorizationResource == "https://mcp.test/")
        #expect(grant.isDynamicRegistration == mode.hasSuffix("dcr"))
        grant = try JSONDecoder().decode(MCPOAuthCredential.self, from: JSONEncoder().encode(grant))
        grant.expiresAt = .distantPast
        await store.save([grant], for: server.id)
        #expect(try await oauth.token(for: server) == "access")
        let requests = OAuthFixture.state.withLock { $0.requests }
        let tokenBodies = OAuthFixture.state.withLock { state in
            zip(state.requests, state.bodies).filter { $0.0.url?.path == "/token" }.map(\.1)
        }
        #expect(tokenBodies.count == 2)
        #expect(
            tokenBodies.allSatisfy {
                URLComponents(string: "?" + $0)?.queryItems?.first { $0.name == "resource" }?.value
                    == "https://mcp.test/"
            })
        #expect(tokenBodies.last?.contains("refresh_token=rotated-refresh") == true)
        #expect(
            requests.filter { $0.url?.host == "mcp.test" && $0.url?.path != "/mcp" }.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == nil
            })
        var other = server
        other.url = "https://mcp.test/another-mcp"
        #expect(try await oauth.token(for: other) == nil)
    }

    @Test func rootWellKnownFallbackAcceptsTheOriginResource() async throws {
        let http = MCPOAuthHTTP(session: session("origin-resource"))
        let metadata = try await http.resourceMetadata(server: server, challenge: challenge)
        #expect(metadata.resource == "https://mcp.test/")
        #expect(
            OAuthFixture.state.withLock { $0.requests.map { $0.url!.path } } == [
                "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource",
            ])
    }

    @Test(arguments: [
        "https://other.test/", "https://mcp.test:8443/", "https://mcp.test/other", "https://mcp.test/mc",
        "https://mcp.test/?tenant=other", "http://mcp.test/", "https://user@mcp.test/", "https://mcp.test/#fragment",
    ])
    func rootMetadataCannotBroadenTheResourceToAnotherOriginOrUnrelatedPath(_ resource: String) async throws {
        let http = MCPOAuthHTTP(session: session("origin-resource"))
        OAuthFixture.state.withLock { $0.resource = resource }
        await #expect(throws: MCPOAuthError.self) {
            try await http.resourceMetadata(server: server, challenge: challenge)
        }
    }

    @Test(arguments: [
        "https://other.test/.well-known/oauth-protected-resource",
        "https://mcp.test:8443/.well-known/oauth-protected-resource",
        "https://mcp.test/.well-known/oauth-protected-resource/unrelated",
        "https://mcp.test/.well-known/oauth-protected-resource?tenant=other",
    ])
    func originResourceExceptionRequiresTheSameOriginRootMetadataDocument(_ address: String) async throws {
        let http = MCPOAuthHTTP(session: session("origin-resource"))
        let challenge = try MCPAuthorizationChallenge(status: 401, header: "Bearer resource_metadata=\"\(address)\"")
        await #expect(throws: MCPOAuthError.resourceMismatch) {
            try await http.resourceMetadata(server: server, challenge: challenge)
        }
    }

    @Test func olderCredentialsStillDecodeAndRefreshWithTheirOriginalResource() async throws {
        let store = OAuthTestStore()
        let oauth = coordinator(store, session: session())
        let data = try JSONEncoder().encode(expiredCredential())
        #expect(!String(decoding: data, as: UTF8.self).contains("authorizationResource"))
        let grant = try JSONDecoder().decode(MCPOAuthCredential.self, from: data)
        #expect(grant.authorizationResource == nil)
        await store.save([grant], for: server.id)
        #expect(try await oauth.token(for: server) == "access")
        #expect(
            OAuthFixture.state.withLock { $0.bodies.contains { $0.contains("resource=https%3A%2F%2Fmcp.test%2Fmcp") } })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTKIT_LIVE_MCP_TESTS"] == "1"))
    func officialExampleResourceAndIssuerDiscovery() async throws {
        let server = MCPServer(name: "Official example", url: "https://example-server.modelcontextprotocol.io/mcp")
        let http = MCPOAuthHTTP(session: nil)
        var request = URLRequest(url: URL(string: server.url)!)
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let (_, response) = try await http.request(request)
        #expect(response.statusCode == 401)
        let challenge = try MCPAuthorizationChallenge(
            status: response.statusCode, header: response.value(forHTTPHeaderField: "WWW-Authenticate"))
        let resource = try await http.resourceMetadata(server: server, challenge: challenge)
        #expect(resource.resource == "https://example-server.modelcontextprotocol.io/")
        let issuer = try #require(resource.authorizationServers.first)
        let metadata = try await http.serverMetadata(issuer: issuer)
        #expect(metadata.issuer == issuer)
        #expect(metadata.codeChallengeMethodsSupported?.contains("S256") == true)
    }

    @Test func injectedSessionCannotLeakAmbientTransportCredentialsToAnIssuer() async throws {
        let config = session().configuration
        config.httpAdditionalHeaders = ["Authorization": "Bearer transport-secret", "X-Private-Key": "private"]
        let session = URLSession(configuration: config)
        let oauth = coordinator(OAuthTestStore(), session: session)
        #expect(try await oauth.token(for: server, challenge: challenge, interaction: interaction) == "access")
        let requests = OAuthFixture.state.withLock { $0.requests }
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Private-Key") == nil })
    }

    @Test func preRegisteredClientWinsAndUsesSecureSecretPort() async throws {
        let store = OAuthTestStore()
        await store.setSecret("manual-secret")
        let oauth = coordinator(store, session: session())
        var server = server
        server.oauth = .init(issuer: "https://auth.test/tenant", clientID: "registered")
        _ = try await oauth.token(for: server, challenge: challenge, interaction: interaction)
        let credential = try #require(await store.credentials(for: server.id).first)
        #expect(credential.clientID == "registered")
        #expect(credential.tokenAuthMethod == "client_secret_basic")
        let requests = OAuthFixture.state.withLock { $0.requests }
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
        #expect(!requests.contains { $0.url?.path == "/register" })
    }

    @Test(arguments: ["bad-resource", "bad-issuer", "no-pkce", "redirect", "manual-required"])
    func invalidDiscoveryNeverOpensBrowser(_ mode: String) async throws {
        let oauth = coordinator(OAuthTestStore(), session: session(mode))
        await #expect(throws: MCPOAuthError.self) {
            try await oauth.token(
                for: server, challenge: challenge,
                interaction: .init { _ in
                    Issue.record("Unexpected browser presentation")
                    throw CancellationError()
                })
        }
        #expect(!OAuthFixture.state.withLock { $0.requests.contains { $0.url?.path == "/token" } })
    }

    @Test func silentRuntimeDoesNotOpenBrowserOrRegister() async throws {
        let oauth = coordinator(OAuthTestStore(), session: session("dcr"))
        await #expect(throws: MCPOAuthError.authorizationRequired) {
            try await oauth.token(for: server, challenge: challenge)
        }
        #expect(!OAuthFixture.state.withLock { $0.requests.contains { $0.url?.path == "/register" } })
    }

    @Test func concurrentRequestsShareAuthorization() async throws {
        let count = Mutex(0)
        let oauth = coordinator(OAuthTestStore(), session: session())
        let interaction = MCPAuthorizationInteraction { request in
            count.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(50))
            return Self.accepted(request)
        }
        try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { try await oauth.token(for: server, challenge: challenge, interaction: interaction) }
            }
            for try await token in group { #expect(token == "access") }
        }
        #expect(count.withLock { $0 } == 1)
    }

    @Test func expiredTokenRefreshesAndPersistsRotationWithoutInteraction() async throws {
        let store = OAuthTestStore()
        let oauth = coordinator(store, session: session())
        await store.save([expiredCredential()], for: server.id)
        #expect(try await oauth.token(for: server) == "access")
        let value = try #require(await store.credentials(for: server.id).first)
        #expect(value.refreshToken == "rotated-refresh")
        #expect(value.expiresAt! > Date())
        #expect(OAuthFixture.state.withLock { $0.bodies.contains { $0.contains("refresh_token=old-refresh") } })
    }

    @Test func concurrentRefreshesUseTheRotatingRefreshTokenOnlyOnce() async throws {
        let store = OAuthTestStore()
        let oauth = coordinator(store, session: session())
        await store.save([expiredCredential()], for: server.id)
        try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<8 { group.addTask { try await oauth.token(for: server) } }
            for try await token in group { #expect(token == "access") }
        }
        #expect(OAuthFixture.state.withLock { $0.requests.filter { $0.url?.path == "/token" }.count } == 1)
        #expect(await store.credentials(for: server.id).first?.refreshToken == "rotated-refresh")
    }

    @Test(arguments: ["forbidden", "network-failure"])
    func ordinaryFailuresNeverOpenAuthorizationOrReplay(_ mode: String) async throws {
        let session = session(mode)
        let oauth = coordinator(OAuthTestStore(), session: session)
        await #expect(throws: (any Error).self) {
            try await MCPClient(session: session, authorization: oauth)
                .discover(
                    server, bearerToken: nil,
                    interaction: .init { _ in
                        Issue.record("An ordinary failure must not trigger authorization")
                        throw CancellationError()
                    })
        }
        #expect(OAuthFixture.state.withLock { $0.requests.count } == 1)
    }

    @Test func invalidRefreshRequiresLoginAndDoesNotKeepRevokedToken() async throws {
        let store = OAuthTestStore()
        let oauth = coordinator(store, session: session("invalid-grant"))
        await store.save([expiredCredential()], for: server.id)
        #expect(try await oauth.token(for: server) == nil)
        let value = try #require(await store.credentials(for: server.id).first)
        #expect(value.refreshToken == nil)
        #expect(value.accessToken == nil)
    }

    @Test func scopeUpgradePreservesExistingScopes() async throws {
        let store = OAuthTestStore()
        let oauth = coordinator(store, session: session())
        var grant = expiredCredential()
        grant.expiresAt = Date().addingTimeInterval(3600)
        await store.save([grant], for: server.id)
        let challenge = try MCPAuthorizationChallenge(
            status: 403, header: "Bearer error=\"insufficient_scope\", scope=\"write\"")
        _ = try await oauth.token(
            for: server, challenge: challenge,
            interaction: .init { request in
                #expect(request.scopes == ["read", "write"])
                return Self.accepted(request)
            })
        #expect(await store.credentials(for: server.id).first?.scopes == ["read", "write"])
    }

    @Test func manualBearerFailureDoesNotFallThroughToOAuth() async throws {
        let session = session()
        let oauth = coordinator(OAuthTestStore(), session: session)
        await #expect(throws: MCPError.self) {
            try await MCPClient(session: session, authorization: oauth)
                .discover(server, bearerToken: "manual-token", interaction: interaction)
        }
        #expect(OAuthFixture.state.withLock { $0.requests.count } == 1)
    }

    @Test func legacySSECannotForwardBearerCredentialsToAnotherOrigin() async throws {
        let session = session()
        let server = MCPServer(name: "SSE", transport: .sse, url: "https://mcp.test/sse")
        await #expect(throws: MCPOAuthError.unsafeRedirect) {
            try await MCPClient(session: session).discover(server, bearerToken: "fixture-manual")
        }
        let requests = OAuthFixture.state.withLock { $0.requests }
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "mcp.test")
    }

    @Test func repeatedUnauthorizedStopsAfterOneAuthorizedRetry() async throws {
        let session = session("always-401")
        let oauth = coordinator(OAuthTestStore(), session: session)
        await #expect(throws: MCPError.self) {
            try await MCPClient(session: session, authorization: oauth)
                .discover(server, bearerToken: nil, interaction: interaction)
        }
        #expect(OAuthFixture.state.withLock { $0.requests.filter { $0.url?.path == "/mcp" }.count } == 2)
    }

    @Test func cancellationAndSignOutPreventLateGrant() async throws {
        let store = OAuthTestStore()
        let oauth = coordinator(store, session: session())
        let started = Mutex(false)
        let task = Task {
            try await oauth.token(
                for: server, challenge: challenge,
                interaction: .init { request in
                    started.withLock { $0 = true }
                    try await Task.sleep(for: .seconds(10))
                    return Self.accepted(request)
                })
        }
        while !started.withLock({ $0 }) { await Task.yield() }
        try await oauth.signOut(serverID: server.id)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.credentials(for: server.id).isEmpty)
    }

    @Test func callbackValidationAndRFC7636Vector() throws {
        #expect(
            MCPOAuthCoordinator.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let good = URL(string: callback.absoluteString + "?state=s&code=c&iss=https%3A%2F%2Fauth.test%2Ftenant")!
        #expect(
            try MCPOAuthCoordinator.authorizationCode(
                callback: good, redirectURI: callback, state: "s", issuer: "https://auth.test/tenant",
                requiresIssuer: true) == "c")
        for suffix in [
            "?state=wrong&code=c", "?state=s&state=s&code=c", "?state=s&code=c",
            "?state=s&code=c&iss=https%3A%2F%2Fother.test",
        ] {
            #expect(throws: MCPOAuthError.self) {
                try MCPOAuthCoordinator.authorizationCode(
                    callback: URL(string: callback.absoluteString + suffix)!, redirectURI: callback, state: "s",
                    issuer: "https://auth.test/tenant", requiresIssuer: true)
            }
        }
    }

    @Test func challengeParserHandlesMixedSchemesAndQuotedCommas() throws {
        let value = try MCPAuthorizationChallenge(
            status: 401,
            header:
                "Basic realm=\"a,b\", Bearer resource_metadata=\"https://mcp.test/meta?a=b,c\", scope=\"read write\"")
        #expect(value.resourceMetadata == "https://mcp.test/meta?a=b,c")
        #expect(value.scopes == ["read", "write"])
        #expect(throws: MCPOAuthError.invalidChallenge) {
            try MCPAuthorizationChallenge(status: 401, header: "Bearer scope=\"a\", scope=\"b\"")
        }
    }

    private func expiredCredential() -> MCPOAuthCredential {
        .init(
            resource: server.url, issuer: "https://auth.test/tenant", configuration: .init(),
            clientID: clientID.absoluteString,
            tokenEndpoint: URL(string: "https://auth.test/token")!, accessToken: "expired", refreshToken: "old-refresh",
            expiresAt: Date().addingTimeInterval(-10), scopes: ["read"])
    }
}
