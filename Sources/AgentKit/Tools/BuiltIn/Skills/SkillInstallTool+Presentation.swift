import Foundation

nonisolated extension SkillInstallTool {
    public static func presentArguments(_ input: AgentToolArgumentDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        let object = input.arguments
        let locale = input.locale
        var items = AgentKnowledgeToolDetail.fields(object, locale: locale, excluding: ["files", "bytes", "warnings"])
        F.appendBytes(&items, "Size", object["bytes"], locale: locale)
        if let files = object["files"]?.arrayValue {
            items.append(AgentKnowledgeToolDetail.fileList(files, locale: locale))
        }
        for warning in object["warnings"]?.arrayValue ?? [] {
            if let text = warning.stringValue { items.append(.message(text, .warning)) }
        }
        return items
    }

    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue, object["saved"]?.boolValue == true else {
            return F.genericItems(input.result, locale: input.locale)
        }
        var items: [AgentToolDetail.Item] = [.message(F.localized("Skill installed", locale: input.locale), .success)]
        F.appendField(&items, "Skill", object["name"]?.stringValue, locale: input.locale)
        // A source is displayed as text; malformed historical URLs are never made executable links.
        F.appendField(&items, "Source", object["source"]?.stringValue, locale: input.locale)
        items += AgentKnowledgeToolDetail.availability(object, locale: input.locale)
        return items
    }
}
