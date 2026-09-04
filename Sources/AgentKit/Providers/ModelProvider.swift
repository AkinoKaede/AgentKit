import Foundation

/// Which request and response shape an endpoint speaks.
///
/// Four, not thirty, and named for the protocol rather than for whoever
/// published it first. OpenRouter, DeepSeek, Groq, Together and Ollama all
/// serve `.chatCompletions`; listing them as separate kinds would be listing
/// one protocol five times and then owing an entry to whoever launches next
/// week. Naming them after a vendor has the same problem in the other
/// direction — most endpoints speaking a shape are not the vendor that
/// introduced it.
///
/// Ordered the way they are shown, and `.chatCompletions` first because it is
/// both the most common and the one every compatible gateway needs.
public nonisolated enum ModelAPIFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case chatCompletions
    case responses
    case messages
    case generateContent

    public nonisolated var id: String { rawValue }
}

/// Google Vertex AI, which is a different way of reaching the same models.
///
/// Not a fifth `ModelAPIFormat`, because the request and response bodies are
/// Gemini's — only the address and the credential change. Kept as a stored
/// struct beside a `usesVertex` flag rather than as an `Optional`, so turning
/// the toggle off and on again does not erase a project id that was typed.
public nonisolated struct VertexConfig: Hashable, Sendable {
    public init(
        projectID: String = "",
        location: String = "global",
        credentialRef: String = "",
        clientEmail: String = ""
    ) {
        self.projectID = projectID
        self.location = location
        self.credentialRef = credentialRef
        self.clientEmail = clientEmail
    }

    public var projectID: String = ""
    /// `global` or a region such as `us-central1`.
    public var location: String = "global"
    /// Where the service account JSON is filed. The JSON holds an RSA private
    /// key, which is a stronger credential than an API key, so it is stored by
    /// reference like every other secret in this app.
    public var credentialRef: String = ""
    /// Lifted out of that JSON at import time so the editor can say who it
    /// signed in as without loading the key back into the view layer.
    public var clientEmail: String = ""

    /// Regional hosts are prefixed; `global` is not. Getting this backwards
    /// produces a DNS failure rather than an API error, which reads like a
    /// network problem and is not one.
    public var host: String {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "global" else {
            return "aiplatform.googleapis.com"
        }
        return "\(trimmed)-aiplatform.googleapis.com"
    }

    public var isComplete: Bool {
        !projectID.trimmingCharacters(in: .whitespaces).isEmpty && !credentialRef.isEmpty
    }
}

