import Foundation

nonisolated extension SkillManageTool {
    public static func presentArguments(_ input: AgentToolArgumentDetailInput) -> [AgentToolDetail.Item] {
        AgentKnowledgeToolDetail.operations(input.arguments, locale: input.locale, memory: false)
    }

    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue, object["saved"]?.boolValue == true else {
            return F.genericItems(input.result, locale: input.locale)
        }
        return [.message(F.localized("Skill changes saved", locale: input.locale), .success)]
            + AgentKnowledgeToolDetail.availability(object, locale: input.locale)
            + presentArguments(.init(arguments: input.arguments, locale: input.locale))
    }
}
