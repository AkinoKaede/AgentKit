import Foundation

nonisolated extension SkillReadFileTool {
    public static func presentArguments(_ input: AgentToolArgumentDetailInput) -> [AgentToolDetail.Item] {
        AgentKnowledgeToolDetail.fields(input.arguments, locale: input.locale)
    }

    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue,
            object["files"]?.arrayValue != nil || object["binary"]?.boolValue == true
                || object["content"]?.stringValue != nil || object["instructions"]?.stringValue != nil
        else { return F.genericItems(input.result, locale: input.locale) }
        let locale = input.locale
        var items: [AgentToolDetail.Item] = []
        F.appendField(
            &items, "Skill", object["skill"]?.stringValue ?? input.arguments["name"]?.stringValue, locale: locale)
        F.appendField(
            &items, "Path", object["path"]?.stringValue ?? input.arguments["path"]?.stringValue, locale: locale)
        if let files = object["files"]?.arrayValue {
            items.append(AgentKnowledgeToolDetail.fileList(files, locale: locale))
        } else if object["binary"]?.boolValue == true {
            F.appendBytes(&items, "Size", object["bytes"], locale: locale)
            items.append(
                .message(
                    F.localized(
                        "Binary resource. Export it from the skill editor to use its original bytes.", locale: locale),
                    .secondary))
        } else if let content = object["content"]?.stringValue ?? object["instructions"]?.stringValue {
            if let offset = object["offset"]?.integerValue {
                let hasEmptyLine = content.isEmpty && offset <= (object["total_lines"]?.integerValue ?? 0)
                let count = content.isEmpty && !hasEmptyLine ? 0 : content.components(separatedBy: "\n").count
                if count > 0, offset > 0, offset <= Int.max - count {
                    items.append(F.field("Lines", "\(offset)–\(offset + count - 1)", locale: locale))
                } else {
                    items.append(.message(F.localized("No lines returned", locale: locale), .secondary))
                }
            }
            items.append(
                .text(
                    .init(
                        title: object["title"]?.stringValue, text: content,
                        style: object["offset"] == nil ? .plain : .monospaced)))
        }
        items += AgentKnowledgeToolDetail.more(object, locale: locale)
        return items
    }
}

nonisolated extension SkillsListTool {
    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let skills = input.result.objectValue?["skills"]?.arrayValue,
            skills.allSatisfy({ $0.objectValue?["name"]?.stringValue != nil })
        else { return F.genericItems(input.result, locale: input.locale) }
        let locale = input.locale
        return [
            .list(
                .init(
                    title: F.localized("Skills", locale: locale),
                    rows: skills.compactMap { value in
                        guard let object = value.objectValue, let name = object["name"]?.stringValue else { return nil }
                        var badges: [String] = []
                        if let enabled = object["enabled"]?.boolValue {
                            badges.append(F.localized(enabled ? "Enabled" : "Disabled", locale: locale))
                        }
                        if object["read_only"]?.boolValue == true {
                            badges.append(F.localized("Read-only", locale: locale))
                        }
                        return .init(
                            title: name, subtitle: object["description"]?.stringValue, badges: badges,
                            symbol: "book.closed")
                    }, emptyMessage: F.localized("No skills available", locale: locale)
                ))
        ]
    }
}
