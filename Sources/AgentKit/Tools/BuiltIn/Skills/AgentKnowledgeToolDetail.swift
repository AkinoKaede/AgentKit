import Foundation

/// Small, UI-neutral building blocks shared by knowledge-tool presenters.
/// Never interprets saved prose as a schema or reads live state while rendering history.
nonisolated enum AgentKnowledgeToolDetail {
    typealias F = AgentToolDetailFormatting
    typealias Item = AgentToolDetail.Item

    static func fields(
        _ object: [String: AgentJSONValue], locale: Locale,
        excluding: Set<String> = [], contentLabel: String.LocalizationValue = "Content"
    ) -> [Item] {
        var items: [Item] = []
        let labels: [(String, String.LocalizationValue)] = [
            ("name", "Skill"), ("skill", "Skill"), ("title", "Title"),
            ("path", "Path"), ("source_url", "Source URL"), ("resolved_source", "Resolved source"),
            ("source", "Source"), ("commit", "Commit"), ("description", "Description"),
            ("query", "Query"), ("conversation_id", "Conversation ID"),
            ("offset", "Offset"), ("limit", "Limit"), ("enabled", "Enabled"),
        ]
        var handled = excluding
        for (key, label) in labels where !excluding.contains(key) {
            guard let value = object[key], value != .null else { continue }
            handled.insert(key)
            let text: String
            if let boolean = value.boolValue {
                text = F.localized(boolean ? "Yes" : "No", locale: locale)
            } else if let string = value.stringValue {
                text = string
            } else if let integer = value.integerValue {
                text = String(integer)
            } else {
                items += F.genericItems(.object([key: value]), locale: locale)
                continue
            }
            // Long request strings are text blocks, not single-line field values.
            items.append(.text(.init(title: F.localized(label, locale: locale), text: text, style: .plain)))
        }
        for (key, label) in [
            ("old_text", String.LocalizationValue("Matching text")), ("content", contentLabel),
        ] where !excluding.contains(key) {
            if let text = object[key]?.stringValue {
                handled.insert(key)
                items.append(F.text(label, text, locale: locale))
            }
        }
        let remaining = object.filter { !handled.contains($0.key) }
        if !remaining.isEmpty { items += F.genericItems(.object(remaining), locale: locale) }
        return items
    }

    static func fileList(_ values: [AgentJSONValue], locale: Locale) -> Item {
        .list(
            .init(
                title: F.localized("Files", locale: locale),
                rows: values.compactMap { $0.stringValue }.map { .init(title: $0, symbol: "doc") },
                emptyMessage: F.localized("No files", locale: locale)
            ))
    }

    static func more(_ object: [String: AgentJSONValue], locale: Locale) -> [Item] {
        guard object["next_offset"]?.integerValue != nil else { return [] }
        return [.message(F.localized("More results are available", locale: locale), .secondary)]
    }

    static func availability(_ object: [String: AgentJSONValue], locale: Locale) -> [Item] {
        guard object["available"]?.stringValue == "next_run" else { return [] }
        return [.message(F.localized("Available on the next run", locale: locale), .secondary)]
    }

    static func operations(
        _ arguments: [String: AgentJSONValue], locale: Locale, memory: Bool
    ) -> [Item] {
        guard let operations = arguments["operations"]?.arrayValue else {
            return F.genericItems(.object(arguments), locale: locale)
        }
        var items: [Item] = []
        for (index, value) in operations.enumerated() {
            guard let object = value.objectValue, let action = object["action"]?.stringValue else {
                items += F.genericItems(value, locale: locale)
                continue
            }
            let label: String.LocalizationValue
            switch action {
            case "add": label = "Add memory"
            case "replace": label = "Replace memory"
            case "remove": label = "Remove memory"
            case "create": label = "Create skill"
            case "update": label = "Update skill"
            case "patch": label = "Patch skill"
            case "delete": label = "Delete skill"
            case "set_enabled": label = "Set skill availability"
            case "write_file": label = "Write skill file"
            case "remove_file": label = "Remove skill file"
            default:
                items += F.genericItems(value, locale: locale)
                continue
            }
            items.append(.message("\(index + 1). \(F.localized(label, locale: locale))", .secondary))
            var excluded: Set<String> = ["action"]
            if memory, let target = object["target"]?.stringValue, ["memory", "user"].contains(target) {
                excluded.insert("target")
                items.append(
                    F.field(
                        "Target", F.localized(target == "user" ? "User profile" : "memory", locale: locale),
                        locale: locale))
            }
            items += fields(
                object, locale: locale, excluding: excluded,
                contentLabel: action == "patch" || action == "replace" ? "Replacement text" : "Content")
        }
        let remaining = arguments.filter { $0.key != "operations" }
        if !remaining.isEmpty { items += F.genericItems(.object(remaining), locale: locale) }
        return items
    }
}
