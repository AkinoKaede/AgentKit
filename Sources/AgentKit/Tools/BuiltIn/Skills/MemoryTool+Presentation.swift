import Foundation

nonisolated extension MemoryTool {
    public static func presentArguments(_ input: AgentToolArgumentDetailInput) -> [AgentToolDetail.Item] {
        AgentKnowledgeToolDetail.operations(input.arguments, locale: input.locale, memory: true)
    }

    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let memory = input.result.objectValue?["memory"]?.stringValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        var items: [AgentToolDetail.Item] = []
        if input.arguments["operations"]?.arrayValue?.isEmpty == false {
            // These are processed requests, not a claim about how many entries changed:
            // an add may have been deduplicated by the store.
            items.append(.message(F.localized("Memory operations processed", locale: input.locale), .success))
            items += presentArguments(.init(arguments: input.arguments, locale: input.locale))
        }
        items.append(
            .text(
                .init(
                    title: F.localized("Current memory", locale: input.locale), text: memory, style: .plain)))
        return items
    }
}