/// One configured endpoint: where to send requests, what to authenticate with,
/// and which models it offers.
///
/// Nothing secret is stored here. `credentialRef` is a lookup string — "the key
/// is filed under this name" — exactly as `Identity.credentialRef` is, so
/// neither an API key nor a service account has a path into this struct, and
/// therefore none into SwiftData or CloudKit later.
public nonisolated struct ModelProvider: Identifiable, Hashable, Sendable {
    public init(
        id: UUID = UUID(),
        name: String,
        apiFormat: ModelAPIFormat = .chatCompletions,
        isEnabled: Bool = true,
        url: String = "",
        credentialRef: String = "",
        usesVertex: Bool = false,
        vertex: VertexConfig = VertexConfig(),
        models: [AIModel] = [],
        modelsFetchedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.apiFormat = apiFormat
        self.isEnabled = isEnabled
        self.url = url
        self.credentialRef = credentialRef
        self.usesVertex = usesVertex
        self.vertex = vertex
        self.models = models
        self.modelsFetchedAt = modelsFetchedAt
    }

    /// The one substitution a URL may contain. Only `.generateContent`
    /// ordinarily needs it — that shape addresses the model in the path rather
    /// than in the body — but any URL may use it.
    public static let modelToken = "{model}"

    public var id: UUID = UUID()
    /// What the user calls this. Free text, because two providers can speak the
    /// same format — "Work" and "Personal" is an ordinary setup.
    public var name: String
    public var apiFormat: ModelAPIFormat = .chatCompletions
    /// A disabled provider keeps its configuration but stops offering its
    /// models anywhere. Deleting to silence one would mean retyping the key.
    public var isEnabled: Bool = true
    /// The complete address a chat request goes to, with `{model}` where the
    /// model id belongs.
    ///
    /// Composed by the caller. This type appends no path and applies no
    /// default, so what is stored is where requests land — the single most
    /// common source of "why does my custom endpoint 404" is a client that
    /// tries to be clever about whether the pasted URL already carried `/v1`,
    /// and the way not to have that bug is not to guess. A blank URL is not a
    /// provider pointed somewhere sensible; it is a provider pointed nowhere,
    /// and it fails as one.
    public var url: String = ""
    public var credentialRef: String = ""
    /// `.generateContent` only — see `usesVertexEndpoint`.
    public var usesVertex: Bool = false
    public var vertex: VertexConfig = VertexConfig()
    public var models: [AIModel] = []
    public var modelsFetchedAt: Date?

    // MARK: - Resolution

    /// The flag is inert on any other shape: Vertex serves Gemini's bodies, so
    /// pointing it at a Chat Completions provider describes nothing that exists.
    public var usesVertexEndpoint: Bool { usesVertex && apiFormat == .generateContent }

    public var effectiveCredentialRef: String {
        usesVertexEndpoint ? vertex.credentialRef : credentialRef
    }

    /// The URL a chat request actually goes to: `url` with the model id filled
    /// in, or — for Vertex — the address derived from the project and location,
    /// which is not typed anywhere and so cannot be stored in `url`.
    ///
    /// `model` is optional because an editor has to draw this line before any
    /// model is picked; the token is left in place then, which reads correctly
    /// as "your model id goes here".
    public func requestURL(model: String? = nil) -> String {
        let modelID = model ?? Self.modelToken

        if usesVertexEndpoint {
            return "https://\(vertex.host)/v1/projects/\(vertex.projectID)"
                + "/locations/\(vertex.location)/publishers/google/models/\(modelID):generateContent"
        }

        return url.replacingOccurrences(of: Self.modelToken, with: modelID)
    }

    // MARK: - State

    public var hasCredential: Bool {
        usesVertexEndpoint ? vertex.isComplete : !credentialRef.isEmpty
    }

    /// Whether this wire protocol has anywhere to *put* a server-side search
    /// tool. A hard fact about the request body, not a guess.
    ///
    /// Chat Completions has nowhere. OpenAI's `web_search_options` exists there
    /// only on the two `*-search-preview` SKUs, while `.chatCompletions` is
    /// also every compatible gateway this package talks to — OpenRouter,
    /// DeepSeek, Groq, Together, Ollama. Sending them an option they have never
    /// heard of turns a working setup into a 400 for a feature nobody asked
    /// for. Nothing overrides this, including the user, because overriding it
    /// would produce a request with no search tool in it at all.
    public var acceptsNativeWebSearchTool: Bool {
        switch apiFormat {
        case .responses, .messages, .generateContent: true
        case .chatCompletions: false
        }
    }

    /// Whether the *model* is one this endpoint runs search for.
    ///
    /// A guess, unlike `acceptsNativeWebSearchTool`, and `WebSearchMode` exists
    /// so the user can overrule it either way.
    ///
    /// The API format alone is not enough, which is the part that had to be
    /// learned. A server tool exists at the intersection of *this vendor's API*
    /// and *this vendor's model*, and a gateway breaks that pairing: point a
    /// `.responses` endpoint at Claude and it will accept
    /// `{"type": "web_search"}` and forward it as an ordinary function
    /// declaration. The model then calls `web_search` as a tool, nothing here
    /// has one registered — because native mode deliberately withholds the
    /// local tool — and the run reports `Unknown tool: web_search`.
    ///
    /// DeepSeek is the case that shows the rule is about *implementation*
    /// rather than branding. It ships both shapes and implements the server
    /// tool in each: `/responses` takes `{"type": "web_search"}` and answers
    /// with `web_search_call` items, while `/anthropic` documents
    /// `server_tool_use` and `web_search_tool_result` as supported content
    /// blocks — marking `code_execution_tool_result` and `mcp_tool_use`
    /// unsupported in the same table, so that list is real and not copied. It
    /// is a first party on both, and reading "not Anthropic's own model" as "no
    /// native search" would refuse a pairing that works.
    public func supportsNativeWebSearch(model: AIModel) -> Bool {
        guard model.abilities.contains(.webSearch), acceptsNativeWebSearchTool else {
            return false
        }
        let id = model.id.lowercased()
        switch apiFormat {
        case .messages:
            return id.contains("claude") || id.contains("deepseek")
        case .generateContent:
            return id.contains("gemini")
        // `.chatCompletions` never reaches here — `acceptsNativeWebSearchTool`
        // has already refused it — but the switch owes every shape an answer.
        case .responses, .chatCompletions:
            return id.contains("gpt") || id.contains("deepseek")
                || id.range(of: #"(^|[-_/])o[3-9]([-._/]|$)"#, options: .regularExpression) != nil
        }
    }

    /// What the role pickers and the conversation's model menu offer. An
    /// embedding model in a chat-model picker is noise.
    public var chatModels: [AIModel] {
        models.filter { $0.kind == .chat }
    }

    /// Chat models offered by the Assistant's model picker and `/model`
    /// completion. Settings deliberately continues to use `chatModels` so a
    /// model hidden from the Assistant can still serve a configured role.
    public var assistantModels: [AIModel] {
        chatModels.filter(\.isShownInAssistant)
    }

    public func model(_ id: String) -> AIModel? {
        models.first { $0.id == id }
    }

}

/// One model on one provider.
///
/// The shape is wider than any single vendor reports, because the same
/// `GET /models` call answers very differently depending on who is behind it: a
/// good gateway sends name, type, modalities, capabilities and token limits,
/// while `api.openai.com` sends an id and an owner. Every field but `id` is
/// therefore optional on the wire, filled by the decoder where the server spoke
/// and by `ModelCapabilityResolver` where it did not.
public nonisolated struct AIModel: Identifiable, Hashable, Sendable {
    public init(
        id: String,
        displayName: String = "",
        ownedBy: String = "",
        kind: Kind = .chat,
        input: Set<Modality> = [.text],
        output: Set<Modality> = [.text],
        abilities: Set<Ability> = [],
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        iconHint: String = "",
        createdAt: Date? = nil,
        origin: Origin = .manual,
        isShownInAssistant: Bool = true,
        reasoningProfile: ReasoningProfile? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.ownedBy = ownedBy
        self.kind = kind
        self.input = input
        self.output = output
        self.abilities = abilities
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.iconHint = iconHint
        self.createdAt = createdAt
        self.origin = origin
        self.isShownInAssistant = isShownInAssistant
        self.reasoningProfile = reasoningProfile
    }

    /// What a request body carries, and what a `AIModelRef` points at. Two
    /// models on one provider cannot share one.
    public var id: String
    /// Blank falls back to `id` — see `label`.
    public var displayName: String = ""
    /// `owned_by`. The only field the barest rows carry beyond the id, which
    /// makes it the only thing available to group them by.
    public var ownedBy: String = ""
    public var kind: Kind = .chat
    public var input: Set<Modality> = [.text]
    public var output: Set<Modality> = [.text]
    public var abilities: Set<Ability> = []
    public var contextLength: Int?
    public var maxOutputTokens: Int?
    /// The vendor brand string a gateway may send (`"Claude"`, `"DeepSeek"`).
    /// Used for the row glyph and nothing else — it is a hint, not an identity.
    public var iconHint: String = ""
    public var createdAt: Date?
    public var origin: Origin = .manual
    /// Whether the Assistant offers this model as a new conversation choice.
    /// Existing references and Settings role assignments remain valid when it
    /// is off.
    public var isShownInAssistant = true
    /// `nil` follows the built-in model-family rules. A value is an explicit
    /// per-model override and survives catalog refreshes.
    public var reasoningProfile: ReasoningProfile?

    public var label: String {
        displayName.isEmpty ? id : displayName
    }

    /// Derived rather than stored, because a payload can assert it twice — once
    /// as `capabilities.vision` and once as `image` in `modalities.input` — and
    /// two fields that mean one thing eventually disagree. The decoder folds
    /// the flag into the modality set, and everything reads it from here.
    public var isVision: Bool { input.contains(.image) }

    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return id.lowercased().contains(q)
            || displayName.lowercased().contains(q)
            || ownedBy.lowercased().contains(q)
    }

    /// What a model is *for*. `other` exists so an unrecognised `type` string
    /// can be kept rather than thrown away or silently called a chat model —
    /// this list meets gateways that invent values.
    public nonisolated enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case chat, embedding, image, other

        public nonisolated var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .chat: String(localized: "Chat", bundle: .module)
            case .embedding: String(localized: "Embedding", bundle: .module)
            case .image: String(localized: "Image", bundle: .module)
            case .other: String(localized: "Other", bundle: .module)
            }
        }

        /// Lenient on purpose: an unknown string is `.other`, never a throw.
        /// Absent — which is most of the wire — means `.chat`, since that is
        /// what an endpoint that does not classify its models is serving.
        public init(wire: String?) {
            guard let wire, !wire.isEmpty else {
                self = .chat
                return
            }
            self = Kind(rawValue: wire.lowercased()) ?? .other
        }
    }

    /// Five, not two. `pdf`, `audio` and `video` all appear in real payloads —
    /// Gemini reports every one of them — and a client that can only say "text
    /// or image" has to discard the difference.
    public nonisolated enum Modality: String, Codable, Sendable, CaseIterable, Identifiable {
        case text, image, audio, video, pdf

        public nonisolated var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .text: String(localized: "Text", bundle: .module)
            case .image: String(localized: "Image", bundle: .module)
            case .audio: String(localized: "Audio", bundle: .module)
            case .video: String(localized: "Video", bundle: .module)
            case .pdf: String(localized: "PDF", bundle: .module)
            }
        }

        public var symbol: String {
            switch self {
            case .text: "text.alignleft"
            case .image: "photo"
            case .audio: "waveform"
            case .video: "film"
            case .pdf: "doc.richtext"
            }
        }
    }

    public nonisolated enum Ability: String, Codable, Sendable, CaseIterable, Identifiable {
        case toolCall, reasoning
        /// The provider runs the search on its own servers when asked, rather
        /// than the model calling one of our tools. Whether that offer is
        /// actually taken up also depends on the API format — see
        /// `ModelProvider.supportsNativeWebSearch`.
        case webSearch

        public nonisolated var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .toolCall: String(localized: "Tools", bundle: .module)
            case .reasoning: String(localized: "Reasoning", bundle: .module)
            case .webSearch: String(localized: "Web Search", bundle: .module)
            }
        }

        public var symbol: String {
            switch self {
            case .toolCall: "wrench.and.screwdriver"
            case .reasoning: "brain"
            case .webSearch: "magnifyingglass"
            }
        }
    }

    /// Whether this row came off the wire or was typed. Shown in the editor so
    /// a hand-added model is not silently replaced by the next fetch.
    public nonisolated enum Origin: String, Codable, Sendable {
        case fetched, manual
    }
}

