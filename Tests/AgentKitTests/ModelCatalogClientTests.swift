import Foundation
import Testing

@testable import AgentKit

@Suite
struct ModelCatalogClientTests {
    @Test(arguments: AIModel.Kind.allCases)
    func reportedPurposesWinOverNameInference(kind: AIModel.Kind) throws {
        let wire = " \n" + kind.rawValue.uppercased() + "\t "
        let model = try parse(id: "text-embedding-custom", type: wire)
        #expect(model.kind == kind)
        #expect(AIModel.Kind(wire: wire) == kind)

        let provider = ModelProvider(name: "Gateway", models: [model])
        #expect(provider.chatModels.count == (kind == .chat ? 1 : 0))
        #expect(provider.assistantModels.count == (kind == .chat ? 1 : 0))
    }

    @Test(arguments: ["model", "llm", "other", "image", "unknown-purpose", "", " \n\t"])
    func unrecognisedPurposesAllowChatAndNameInference(type: String) throws {
        #expect(AIModel.Kind(wire: type) == .chat)
        let chat = try parse(id: "private-chat-deployment", type: type)
        #expect(chat.kind == .chat)
        #expect(ModelProvider(name: "Gateway", models: [chat]).assistantModels == [chat])
        #expect(try parse(id: "text-embedding-custom", type: type).kind == .embedding)
        #expect(try parse(id: "flux-custom", type: type).kind == .imageGeneration)
    }

    @Test
    func missingAndNullPurposesAllowNameInference() throws {
        #expect(AIModel.Kind(wire: nil) == .chat)
        for type: Any? in [nil, NSNull()] {
            #expect(try parse(id: "private-chat-deployment", type: type).kind == .chat)
            #expect(try parse(id: "text-embedding-custom", type: type).kind == .embedding)
            #expect(try parse(id: "flux-custom", type: type).kind == .imageGeneration)
        }
    }

    @Test
    func anthropicObjectTypeDoesNotHideChatModels() throws {
        let data = Data(
            #"{"data":[{"id":"claude-custom","type":"model","display_name":"Claude"}],"has_more":false}"#.utf8
        )
        var provider = ModelProvider(name: "Anthropic", apiFormat: .messages)
        let page = try ModelCatalogClient.parseOpenAIPage(data, provider: provider)
        provider.models = page.models
        #expect(page.models.first?.kind == .chat)
        #expect(provider.assistantModels.map(\.id) == ["claude-custom"])
        #expect(page.hasMore == false)
    }

    private func parse(id: String, type: Any?) throws -> AIModel {
        var row: [String: Any] = ["id": id]
        if let type { row["type"] = type }
        let data = try JSONSerialization.data(withJSONObject: ["data": [row]])
        return try #require(ModelCatalogClient.parseOpenAIPage(data).models.first)
    }
}
