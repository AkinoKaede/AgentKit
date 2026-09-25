import Foundation

nonisolated extension SessionSearchTool {
    public static func presentArguments(_ input: AgentToolArgumentDetailInput) -> [AgentToolDetail.Item] {
        AgentKnowledgeToolDetail.fields(input.arguments, locale: input.locale)
    }

    public static func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        let queryItems: [AgentToolDetail.Item]
        if let query = F.nonempty(input.arguments["query"]?.stringValue) {
            queryItems = AgentKnowledgeToolDetail.fields(["query": .string(query)], locale: input.locale)
        } else {
            queryItems = []
        }
        guard let object = input.result.objectValue else {
            return queryItems + F.genericItems(input.result, locale: input.locale)
        }
        let locale = input.locale
        var items: [AgentToolDetail.Item] = []
        if let sessions = object["sessions"]?.arrayValue {
            items.append(
                .list(
                    .init(
                        title: F.localized("Recent conversations", locale: locale),
                        rows: sessions.map {
                            .init(
                                title: F.nonempty($0.objectValue?["title"]?.stringValue)
                                    ?? F.localized("Untitled conversation", locale: locale), symbol: "bubble.left")
                        }, emptyMessage: F.localized("No conversations found", locale: locale))))
        } else if let messages = object["messages"]?.arrayValue {
            if messages.isEmpty { items.append(.message(F.localized("No messages found", locale: locale), .secondary)) }
            for value in messages {
                guard let message = value.objectValue, let content = message["content"]?.stringValue else {
                    // Preserve unknown data without exposing the protocol's private identifiers.
                    let visible = value.objectValue?.filter { !["conversation_id", "message_id"].contains($0.key) }
                    items += F.genericItems(visible.map(AgentJSONValue.object) ?? value, locale: locale)
                    continue
                }
                let title =
                    F.nonempty(message["title"]?.stringValue) ?? F.localized("Untitled conversation", locale: locale)
                let role: String.LocalizationValue
                switch message["role"]?.stringValue {
                case "user": role = "User"
                case "assistant": role = "Assistant"
                case "tool": role = "Tool"
                case "system": role = "System"
                default: role = "Message"
                }
                items.append(
                    .text(
                        .init(
                            title: "\(title) — \(F.localized(role, locale: locale))", text: content, style: .plain)))
            }
        } else {
            return queryItems + F.genericItems(input.result, locale: locale)
        }
        items += AgentKnowledgeToolDetail.more(object, locale: locale)
        return queryItems + items
    }
}
