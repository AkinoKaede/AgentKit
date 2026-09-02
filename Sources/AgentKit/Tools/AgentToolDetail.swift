import Foundation

/// UI-neutral content chosen by a tool and rendered by the transcript.
/// It deliberately contains no SwiftUI types or executable persisted state.
public nonisolated struct AgentToolDetail: Equatable, Sendable {
    public init(
        items: [Item]
    ) {
        self.items = items
    }

    public var items: [Item]

    public nonisolated enum Item: Equatable, Sendable {
        case field(Field)
        case message(String, Tint)
        case text(TextBlock)
        case list(ListBlock)
        case groupedList(GroupedList)
    }

    public nonisolated struct Field: Equatable, Sendable {
        public init(
            label: String,
            value: String,
            isMonospaced: Bool = false,
            url: String? = nil
        ) {
            self.label = label
            self.value = value
            self.isMonospaced = isMonospaced
            self.url = url
        }

        public var label: String
        public var value: String
        public var isMonospaced = false
        public var url: String? = nil
    }

    public nonisolated enum Tint: Equatable, Sendable {
        case secondary, warning, success, failure
    }

    public nonisolated enum TextStyle: Equatable, Sendable {
        case plain, monospaced
    }

    public nonisolated struct TextBlock: Equatable, Sendable {
        public init(
            title: String? = nil,
            text: String,
            style: TextStyle
        ) {
            self.title = title
            self.text = text
            self.style = style
        }

        public var title: String?
        public var text: String
        public var style: TextStyle
    }

    public nonisolated struct ListRow: Equatable, Sendable {
        public init(
            title: String,
            subtitle: String? = nil,
            detail: String? = nil,
            badges: [String] = [],
            symbol: String? = nil,
            tint: Tint = .secondary,
            url: String? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.detail = detail
            self.badges = badges
            self.symbol = symbol
            self.tint = tint
            self.url = url
        }

        public var title: String
        public var subtitle: String? = nil
        public var detail: String? = nil
        public var badges: [String] = []
        public var symbol: String? = nil
        public var tint: Tint = .secondary
        public var url: String? = nil
    }

    public nonisolated struct ListBlock: Equatable, Sendable {
        public init(
            title: String? = nil,
            rows: [ListRow],
            emptyMessage: String? = nil
        ) {
            self.title = title
            self.rows = rows
            self.emptyMessage = emptyMessage
        }

        public var title: String?
        public var rows: [ListRow]
        public var emptyMessage: String? = nil
    }

    public nonisolated struct ListSection: Equatable, Sendable {
        public init(
            title: String,
            rows: [ListRow]
        ) {
            self.title = title
            self.rows = rows
        }

        public var title: String
        public var rows: [ListRow]
    }

    public nonisolated struct GroupedList: Equatable, Sendable {
        public init(
            summary: String,
            sections: [ListSection],
            isScrollable: Bool
        ) {
            self.summary = summary
            self.sections = sections
            self.isScrollable = isScrollable
        }

        public var summary: String
        public var sections: [ListSection]
        public var isScrollable: Bool
    }
}

/// The complete, immutable input to a detail projection.
public nonisolated struct AgentToolDetailInput: Sendable {
    public init(
        result: AgentJSONValue,
        arguments: [String: AgentJSONValue],
        locale: Locale
    ) {
        self.result = result
        self.arguments = arguments
        self.locale = locale
    }

    public var result: AgentJSONValue
    public var arguments: [String: AgentJSONValue]
    public var locale: Locale
}

/// A local function selected by a stable ID stored in descriptor metadata.
/// Only the built-in catalog constructs these; remote tools cannot register code.
public nonisolated struct AgentToolDetailPresenter: Sendable {
    public let id: String
    private let projection: @Sendable (AgentToolDetailInput) -> [AgentToolDetail.Item]

    public init(
        id: String,
        present: @escaping @Sendable (AgentToolDetailInput) -> [AgentToolDetail.Item]
    ) {
        // Namespaced, not `builtin.`-prefixed. The ID is persisted with the card
        // and looked up years later against a registry the host composed from
        // several catalogs, so what it has to be is unlikely to collide — an app
        // registering `fetch` of its own must not silently answer for ours.
        precondition(
            id.split(separator: ".", omittingEmptySubsequences: false).count >= 2
                && !id.split(separator: ".", omittingEmptySubsequences: false)
                    .contains(where: \.isEmpty),
            "Detail presenter IDs must be namespaced, as in \"builtin.fetch\""
        )
        self.id = id
        projection = present
    }

    public func present(_ input: AgentToolDetailInput) -> [AgentToolDetail.Item] {
        projection(input)
    }
}

