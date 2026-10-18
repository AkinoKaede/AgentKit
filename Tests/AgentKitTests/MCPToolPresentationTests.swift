import Testing

@testable import AgentKit

@Suite
struct MCPToolPresentationTests {
    @Test func discoveredToolsDeclareCallRatherThanRun() throws {
        let server = MCPServer(name: "Docs", tools: [MCPTool(id: "search")])
        let tool = try #require(AgentMCPTools.make(servers: [(server, nil)]).first)
        #expect(tool.descriptor.presentation?.actionKind == .call)
    }
}
