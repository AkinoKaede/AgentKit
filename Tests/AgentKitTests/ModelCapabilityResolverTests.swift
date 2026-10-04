import Foundation
import Testing

@testable import AgentKit

@Suite
struct ModelCapabilityResolverTests {
    @Test
    func mixedCatalogKeepsChatCapabilitiesWhenOtherTypesOmitChatFields() {
        let resolution = resolve("catalog-chat")
        #expect(resolution.catalogSource?.modelID == "catalog-chat")
        #expect(resolution.model.kind == .chat)
        #expect(resolution.model.abilities == [.toolCall, .reasoning])
        #expect(resolution.model.contextLength == 128_000)
        #expect(resolution.model.maxOutputTokens == 8_192)
        #expect(resolution.wireValue(for: .max) == "max")
    }

    @Test
    func imageCatalogPreservesOutputWithoutAssigningChatAbilities() {
        let resolution = resolve("catalog-image")
        #expect(resolution.catalogSource != nil)
        #expect(resolution.model.kind == .imageGeneration)
        #expect(resolution.model.input == [.text, .image])
        #expect(resolution.model.output == [.image])
        #expect(resolution.model.abilities.isEmpty)
        #expect(resolution.model.contextLength == nil)
        #expect(resolution.model.maxOutputTokens == nil)
        #expect(resolution.supported == [.off])
        #expect(ModelProvider(name: "Catalog", models: [resolution.model]).assistantModels.isEmpty)
    }

    @Test
    func classifierCatalogStaysOutOfChatPickers() {
        let resolution = resolve("catalog-classifier")
        #expect(resolution.catalogSource != nil)
        #expect(resolution.model.kind == .classifier)
        #expect(resolution.model.abilities.isEmpty)
        #expect(resolution.model.contextLength == 32_000)
        #expect(resolution.model.maxOutputTokens == nil)
        let provider = ModelProvider(name: "Catalog", models: [resolution.model])
        #expect(provider.chatModels.isEmpty)
        #expect(provider.assistantModels.isEmpty)
    }

    @Test
    func endpointCapabilitiesRemainAuthoritative() {
        let model = AIModel(
            id: "catalog-image", kind: .chat, input: [.audio], output: [.text], abilities: [.structuredOutput]
        )
        let resolution = ModelCapabilityResolver.resolve(
            model: model, provider: ModelProvider(name: "Catalog"),
            reported: [.kind, .input, .output, .abilities], catalogData: catalogData
        )
        #expect(resolution.catalogSource != nil)
        #expect(resolution.model.kind == .chat)
        #expect(resolution.model.input == [.audio])
        #expect(resolution.model.output == [.text])
        #expect(resolution.model.abilities == [.structuredOutput])
    }

    private func resolve(_ id: String) -> ModelCapabilityResolver.Resolution {
        ModelCapabilityResolver.resolve(
            model: AIModel(id: id), provider: ModelProvider(name: "Catalog"), catalogData: catalogData
        )
    }

    private var catalogData: Data {
        Data(
            #"""
            {
                "package": "pi-test", "version": "1.0.2", "commit": "fixture",
                "models": [
                    {"provider":"openai","id":"catalog-chat","name":"Chat","type":"chat",
                     "reasoning":true,"input":["text"],"output":["text"],"contextWindow":128000,"maxOutputTokens":8192,
                     "effortWireValues":{"max":"max"}},
                    {"provider":"openai","id":"catalog-image","name":"Image","type":"image",
                     "reasoning":null,"input":["text","image"],"output":["image"],"contextWindow":null,
                     "maxOutputTokens":null,"effortWireValues":{}},
                    {"provider":"openai","id":"catalog-classifier","name":"Classifier","type":"classifier",
                     "input":["text"],"output":["text"],"contextWindow":32000,"effortWireValues":{}}
                ]
            }
            """#.utf8
        )
    }
}
