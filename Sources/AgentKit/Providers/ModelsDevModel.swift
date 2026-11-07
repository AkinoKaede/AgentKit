import Foundation

/// A models.dev object. Codable preserves upstream keys and unknown fields,
/// including experimental settings and tiered pricing, without a private wire schema.
public nonisolated protocol ModelsDevObject: Codable, Hashable, Sendable {
    var fields: [String: AgentJSONValue] { get set }
    init(fields: [String: AgentJSONValue])
}

extension ModelsDevObject {
    public init(from decoder: any Decoder) throws {
        self.init(fields: try decoder.singleValueContainer().decode([String: AgentJSONValue].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fields)
    }
}

public nonisolated struct ModelsDevModel: ModelsDevObject {
    public var fields: [String: AgentJSONValue]

    public init(fields: [String: AgentJSONValue] = [:]) {
        self.fields = fields
    }

    public var id: String? {
        get { fields["id"]?.stringValue }
        set { fields["id"] = newValue.map { .string($0) } }
    }

    public var name: String? {
        get { fields["name"]?.stringValue }
        set { fields["name"] = newValue.map { .string($0) } }
    }

    public var description: String? {
        get { fields["description"]?.stringValue }
        set { fields["description"] = newValue.map { .string($0) } }
    }

    public var type: String? {
        get { fields["type"]?.stringValue }
        set { fields["type"] = newValue.map { .string($0) } }
    }

    public var family: String? {
        get { fields["family"]?.stringValue }
        set { fields["family"] = newValue.map { .string($0) } }
    }

    public var attachment: Bool? {
        get { fields["attachment"]?.boolValue }
        set { fields["attachment"] = newValue.map { .bool($0) } }
    }

    public var reasoning: Bool? {
        get { fields["reasoning"]?.boolValue }
        set { fields["reasoning"] = newValue.map { .bool($0) } }
    }

    public var toolCall: Bool? {
        get { fields["tool_call"]?.boolValue }
        set { fields["tool_call"] = newValue.map { .bool($0) } }
    }

    public var structuredOutput: Bool? {
        get { fields["structured_output"]?.boolValue }
        set { fields["structured_output"] = newValue.map { .bool($0) } }
    }

    public var temperature: Bool? {
        get { fields["temperature"]?.boolValue }
        set { fields["temperature"] = newValue.map { .bool($0) } }
    }

    public var knowledge: String? {
        get { fields["knowledge"]?.stringValue }
        set { fields["knowledge"] = newValue.map { .string($0) } }
    }

    public var releaseDate: String? {
        get { fields["release_date"]?.stringValue }
        set { fields["release_date"] = newValue.map { .string($0) } }
    }

    public var lastUpdated: String? {
        get { fields["last_updated"]?.stringValue }
        set { fields["last_updated"] = newValue.map { .string($0) } }
    }

    public var openWeights: Bool? {
        get { fields["open_weights"]?.boolValue }
        set { fields["open_weights"] = newValue.map { .bool($0) } }
    }

    public var status: String? {
        get { fields["status"]?.stringValue }
        set { fields["status"] = newValue.map { .string($0) } }
    }

    public var canonicalModelID: String? {
        get { fields["canonical_model_id"]?.stringValue }
        set { fields["canonical_model_id"] = newValue.map { .string($0) } }
    }

    public var modalities: ModelsDevModalities {
        get { ModelsDevModalities(fields: fields["modalities"]?.objectValue ?? [:]) }
        set { fields["modalities"] = .object(newValue.fields) }
    }

    public var limit: ModelsDevLimits {
        get { ModelsDevLimits(fields: fields["limit"]?.objectValue ?? [:]) }
        set { fields["limit"] = .object(newValue.fields) }
    }

    public var cost: ModelsDevCost {
        get { ModelsDevCost(fields: fields["cost"]?.objectValue ?? [:]) }
        set { fields["cost"] = .object(newValue.fields) }
    }

    public var reasoningOptions: [ModelsDevReasoningOption]? {
        get {
            fields["reasoning_options"]?.arrayValue?.compactMap {
                $0.objectValue.map { ModelsDevReasoningOption(fields: $0) }
            }
        }
        set { fields["reasoning_options"] = newValue.map { .array($0.map { .object($0.fields) }) } }
    }
}

public nonisolated struct ModelsDevLimits: ModelsDevObject {
    public var fields: [String: AgentJSONValue]

    public init(fields: [String: AgentJSONValue] = [:]) {
        self.fields = fields
    }

    public var context: Int? {
        get { fields["context"]?.integerValue }
        set { fields["context"] = newValue.map { .number(Double($0)) } }
    }

    public var input: Int? {
        get { fields["input"]?.integerValue }
        set { fields["input"] = newValue.map { .number(Double($0)) } }
    }

    public var output: Int? {
        get { fields["output"]?.integerValue }
        set { fields["output"] = newValue.map { .number(Double($0)) } }
    }
}

public nonisolated struct ModelsDevCost: ModelsDevObject {
    public var fields: [String: AgentJSONValue]

    public init(fields: [String: AgentJSONValue] = [:]) {
        self.fields = fields
    }

    public var input: Double? {
        get { fields["input"]?.numberValue }
        set { fields["input"] = newValue.map { .number($0) } }
    }

    public var output: Double? {
        get { fields["output"]?.numberValue }
        set { fields["output"] = newValue.map { .number($0) } }
    }

    public var cacheRead: Double? {
        get { fields["cache_read"]?.numberValue }
        set { fields["cache_read"] = newValue.map { .number($0) } }
    }

    public var cacheWrite: Double? {
        get { fields["cache_write"]?.numberValue }
        set { fields["cache_write"] = newValue.map { .number($0) } }
    }
}

public nonisolated struct ModelsDevReasoningOption: ModelsDevObject {
    public var fields: [String: AgentJSONValue]

    public init(fields: [String: AgentJSONValue] = [:]) {
        self.fields = fields
    }

    public var type: String? {
        get { fields["type"]?.stringValue }
        set { fields["type"] = newValue.map { .string($0) } }
    }

    public var min: Int? {
        get { fields["min"]?.integerValue }
        set { fields["min"] = newValue.map { .number(Double($0)) } }
    }

    public var max: Int? {
        get { fields["max"]?.integerValue }
        set { fields["max"] = newValue.map { .number(Double($0)) } }
    }

    public var values: [String]? {
        get { fields["values"]?.arrayValue?.compactMap(\.stringValue) }
        set { fields["values"] = newValue.map { .array($0.map(AgentJSONValue.string)) } }
    }
}

public nonisolated struct ModelsDevModalities: ModelsDevObject {
    public var fields: [String: AgentJSONValue]

    public init(fields: [String: AgentJSONValue] = [:]) {
        self.fields = fields
    }

    public var input: [String]? {
        get { fields["input"]?.arrayValue?.compactMap(\.stringValue) }
        set { fields["input"] = newValue.map { .array($0.map(AgentJSONValue.string)) } }
    }

    public var output: [String]? {
        get { fields["output"]?.arrayValue?.compactMap(\.stringValue) }
        set { fields["output"] = newValue.map { .array($0.map(AgentJSONValue.string)) } }
    }
}

public nonisolated struct ModelsDevProvider: ModelsDevObject {
    public var fields: [String: AgentJSONValue]

    public init(fields: [String: AgentJSONValue] = [:]) {
        self.fields = fields
    }

    public var id: String? {
        get { fields["id"]?.stringValue }
        set { fields["id"] = newValue.map { .string($0) } }
    }

    public var name: String? {
        get { fields["name"]?.stringValue }
        set { fields["name"] = newValue.map { .string($0) } }
    }

    public var api: String? {
        get { fields["api"]?.stringValue }
        set { fields["api"] = newValue.map { .string($0) } }
    }

    public var npm: String? {
        get { fields["npm"]?.stringValue }
        set { fields["npm"] = newValue.map { .string($0) } }
    }

    public var doc: String? {
        get { fields["doc"]?.stringValue }
        set { fields["doc"] = newValue.map { .string($0) } }
    }

    public var env: [String]? {
        get { fields["env"]?.arrayValue?.compactMap(\.stringValue) }
        set { fields["env"] = newValue.map { .array($0.map(AgentJSONValue.string)) } }
    }

    public var models: [String: ModelsDevModel] {
        get {
            (fields["models"]?.objectValue ?? [:]).compactMapValues {
                $0.objectValue.map { ModelsDevModel(fields: $0) }
            }
        }
        set { fields["models"] = .object(newValue.mapValues { .object($0.fields) }) }
    }
}