/// One explicit entry in a model's custom reasoning profile.
///
/// A blank `wireValue` means "use the provider's ordinary value for this
/// level". Keeping support separate from the value is important: providers
/// such as Gemini use uppercase wire values, while a missing level means the
/// level is unsupported rather than merely unmapped.
public nonisolated struct ReasoningLevelMapping: Hashable, Codable, Sendable {
    public var isSupported: Bool
    public var wireValue: String?

    public init(isSupported: Bool = true, wireValue: String? = nil) {
        self.isSupported = isSupported
        self.wireValue = wireValue
    }
}

/// A complete manual override for the seven stable effort levels.
public nonisolated struct ReasoningProfile: Hashable, Codable, Sendable {
    public var levels: [ReasoningEffort: ReasoningLevelMapping]

    public init(levels: [ReasoningEffort: ReasoningLevelMapping] = [:]) {
        self.levels = levels
    }

    public func mapping(for effort: ReasoningEffort) -> ReasoningLevelMapping {
        levels[effort] ?? ReasoningLevelMapping(isSupported: false)
    }
}

/// A model, addressed the way every assignment has to address one.
///
/// Two providers can both offer `gpt-5` — one your employer's account, one your
/// own — so a bare model id names a request but not which key pays for it. That
/// is the whole reason this is a pair.
public nonisolated struct AIModelRef: Hashable, Codable, Sendable {
    public init(
        modelProviderID: ModelProvider.ID,
        modelID: String
    ) {
        self.modelProviderID = modelProviderID
        self.modelID = modelID
    }

    public var modelProviderID: ModelProvider.ID
    public var modelID: String
}

