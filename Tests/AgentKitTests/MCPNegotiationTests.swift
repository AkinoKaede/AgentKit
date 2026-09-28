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
        if mode == "sse", request.httpMethod == "GET" {
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
        if mode == "sse", request.url?.path == "/mcp" {
            status = 405
        } else if method == "server/discover", ["versions", "no-common"].contains(mode) {
            status = 400
            error = [
                "code": -32022, "message": "Unsupported protocol version",
                "data": ["supported": mode == "versions" ? ["2025-06-18"] : ["1900-01-01"]],
            ]
        } else if mode == "auth" {
            status = 401
        } else if method == "server/discover" && mode == "legacy" {
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
                mode == "versions" ? "2025-06-18" : (mode == "sse" ? "2024-11-05" : "2025-11-25")
        } else if method == "tools/list" {
            result["tools"] = [["name": "hello", "inputSchema": ["type": "object"]]]
        } else if method == "tools/call" {
            result["content"] = []
            result["isError"] = false
        }
        var envelope: [String: Any] = ["jsonrpc": "2.0", "id": object["id"] ?? 1]
        if let error { envelope["error"] = error } else { envelope["result"] = result }
        if mode == "sse", request.url?.path == "/messages" {
            status = 202
            if object["id"] != nil, let stream = Self.eventStream.withLock({ $0 })?.value {
                let bytes = try! JSONSerialization.data(withJSONObject: envelope)
                let event = "event: message\ndata: " + String(decoding: bytes, as: UTF8.self) + "\n\n"
                stream.client?.urlProtocol(stream, didLoad: Data(event.utf8))
            }
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
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
