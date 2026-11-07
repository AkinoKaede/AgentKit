import CryptoKit
import Foundation
import Testing

@testable import AgentKit

@Suite
struct ModelCatalogSnapshotTests {
    @Test
    func nativeListingFlagsAndLimitsBeatFamilyInferenceWithoutDroppingMetadata() throws {
        let data = Data(
            #"""
            {"data":[{"id":"gpt-5-fixture","type":"chat","tool_call":false,"reasoning":false,
             "structured_output":false,"limit":{"context":10000,"input":9000,"output":1000},
             "modalities":{"input":["text","pdf"],"output":["text"]},
             "cost":{"input":2.5},"experimental":{"keep":true}}]}
            """#.utf8)
        let model = try #require(ModelCatalogClient.parseOpenAIPage(data).models.first)
        #expect(model.abilities == [.webSearch])
        #expect(model.contextLength == 10000)
        #expect(model.specification.limit.input == 9000)
        #expect(model.maxOutputTokens == 1000)
        #expect(model.specification.cost.input == 2.5)
        #expect(model.specification.fields["experimental"] == .object(["keep": .bool(true)]))
    }

    @Test
    func nativeSpecificationsRoundTripUnknownFieldsWithoutAnEnvelope() throws {
        let data = Data(
            #"""
            {"id":"native","name":"Native","family":"fixture","limit":{"context":10000,"input":9000,"output":1000},
             "modalities":{"input":["text","pdf"],"output":["text"]},
             "cost":{"input":2.5,"output":15,"cache_read":0.25,"tiers":[{"tier":{"size":200000},"input":5}]},
             "reasoning_options":[{"type":"budget_tokens","min":128,"max":32768}],
             "experimental":{"modes":{"fast":{"provider":{"body":{"service_tier":"priority"}}}}},
             "future":{"nested":true}}
            """#.utf8)
        let specification = try JSONDecoder().decode(ModelsDevModel.self, from: data)
        #expect(specification.limit.input == 9000)
        #expect(specification.cost.cacheRead == 0.25)
        #expect(specification.reasoningOptions?.first?.min == 128)
        #expect(try AgentJSONValue.decode(JSONEncoder().encode(specification)) == AgentJSONValue.decode(data))
        var model = AIModel(id: "native")
        model.specification = specification
        model.contextLength = 12000
        model.input.insert(.image)
        model.abilities.insert(.toolCall)
        #expect(model.specification.limit.context == 12000)
        #expect(model.specification.limit.input == 9000)
        #expect(model.specification.modalities.input?.contains("image") == true)
        #expect(model.specification.toolCall == true)
        #expect(model.specification.fields["future"] == specification.fields["future"])
        #expect(model.specification.cost == specification.cost)
    }

    @Test(arguments: [
        "embedding", "reranking", "image", "video", "speech", "transcription", "realtime", "decision", "future",
    ])
    func specializedModelsRetainTheirNativeTypeWithoutEnteringChatPickers(type: String) throws {
        var record = row("specialized")
        record["type"] = type
        record["modalities"] = ["input": ["audio"], "output": ["text"]]
        let resolution = ModelCapabilityResolver.resolve(
            model: AIModel(id: "specialized"), provider: ModelProvider(name: "Gateway"),
            catalogData: try snapshot([record])
        )
        #expect(resolution.model.kind != .chat)
        #expect(resolution.model.specification.type == type)
        #expect(resolution.model.input == [.audio])
        #expect(ModelProvider(name: "Gateway", models: [resolution.model]).assistantModels.isEmpty)
    }

    @Test
    func nativeOverridesAndSeparateHostPolicyPreserveReviewOnlyModels() throws {
        var record = row("codex-auto-review")
        record["limit"] = ["context": 272000]
        record["tool_call"] = true
        record["reasoning"] = true
        record["structured_output"] = true
        record["reasoning_options"] = [["type": "effort", "values": ["low", "medium", "high", "xhigh", "max"]]]
        let policy = Data(#"{"hiddenFromAssistant":[{"provider":"openai","modelID":"codex-auto-review"}]}"#.utf8)
        for base in [try snapshot([row("different")]), Data()] {
            let result = ModelCapabilityResolver.resolve(
                model: AIModel(id: "codex-auto-review"), provider: ModelProvider(name: "OpenAI"),
                catalogData: base, overridesData: try snapshot([record]), policyData: policy
            )
            #expect(result.model.contextLength == 272000)
            #expect(result.model.maxOutputTokens == nil)
            #expect(result.model.abilities == [.toolCall, .reasoning, .structuredOutput])
            #expect(result.supported == [.low, .medium, .high, .xHigh, .max])
            #expect(!result.model.isShownInAssistant)
            #expect(result.model.specification.fields["showInAssistant"] == nil)
        }
    }

    @Test
    func modelsDevMetadataAndExplicitCapabilitiesAreLoaded() throws {
        let data = try snapshot([row("gpt-5.4", structuredOutput: false)])
        let catalog = ModelCapabilityResolver.BundledModelCatalog.load(data: data)
        #expect(catalog.metadata?.source == "https://models.dev/api.json")
        #expect(catalog.metadata?.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        #expect(catalog.metadata?.modelCount == 1)
        let resolution = ModelCapabilityResolver.resolve(
            model: AIModel(id: "gpt-5.4"), provider: ModelProvider(name: "OpenAI"), catalogData: data
        )
        #expect(resolution.catalogSource == .init(provider: "openai", modelID: "gpt-5.4"))
        // Explicit false flags beat family guesses; native search remains additive.
        #expect(resolution.model.abilities == [.webSearch])
        #expect(resolution.model.input == [.text, .image, .pdf])
        #expect(resolution.supported == [.off])
    }

    @Test
    func declaredEffortsPreserveWireValuesAndExcludeUnlistedLevels() throws {
        var record = row("reasoner")
        record["reasoning"] = true
        record["tool_call"] = false
        record["reasoning_options"] = [["type": "effort", "values": ["none", "high", "xhigh", "unknown", "default"]]]
        let resolution = ModelCapabilityResolver.resolve(
            model: AIModel(id: "reasoner"), provider: ModelProvider(name: "OpenAI"),
            catalogData: try snapshot([record])
        )
        #expect(resolution.supported == [.off, .high, .xHigh])
        #expect(resolution.wireValue(for: .off) == "none")
        #expect(resolution.wireValue(for: .xHigh) == "xhigh")
        #expect(resolution.wireValue(for: .max) == nil)
        #expect(resolution.clamp(.low) == .high)
    }

    @Test
    func budgetAndToggleSnapshotsRetainFallbackEfforts() throws {
        var record = row("budget-reasoner")
        record["reasoning"] = true
        record["tool_call"] = false
        let resolution = ModelCapabilityResolver.resolve(
            model: AIModel(id: "budget-reasoner"), provider: ModelProvider(name: "Anthropic", apiFormat: .messages),
            catalogData: try snapshot([record])
        )
        #expect(resolution.supported == [.off, .minimal, .low, .medium, .high])
        #expect(resolution.wireValue(for: .high) == "high")
    }

    @Test
    func manualReasoningAndReportedCapabilitiesRemainAuthoritative() throws {
        var record = row("custom")
        record["reasoning"] = true
        record["tool_call"] = true
        record["reasoning_options"] = [["type": "effort", "values": ["high"]]]
        var model = AIModel(id: "custom", contextLength: 777)
        model.abilities = [.reasoning]
        model.input = [.audio]
        model.reasoningProfile = ReasoningProfile(levels: [
            .low: ReasoningLevelMapping(isSupported: true, wireValue: "custom-low")
        ])
        let resolution = ModelCapabilityResolver.resolve(
            model: model, provider: ModelProvider(name: "Custom"),
            reported: [.input, .abilities], catalogData: try snapshot([record])
        )
        #expect(resolution.model.abilities == [.reasoning])
        #expect(resolution.model.input == [.audio])
        #expect(resolution.model.contextLength == 777)
        #expect(resolution.supported == [.low])
        #expect(resolution.wireValue(for: .low) == "custom-low")
    }

    @Test
    func overridesReplaceBothIndexesAndWorkWithoutBaseSnapshot() throws {
        var override = legacyRow("shared")
        override["contextWindow"] = 456
        override["showInAssistant"] = false
        let overrides = try JSONSerialization.data(withJSONObject: ["models": [override]])
        for data in [try snapshot([row("shared")]), Data("broken".utf8)] {
            let catalog = ModelCapabilityResolver.BundledModelCatalog.load(data: data, overridesData: overrides)
            let direct = ModelProvider(name: "Direct", inferenceURL: "https://api.openai.com/v1/responses")
            for provider in [direct, ModelProvider(name: "Gateway")] {
                let resolution = ModelCapabilityResolver.resolve(
                    model: AIModel(id: "shared"), provider: provider, catalogData: data, overridesData: overrides
                )
                #expect(resolution.model.contextLength == 456)
                #expect(!resolution.model.isShownInAssistant)
                #expect(resolution.catalogSource?.provider == "openai")
            }
            #expect(catalog.recordsByID["shared"]?.count == 1)
        }
    }

    @Test
    func matchingPrefersActualEndpointThenDirectVendorDeterministically() throws {
        let records = [row("shared", provider: "vercel"), row("shared"), row("shared", provider: "openrouter")]
        for ordered in [records, Array(records.reversed())] {
            let data = try snapshot(ordered)
            for (url, expected) in [
                ("https://ai-gateway.vercel.sh/v1", "vercel"),
                ("https://openrouter.ai/api/v1", "openrouter"),
                ("https://api.openai.com/v1", "openai"),
                ("https://gateway.example/openrouter.ai", "openai"),
                ("https://openrouter.ai.example/v1", "openai"),
            ] {
                let resolution = ModelCapabilityResolver.resolve(
                    model: AIModel(id: "shared"), provider: ModelProvider(name: "Gateway", inferenceURL: url),
                    catalogData: data
                )
                #expect(resolution.catalogSource?.provider == expected)
            }
        }
    }

    @Test
    func malformedSnapshotsUseFallback() throws {
        for data in [Data(), Data("invalid".utf8), Data("{}".utf8)] {
            let catalog = ModelCapabilityResolver.BundledModelCatalog.load(data: data)
            #expect(catalog.metadata == nil)
            let resolution = ModelCapabilityResolver.resolve(
                model: AIModel(id: "gpt-5-fixture"), provider: ModelProvider(name: "Gateway"), catalogData: data
            )
            #expect(resolution.catalogSource == nil)
            #expect(resolution.model.contextLength == nil)
            #expect(resolution.model.abilities.contains(.reasoning))
        }
    }

    @Test(arguments: ["new", "legacy", "missing", "malformed"])
    func bundleResourceSelectionPrefersNewNameAndSupportsLegacy(mode: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundleURL = directory.appendingPathComponent("Catalog.bundle")
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "test.catalog.\(UUID().uuidString)", "CFBundlePackageType": "BNDL",
            ],
            format: .xml, options: 0
        )
        try info.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        if mode != "missing" {
            let legacy = try JSONSerialization.data(withJSONObject: [
                "package": "pi-test", "version": "1.0", "commit": "legacy", "models": [legacyRow("legacy")],
            ])
            try legacy.write(to: resources.appendingPathComponent("PiModelCatalog.json"))
        }
        if mode == "new" || mode == "malformed" {
            let data = mode == "new" ? try snapshot([row("new")]) : Data("broken".utf8)
            try data.write(to: resources.appendingPathComponent("ModelCatalog.json"))
        }
        let bundle = try #require(Bundle(url: bundleURL))
        let loaded = ModelCapabilityResolver.BundledModelCatalog.load(bundles: [bundle])
        switch mode {
        case "new":
            #expect(loaded.recordsByID["new"]?.count == 1)
            #expect(loaded.recordsByID["legacy"] == nil)
        case "legacy":
            #expect(loaded.recordsByID["legacy"]?.count == 1)
            #expect(loaded.metadata?.package == "pi-test")
            #expect(loaded.metadata?.version == "1.0")
            #expect(loaded.metadata?.commit == "legacy")
        default:
            #expect(loaded.recordsByID.isEmpty)
            #expect(loaded.metadata == nil)
        }
    }

    private func snapshot(_ records: [[String: Any]]) throws -> Data {
        var providers: [String: [String: Any]] = [:]
        for var record in records {
            let provider = record.removeValue(forKey: "provider") as! String
            let id = record["id"] as! String
            providers[provider, default: [:]][id] = record
        }
        return try JSONSerialization.data(
            withJSONObject: providers.mapValues { ["models": $0] }, options: [.sortedKeys]
        )
    }

    private func row(
        _ id: String, provider: String = "openai", structuredOutput: Bool = false
    ) -> [String: Any] {
        [
            "provider": provider, "id": id, "name": id,
            "reasoning": false, "tool_call": false, "structured_output": structuredOutput,
            "modalities": ["input": ["text", "image", "pdf"], "output": ["text"]],
            "limit": ["context": 1000, "input": 900, "output": 100],
        ]
    }

    private func legacyRow(_ id: String) -> [String: Any] {
        [
            "provider": "openai", "id": id, "name": id, "type": "chat",
            "reasoning": false, "abilities": [],
            "input": ["text"], "output": ["text"], "effortWireValues": [:],
        ]
    }
}
