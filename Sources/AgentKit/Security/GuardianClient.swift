import Foundation

/// A fail-closed Guardian backed by an isolated agent loop.
public nonisolated struct GuardianClient: GuardianReviewing, Sendable {
    private let model: any AgentModelStreaming
    private let sessions: GuardianSessionStore
    private let sessionID: String
    private let tools: AgentToolRegistry
    private let services: AgentToolServices
    private let additionalPolicy: String

    public init(
        model: any AgentModelStreaming,
        sessions: GuardianSessionStore = GuardianSessionStore(),
        sessionID: String = UUID().uuidString,
        tools: AgentToolRegistry = AgentToolRegistry([]),
        services: AgentToolServices = AgentToolServices(),
        additionalPolicy: String = ""
    ) {
        self.model = model
        self.sessions = sessions
        self.sessionID = sessionID
        self.tools = tools.available(in: .reviewing)
        self.services = services
        self.additionalPolicy = additionalPolicy
    }

    /// Guardian runs in the approval latency path, so start at low. The
    /// shared clamp moves upward first for models that do not expose low.
    public static func preferredReasoning(
        model: AIModel, provider: ModelProvider
    ) -> ReasoningEffort {
        ModelCapabilityResolver.reasoning(model: model, provider: provider)
            .clamp(.low)
    }

    public func review(_ request: AgentApprovalRequest) async throws -> GuardianDecision {
        let toolChannel = tools.descriptors.isEmpty ? "no-tools" : "tools"
        return try await sessions.review(
            channelID: "\(sessionID):\(toolChannel)",
            request: request,
            model: model,
            tools: tools,
            services: services,
            systemPrompt: GuardianPolicy.systemPrompt(
                additionalPolicy: additionalPolicy,
                toolsAvailable: !tools.descriptors.isEmpty
            )
        )
    }

    public static let outputFormat = AgentModelOutputFormat(
        name: "guardian_decision",
        schema: .object([
            "type": .string("object"),
            "properties": .object([
                "outcome": .object([
                    "type": .string("string"),
                    "enum": .array([.string("allow"), .string("deny")]),
                ]),
                "rationale": .object(["type": .string("string")]),
                "risk_level": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("low"), .string("medium"), .string("high"), .string("critical"),
                    ]),
                ]),
                "user_authorization": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("unknown"), .string("low"), .string("medium"), .string("high"),
                    ]),
                ]),
            ]),
            "required": .array([.string("outcome")]),
            "additionalProperties": .bool(false),
        ]),
        strict: false
    )
}

public nonisolated enum GuardianError: LocalizedError, Sendable {
    case invalidResponse
    case turnBudgetExceeded
    case toolBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            String(localized: "Auto-reviewing returned an invalid decision.", bundle: .module)
        case .turnBudgetExceeded:
            String(localized: "Auto-reviewing exceeded its reasoning turn limit.", bundle: .module)
        case .toolBudgetExceeded:
            String(localized: "Auto-reviewing exceeded its investigation limit.", bundle: .module)
        }
    }
}
