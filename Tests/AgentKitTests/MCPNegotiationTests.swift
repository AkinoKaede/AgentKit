import Foundation
import Synchronization
import Testing

@testable import AgentKit

private final class MCPFixtureProtocol: URLProtocol, @unchecked Sendable {
    private struct StreamReference: @unchecked Sendable {
        let value: MCPFixtureProtocol
    }
    private static let eventStream = Mutex<StreamReference?>(nil)
    static let state = Mutex<(mode: String, requests: [URLRequest])>(("modern", []))
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mcp.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.state.withLock { state in
            state.requests.append(request)
            return state.mode
        }
        let isSSE = mode.hasPrefix("sse")
        if mode == "sse-open-failure", request.httpMethod == "GET" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if isSSE, request.httpMethod == "GET" {
            Self.eventStream.withLock { $0 = StreamReference(value: self) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("event: endpoint\ndata: /messages\n\n".utf8))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let method = object["method"] as? String ?? ""
        var status = 200
        var result: [String: Any] = ["resultType": "complete"]
        var error: [String: Any]?
        if request.httpMethod == "DELETE" {
            status = 500  // Teardown failure must not replace the operation result.
        } else if isSSE, request.url?.path == "/mcp" {
            status = 405
        } else if method == "server/discover", ["versions", "no-common"].contains(mode) {
            status = 400
            error = [
                "code": -32022, "message": "Unsupported protocol version",
                "data": ["supported": mode == "versions" ? ["2025-06-18"] : ["1900-01-01"]],
            ]
        } else if mode == "auth" {
            status = 401
        } else if method == "server/discover" && ["legacy", "march", "march-batch", "march-sse-batch"].contains(mode) {
            status = 400
        } else if method == "server/discover" && mode.hasPrefix("session-") {
            status = 400
        } else if method == "server/discover" && mode == "legacy-json" {
            status = 400
            error = ["code": -32600, "message": "Missing session"]
        } else if method == "server/discover" && mode == "header" {
            status = 400
            error = ["code": -32020, "message": "mismatch"]
        } else if method == "server/discover" {
            result["supportedVersions"] = ["2026-07-28"]
        } else if method == "initialize" {
            result["protocolVersion"] =
                mode.hasPrefix("march")
                ? "2025-03-26" : (mode == "versions" ? "2025-06-18" : (isSSE ? "2024-11-05" : "2025-11-25"))
            if mode == "session-invalid" || mode == "sse-invalid" {
                result["protocolVersion"] = "unsupported"
            }
        } else if method == "notifications/initialized" && mode == "session-notify-failure" {
            status = 500
        } else if method == "tools/list" && mode == "session-list-failure" {
            status = 500
        } else if method == "tools/call" && mode == "session-call-failure" {
            status = 500
        } else if method == "tools/list" {
            result["tools"] = [["name": "hello", "inputSchema": ["type": "object"]]]
        } else if method == "tools/call" {
            result["content"] = []
            result["isError"] = false
        }
        var envelope: [String: Any] = ["jsonrpc": "2.0", "id": object["id"] ?? 1]
        if let error { envelope["error"] = error } else { envelope["result"] = result }
        if isSSE, request.url?.path == "/messages" {
            status = 202
            if object["id"] != nil, let stream = Self.eventStream.withLock({ $0 })?.value {
                let bytes = try! JSONSerialization.data(withJSONObject: envelope)
                let event = "event: message\ndata: " + String(decoding: bytes, as: UTF8.self) + "\n\n"
                stream.client?.urlProtocol(stream, didLoad: Data(event.utf8))
            }
        }
        if mode.contains("batch"), method == "tools/list" || method == "tools/call" {
            let batch: [[String: Any]] = [
                ["jsonrpc": "2.0", "method": "notifications/message", "params": [:]], envelope,
            ]
            var data = try! JSONSerialization.data(withJSONObject: batch)
            if mode == "march-sse-batch" {
                data = Data(("data: " + String(decoding: data, as: UTF8.self) + "\n\n").utf8)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": mode == "march-sse-batch" ? "text/event-stream" : "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var headers = ["Content-Type": "application/json"]
        if mode.hasPrefix("session-"), method == "initialize" {
            headers["Mcp-Session-Id"] = "fixture-session"
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: status == 400 && mode == "legacy" ? Data() : try! JSONSerialization.data(withJSONObject: envelope))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.eventStream.withLock { if $0?.value === self { $0 = nil } }
    }
}

@Suite(.serialized)
struct MCPNegotiationTests {
    func client(_ mode: String) -> MCPClient {
        MCPFixtureProtocol.state.withLock { $0 = (mode, []) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPFixtureProtocol.self]
        return MCPClient(session: URLSession(configuration: config))
    }
    let server = MCPServer(name: "test", url: "https://mcp.test/mcp")

    @Test(arguments: ["march", "march-batch", "march-sse-batch"])
    func march2025DiscoversAndCallsWithSingleOrBatchedResponses(_ mode: String) async throws {
        let client = client(mode)
        let discovery = try await client.discover(server, bearerToken: nil)
        #expect(discovery.protocolVersion == "2025-03-26")
        #expect(discovery.tools.count == 1)
        let result = try await client.call(server, tool: "hello", arguments: .object([:]), bearerToken: nil)
        #expect(!result.isError)
    }

    @Test func unsupportedVersionSelectsAnAdvertisedIntersection() async throws {
        let discovered = try await client("versions").discover(server, bearerToken: nil)
        #expect(discovered.protocolVersion == "2025-06-18")
    }
    @Test func unsupportedVersionWithoutIntersectionStops() async {
        await #expect(throws: MCPError.unsupportedVersion(["1900-01-01"])) {
            try await client("no-common").discover(server, bearerToken: nil)
        }
        #expect(MCPFixtureProtocol.state.withLock { $0.requests.count } == 1)
    }
    @Test func automaticFallbackReadsTheLegacyEndpointStream() async throws {
        let discovered = try await client("sse").discover(server, bearerToken: nil)
        #expect(discovered.protocolVersion == "2024-11-05")
        #expect(discovered.tools.count == 1)
        let requests = MCPFixtureProtocol.state.withLock { $0.requests }
        #expect(requests.map { $0.httpMethod } == ["POST", "POST", "GET", "POST", "POST", "POST"])
        #expect(requests.suffix(3).allSatisfy { $0.url?.path == "/messages" })
    }

    @Test func modernDiscoveryUsesMetadataAndSkipsInitialize() async throws {
        let result = try await client("modern").discover(server, bearerToken: nil)
        #expect(result.protocolVersion == "2026-07-28")
        #expect(result.tools.count == 1)
        let requests = MCPFixtureProtocol.state.withLock { $0.requests }
        #expect(requests.map { $0.value(forHTTPHeaderField: "Mcp-Method") } == ["server/discover", "tools/list"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Mcp-Session-Id") == nil })
    }
    @Test(arguments: ["legacy", "legacy-json"])
    func legacyFallbackInitializesAfterProbe(_ mode: String) async throws {
        let result = try await client(mode).discover(server, bearerToken: nil)
        #expect(result.protocolVersion == "2025-11-25")
        #expect(MCPFixtureProtocol.state.withLock { $0.requests.count } == 4)
    }
    @Test(arguments: ["auth", "header"])
    func errorsDoNotDowngrade(_ mode: String) async throws {
        await #expect(throws: MCPError.self) { try await client(mode).discover(server, bearerToken: nil) }
        #expect(MCPFixtureProtocol.state.withLock { $0.requests.count } == 1)
    }
    @Test func toolCallIsSentExactlyOnce() async throws {
        _ = try await client("modern").call(server, tool: "hello", arguments: .object([:]), bearerToken: nil)
        let requests = MCPFixtureProtocol.state.withLock { $0.requests }
        #expect(
            requests.map { $0.value(forHTTPHeaderField: "Mcp-Method") } == [
                "server/discover", "tools/list", "tools/call",
            ])
    }
    @Test(arguments: ["session-invalid", "session-notify-failure", "session-list-failure"])
    func failedDiscoveryReleasesAssignedSession(_ mode: String) async throws {
        let expected: MCPError =
            mode == "session-invalid"
            ? .malformedResponse("initialize: unsupported protocol version") : .http(status: 500)
        await #expect(throws: expected) { try await client(mode).discover(server, bearerToken: nil) }
        let requests = MCPFixtureProtocol.state.withLock { $0.requests }
        let deletes = requests.filter { $0.httpMethod == "DELETE" }
        #expect(deletes.count == 1)
        #expect(deletes.first?.value(forHTTPHeaderField: "Mcp-Session-Id") == "fixture-session")
    }