/// Shared vocabulary for tool-owned projections. It owns generic formatting,
/// not knowledge of any particular result schema.
public nonisolated enum AgentToolDetailFormatting {
    public typealias Item = AgentToolDetail.Item
    public typealias Field = AgentToolDetail.Field

    public static func genericItems(
        _ value: AgentJSONValue, locale: Locale
    ) -> [AgentToolDetail.Item] {
        var fields: [Field] = []
        flatten(value, path: [], locale: locale, into: &fields)
        if fields.isEmpty {
            return [.message(localized("Completed without output", locale: locale), .secondary)]
        }
        return fields.map(Item.field)
    }

    public static func objectItems(
        _ input: AgentToolDetailInput,
        build: ([String: AgentJSONValue]) -> [Item]
    ) -> [Item] {
        guard let object = input.result.objectValue else {
            return genericItems(input.result, locale: input.locale)
        }
        return build(object)
    }

    public static func arrayItems(
        _ input: AgentToolDetailInput,
        build: ([AgentJSONValue]) -> [Item]
    ) -> [Item] {
        guard let values = input.result.arrayValue else {
            return genericItems(input.result, locale: input.locale)
        }
        return build(values)
    }

    private static func flatten(
        _ value: AgentJSONValue, path: [String], locale: Locale, into fields: inout [Field]
    ) {
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                flatten(
                    object[key] ?? .null, path: path + [humanized(key)], locale: locale,
                    into: &fields
                )
            }
        case .array(let array):
            if array.isEmpty {
                fields.append(
                    Field(
                        label: label(path, locale: locale), value: localized("None", locale: locale)
                    ))
            } else {
                for (index, entry) in array.enumerated() {
                    flatten(
                        entry, path: path + [String(index + 1)], locale: locale, into: &fields
                    )
                }
            }
        case .string(let string):
            fields.append(Field(label: label(path, locale: locale), value: string))
        case .number(let number):
            let rendered = number.rounded() == number ? String(Int(number)) : String(number)
            fields.append(Field(label: label(path, locale: locale), value: rendered))
        case .bool(let bool):
            fields.append(
                Field(
                    label: label(path, locale: locale),
                    value: localized(bool ? "Yes" : "No", locale: locale)
                ))
        case .null:
            break
        }
    }

    public static func field(
        _ label: String.LocalizationValue, _ value: String, locale: Locale,
        monospaced: Bool = false, url: String? = nil
    ) -> Item {
        .field(
            Field(
                label: AgentLocalization.string(label, locale: locale), value: value,
                isMonospaced: monospaced, url: url
            ))
    }

    public static func appendField(
        _ items: inout [Item], _ label: String.LocalizationValue, _ value: String?,
        locale: Locale, monospaced: Bool = false
    ) {
        guard let value = nonempty(value) else { return }
        items.append(field(label, value, locale: locale, monospaced: monospaced))
    }

    public static func appendBytes(
        _ items: inout [Item], _ label: String.LocalizationValue, _ value: AgentJSONValue?,
        locale: Locale
    ) {
        guard let bytes = value?.integerValue else { return }
        items.append(field(label, byteCount(bytes), locale: locale))
    }

    public static func text(
        _ title: String.LocalizationValue, _ value: String, locale: Locale
    ) -> Item {
        .text(
            .init(
                title: AgentLocalization.string(title, locale: locale), text: value, style: .monospaced
            ))
    }

    public static func localized(_ key: String.LocalizationValue, locale: Locale) -> String {
        AgentLocalization.string(key, locale: locale)
    }

    public static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    public static func byteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    public static func displayDate(_ raw: String) -> String {
        guard let date = try? Date.ISO8601FormatStyle().parse(raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    public static func statusLabel(_ status: String, locale: Locale) -> String {
        switch status {
        case "connecting": localized("Connecting", locale: locale)
        case "running": localized("Running", locale: locale)
        case "exited": localized("Exited", locale: locale)
        default: humanized(status).capitalized
        }
    }

    public static func kindLabel(_ kind: String, locale: Locale) -> String {
        switch kind {
        case "file": localized("File", locale: locale)
        case "directory": localized("Directory", locale: locale)
        case "symlink", "symbolic_link": localized("Symlink", locale: locale)
        default: humanized(kind).capitalized
        }
    }

    public static func humanized(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
    }

    private static func label(_ path: [String], locale: Locale) -> String {
        let rendered = path.joined(separator: " · ")
        return rendered.isEmpty ? localized("Result", locale: locale) : rendered.capitalized
    }
}
