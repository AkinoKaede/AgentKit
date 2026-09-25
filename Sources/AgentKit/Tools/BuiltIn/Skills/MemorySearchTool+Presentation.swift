import Foundation

nonisolated extension MemorySearchTool {
    public static func presentArguments(_ input: AgentToolArgumentDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        var items = AgentKnowledgeToolDetail.fields(input.arguments, locale: input.locale, excluding: ["target"])
        if let target = input.arguments["target"]?.stringValue {
            let value: String
            switch target {
            case "memory": value = F.localized("Persistent memory", locale: input.locale)
            case "user": value = F.localized("User profile", locale: input.locale)
            default: value = target
            }
            items.append(F.field("Target", value, locale: input.locale))
        }
        return items
    }

    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        presentArguments(.init(arguments: input.arguments, locale: input.locale))
            + AgentToolDetailFormatting.genericItems(input.result, locale: input.locale)
    }
}