    @Test(arguments: ["session-success", "session-call-failure"])
    func callReleasesAssignedSessionWithoutReplay(_ mode: String) async throws {
        let client = client(mode)
        if mode == "session-call-failure" {
            await #expect(throws: MCPError.self) {
                try await client.call(server, tool: "hello", arguments: .object([:]), bearerToken: nil)
            }
        } else {
            _ = try await client.call(server, tool: "hello", arguments: .object([:]), bearerToken: nil)
        }
        let requests = MCPFixtureProtocol.state.withLock { $0.requests }
        #expect(requests.filter { $0.httpMethod == "DELETE" }.count == 1)
        // Probe, initialize, initialized, one call, teardown: failures must not replay.
        #expect(requests.count == 5)
    }

    @Test func legacyCallUsesInitializedSession() async throws {
        _ = try await client("sse").call(server, tool: "hello", arguments: .object([:]), bearerToken: nil)
        let requests = MCPFixtureProtocol.state.withLock { $0.requests }
        #expect(requests.map { $0.httpMethod } == ["POST", "POST", "GET", "POST", "POST", "POST"])
        #expect(requests.suffix(3).allSatisfy { $0.url?.path == "/messages" })
    }

    @Test(arguments: [false, true])
    func legacyInvalidInitializationPreventsOperations(_ calling: Bool) async throws {
        let client = client("sse-invalid")
        await #expect(throws: MCPError.malformedResponse("initialize: unsupported legacy version")) {
            if calling {
                _ = try await client.call(server, tool: "hello", arguments: .object([:]), bearerToken: nil)
            } else {
                _ = try await client.discover(server, bearerToken: nil)
            }
        }
        let requests = MCPFixtureProtocol.state.withLock { $0.requests }
        #expect(requests.map { $0.httpMethod } == ["POST", "POST", "GET", "POST"])
    }

    @Test(arguments: [false, true])
    func legacyOpeningErrorsUseTransportErrorForBothOperations(_ calling: Bool) async throws {
        var server = server
        server.transport = .sse
        let client = client("sse-open-failure")
        do {
            if calling {
                _ = try await client.call(server, tool: "hello", arguments: .object([:]), bearerToken: nil)
            } else {
                _ = try await client.discover(server, bearerToken: nil)
            }
            Issue.record("Expected a transport error")
        } catch MCPError.transport {
            // Both legacy entry points normalize URLSession errors identically.
        }
    }

    @Test func literalDataIsNotMistakenForSchemaAnnotations() {
        let literal: AgentJSONValue = .object(["x-mcp-header": .string("literal-data")])
        let schema: AgentJSONValue = .object([
            "properties": .object([
                "payload": .object(["const": literal, "default": literal, "enum": .array([literal])])
            ])
        ])
        #expect(MCPClient.parameterHeaders(schema: schema, arguments: .object([:])) != nil)
        let invalid: AgentJSONValue = .object([
            "allOf": .array([
                .object([
                    "properties": .object([
                        "payload": .object([
                            "type": .string("string"), "x-mcp-header": .string("Header"),
                        ])
                    ])
                ])
            ])
        ])
        #expect(MCPClient.parameterHeaders(schema: invalid, arguments: .object([:])) == nil)
    }

    @Test func parameterHeaderEncodingAndSchemaValidation() {
        let schema: AgentJSONValue = .object([
            "properties": .object(["region": .object(["type": .string("string"), "x-mcp-header": .string("Region")])])
        ])
        #expect(
            MCPClient.parameterHeaders(schema: schema, arguments: .object(["region": .string("中文")]))?[
                "Mcp-Param-Region"] == "=?base64?5Lit5paH?=")
        #expect(MCPClient.headerValue("=?base64?literal?=") != "=?base64?literal?=")
    }
}
