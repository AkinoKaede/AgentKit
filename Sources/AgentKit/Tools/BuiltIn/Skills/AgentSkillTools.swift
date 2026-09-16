import Foundation

/// Tells the model which skills it has, without spending what they say.
///
/// At the model boundary rather than in the system prompt, for the reason
/// `AgentSessionContextInjection` already documents at length: every provider
/// cache is a *prefix* cache, so a list that changes when the user enables a
/// skill would miss the whole replayed conversation on the next turn.
/// `AgentSystemPrompt.default` stays byte-identical for every run, and this
/// rides the tail in front of the prompt where nothing was cacheable anyway.
///
/// Anchored to the prompt by identity rather than by index, like the transforms
/// beside it: what runs ahead of this is free to add and remove messages.
public nonisolated struct AgentSkillCatalogInjection: AgentContextTransforming {
    public var catalog: AgentSkillCatalog
    public var before: AgentTranscriptMessage.ID?

    public init(catalog: AgentSkillCatalog, before: AgentTranscriptMessage.ID?) {
        self.catalog = catalog
        self.before = before
    }

    public func transform(_ context: AgentModelContext) -> AgentModelContext {
        guard !catalog.isEmpty, let before,
            let index = context.messages.firstIndex(where: { $0.id == before })
        else { return context }
        var result = context
        result.messages.insert(
            AgentTranscriptMessage(role: .user, text: catalog.catalogBlock), at: index
        )
        return result
    }
}
