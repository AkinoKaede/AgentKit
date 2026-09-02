import Foundation

/// The JSON Schema fragments and result envelope every built-in tool file shares.
///
/// A protocol with defaults rather than a namespace enum, for one reason: a
/// conforming type calls `descriptor(…)` and `string(max:)` unqualified, exactly as
/// it did when these were private members of `AgentToolSupport`. So a second tool
/// file costs a conformance instead of a copy of forty lines — which is the seam
/// this is for. Nothing here holds state; conformers are caseless enums.
public nonisolated protocol AgentToolSchemaBuilding: Sendable {}
nonisolated

    extension AgentToolSchemaBuilding
{
    /// The one envelope every tool result goes through.
    ///
    /// A remote file, a web page, an MCP payload and a scratch file are all things
    /// someone other than the user wrote, and the system prompt tells the model to
    /// treat what is inside these tags as data. Wrapping happens here so a new tool
    /// cannot forget to.
    public static func result(
        _ invocation: AgentToolInvocation, _ value: AgentJSONValue, truncated: Bool = false
    ) -> AgentToolResult {
        AgentToolResult(
            callID: invocation.call.id,
            content: "\(AgentToolResult.untrustedDataOpeningMarker)\(value.encodedString)"
                + AgentToolResult.untrustedDataClosingMarker,
            isTruncated: truncated,
            metadata: ["untrusted": .bool(true)]
        )
    }

    public static func descriptor(
        _ name: String, _ summary: String, properties: [String: AgentJSONValue],
        required: [String], target: AgentToolDescriptor.Target,
        safety: AgentToolDescriptor.Safety,
        concurrency: AgentToolDescriptor.Concurrency = .sequential,
        presentation: AgentToolDescriptor.Presentation? = nil
    ) -> AgentToolDescriptor {
        AgentToolDescriptor(
            name: name, summary: summary,
            inputSchema: .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(AgentJSONValue.string)),
                "additionalProperties": .bool(false),
            ]),
            target: target, safety: safety, concurrency: concurrency,
            presentation: presentation
        )
    }

    public static func string(max: Int? = nil) -> AgentJSONValue {
        var schema: [String: AgentJSONValue] = ["type": .string("string")]
        if let max { schema["maxLength"] = .number(Double(max)) }
        return .object(schema)
    }

    public static func boolean() -> AgentJSONValue { .object(["type": .string("boolean")]) }

    public static func integer(min: Int, max: Int) -> AgentJSONValue {
        .object([
            "type": .string("integer"), "minimum": .number(Double(min)),
            "maximum": .number(Double(max)),
        ])
    }

    public static func enumeration(_ values: [String]) -> AgentJSONValue {
        .object([
            "type": .string("string"), "enum": .array(values.map(AgentJSONValue.string)),
        ])
    }

    public static func array(items: AgentJSONValue, max: Int) -> AgentJSONValue {
        .object([
            "type": .string("array"), "items": items, "maxItems": .number(Double(max)),
        ])
    }

    /// Attaches a JSON Schema `description` to a fragment.
    ///
    /// A tool's one-line `summary` is otherwise the only prose the model gets, which
    /// is enough for a property whose name says everything and not enough for one
    /// whose meaning is a convention — "omit for exactly one, 0 for every
    /// occurrence". `description` is a standard keyword every provider dialect
    /// forwards, and `AgentJSONSchemaValidator` ignores it.
    public static func described(_ schema: AgentJSONValue, _ text: String) -> AgentJSONValue {
        guard var object = schema.objectValue else { return schema }
        object["description"] = .string(text)
        return .object(object)
    }

    public static func object(
        properties: [String: AgentJSONValue], required: [String]
    ) -> AgentJSONValue {
        .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(AgentJSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }
}