/// What the app asks a model to do.
///
/// The list is short on purpose. A role earns its place by wanting a
/// *materially different* model, not by being a different prompt — titling a
/// conversation and summarising a thread both want "whatever the chat model is,
/// but cheaper", which is a decision the chat picker already expresses. Roles
/// that only ever get set to the same thing are multiple pickers pretending to be a
/// choice.
///
/// What is left is a few jobs with genuinely different requirements: holding a
/// conversation, quickly rewriting a draft, and supplying a *second opinion*.
///
/// None of them is required — see `AIConfigurationModel.resolve(_:)`.
public nonisolated enum AIRole: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The assistant, whether it is answering or acting. One role rather than
    /// two: "chat" and "agent" differ in what tools the turn is given, not in
    /// which model should be behind it, and splitting them would ask the user a
    /// question that has one answer.
    case chat
    case commandGenerator
    case securityReview

    public nonisolated var id: String { rawValue }

    public var displayName: String {
        switch self {
        // Just "Chat", though it covers agent turns too. A label reading
        // "Chat & Agent" implies a second setting exists somewhere.
        case .chat: String(localized: "Chat", bundle: .module)
        case .commandGenerator: String(localized: "Command Generator", bundle: .module)
        case .securityReview: String(localized: "Security Review", bundle: .module)
        }
    }

    public var detail: String {
        switch self {
        case .chat:
            String(localized: "Used for chat, tools, and the Assistant sidebar.", bundle: .module)
        case .commandGenerator:
            String(
                localized:
                    "Turns the current terminal input into one command. Choose a fast model."
            )
        // Names two models outright. This one runs on every command Approve for
        // Me would execute, so it sits in the latency path — a deliberate
        // reasoning model here makes the feature feel broken even when it
        // works, and that is not something a user should have to discover.
        case .securityReview:
            String(
                localized:
                    "Reviews commands before automatic approval. Choose a fast model different from Chat; Same as Chat is not an independent second opinion."
            )
        }
    }

    /// What the picker shows when nothing is assigned.
    ///
    /// Chat says "Automatic" because it resolves to something rather than to
    /// nothing; the rest say what they actually do, which is follow Chat.
    public var unsetLabel: String {
        switch self {
        case .chat: String(localized: "Automatic", bundle: .module)
        default: String(localized: "Same as Chat", bundle: .module)
        }
    }
}
