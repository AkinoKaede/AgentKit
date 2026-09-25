import Foundation
import Testing

@testable import AgentKit

@Suite struct AgentSearchQueryTests {
    @Test func naturalQuestionsBecomeSearchableTerms() {
        #expect(AgentSearchQuery("How do I deploy the server?").terms == ["deploy", "server"])
        #expect(AgentSearchQuery("服务器部署失败怎么办？").terms == ["服务器", "部署", "失败"])
        #expect(AgentSearchQuery("server?").terms == ["server"])
        #expect(AgentSearchQuery("the").terms == ["the"])
        #expect(AgentSearchQuery("Café").terms == ["café"])
        #expect(AgentSearchQuery("Café").fts5Query(matchingAll: true) == "\"café\"")
    }

    @Test func quotedPhrasesAndStructuredTermsRemainAtomic() {
        let query = AgentSearchQuery("\"Docker Compose\" project-A /etc/nginx.conf .bashrc")
        #expect(query.terms == ["docker compose", "project-a", "/etc/nginx.conf", ".bashrc"])
        #expect(
            query.fts5Query(matchingAll: true)
                == "\"docker compose\" \"project-a\" \"/etc/nginx.conf\" \".bashrc\"")
        #expect(
            query.fts5Query(matchingAll: false)
                == "\"docker compose\" OR \"project-a\" OR \"/etc/nginx.conf\" OR \".bashrc\"")
        #expect(AgentSearchQuery("服务器 部署").fts5Query(matchingAll: true) == nil)
        #expect(AgentSearchQuery("服务器 部署").shortTerms == ["部署"])
    }

    @Test func sentencePunctuationDoesNotBecomePartOfStructuredTerms() {
        #expect(AgentSearchQuery("project-A.").terms == ["project-a"])
        #expect(AgentSearchQuery("/etc/nginx.conf.").terms == ["/etc/nginx.conf"])
        #expect(AgentSearchQuery("(.bashrc)").terms == [".bashrc"])
        #expect(AgentSearchQuery("`/etc/nginx.conf`").terms == ["/etc/nginx.conf"])
    }

    @Test func memorySearchUsesStrictThenRankedBroadMatching() async throws {
        let older = Date(timeIntervalSince1970: 100)
        let access = SearchMemoryAccess(
            state: .init(entries: [
                .init(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, target: .memory,
                    content: "Deploy the server with Docker Compose.", updatedAt: older),
                .init(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, target: .memory,
                    content: "Server logs contain error 500.", updatedAt: older.addingTimeInterval(10)),
                .init(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, target: .memory,
                    content: "Docker Compose is the deployment tool.", updatedAt: older.addingTimeInterval(20)),
                .init(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, target: .memory,
                    content: "服务器部署使用 Docker Compose。", updatedAt: older),
                .init(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, target: .user,
                    content: "Deploy the server with Docker Compose.", updatedAt: older),
                .init(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, target: .memory,
                    content: "Café mode uses a warm palette.", updatedAt: older),
            ]))
        #expect(
            try await contents(access, "How do I deploy the server?", target: .memory)
                == ["Deploy the server with Docker Compose."])
        #expect(
            try await contents(access, "服务器怎么部署？", target: .memory)
                == ["服务器部署使用 Docker Compose。"])
        #expect(
            try await contents(access, "server docker failed", target: .memory).first
                == "Deploy the server with Docker Compose.")
        #expect(
            try await contents(access, "server?", target: .user)
                == ["Deploy the server with Docker Compose."])
        #expect(
            try await contents(access, "How do I deploy the server with Docker Compose today?", target: .memory)
                .first == "Deploy the server with Docker Compose.")
        #expect(try await contents(access, "café", target: .memory) == ["Café mode uses a warm palette."])
        #expect(try await contents(access, "unrelated kiwi").isEmpty)
    }

    @Test func fallbackPaginationUsesStableIDWhenRelevanceAndTimeTie() async throws {
        let time = Date(timeIntervalSince1970: 100)
        let access = SearchMemoryAccess(
            state: .init(entries: [
                .init(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, target: .memory,
                    content: "server alpha", updatedAt: time),
                .init(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, target: .memory,
                    content: "server beta", updatedAt: time),
            ]))
        let first = try await access.searchMemories(.init(query: "server missing", limit: 1))
        let second = try await access.searchMemories(.init(query: "server missing", limit: 1, offset: 1))
        #expect(first.objectValue?["next_offset"]?.integerValue == 1)
        #expect(first.objectValue?["entries"]?.arrayValue?.first?.objectValue?["content"]?.stringValue == "server beta")
        #expect(
            second.objectValue?["entries"]?.arrayValue?.first?.objectValue?["content"]?.stringValue == "server alpha")
        #expect(second.objectValue?["next_offset"] == .null)
    }

    private func contents(
        _ access: SearchMemoryAccess, _ query: String, target: AgentMemoryTarget? = nil
    ) async throws -> [String] {
        let result = try await access.searchMemories(.init(query: query, target: target))
        return result.objectValue?["entries"]?.arrayValue?.compactMap { $0.objectValue?["content"]?.stringValue } ?? []
    }
}

private struct SearchMemoryAccess: AgentMemoryAccessing {
    let state: AgentMemoryState
    func memoryState() async throws -> AgentMemoryState { state }
    func applyMemory(_ operations: [AgentMemoryOperation]) async throws -> AgentMemoryState { state }
    func searchSessions(_ request: AgentSessionSearchRequest) async throws -> AgentJSONValue { .array([]) }
}
