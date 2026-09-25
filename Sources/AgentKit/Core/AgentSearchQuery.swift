import Foundation
import NaturalLanguage

/// Lexical search terms shared by in-memory knowledge lookup and host-owned full-text stores.
/// Quoted phrases and structured tokens (such as paths and identifiers) stay intact.
public nonisolated struct AgentSearchQuery: Sendable {
    public let literalQuery: String
    public let terms: [String]

    public init(_ raw: String) {
        literalQuery = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Self.parse(literalQuery)
        let meaningful = parsed.filter { $0.quoted || !Self.questionWords.contains($0.text) }
        var seen: Set<String> = []
        terms = (meaningful.isEmpty ? parsed : meaningful).compactMap { term in
            seen.insert(term.text).inserted ? term.text : nil
        }
    }

    /// SQLite FTS5 trigram indexes cannot match terms shorter than three Unicode scalars.
    public var shortTerms: [String] { terms.filter { $0.unicodeScalars.count < 3 } }

    /// Returns a quoted, injection-safe trigram query, or nil when literal matching is required.
    public func fts5Query(matchingAll: Bool) -> String? {
        guard !terms.isEmpty, shortTerms.isEmpty else { return nil }
        return terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: matchingAll ? " " : " OR ")
    }

    private struct Term {
        let text: String
        let quoted: Bool
    }

    private static let questionWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "do", "does", "did", "i", "me", "my", "we", "our",
        "you", "your", "what", "which", "when", "where", "why", "how", "to", "for", "of", "in", "on", "at",
        "with", "about", "please", "and", "or", "请", "的", "我", "你", "我们", "是", "吗", "呢", "怎么",
        "如何", "怎样", "怎么办", "多少", "什么", "一下",
    ]

    private static func parse(_ raw: String) -> [Term] {
        var result: [Term] = []
        var fragment = ""
        var quoted = false
        for character in raw {
            if character == "\"" {
                if quoted {
                    let phrase = normalize(fragment.trimmingCharacters(in: .whitespacesAndNewlines))
                    if !phrase.isEmpty { result.append(.init(text: phrase, quoted: true)) }
                } else {
                    result += words(in: fragment)
                }
                fragment = ""
                quoted.toggle()
            } else {
                fragment.append(character)
            }
        }
        result += words(in: fragment)
        return result
    }

    private static func words(in text: String) -> [Term] {
        var result: [Term] = []
        for piece in text.split(whereSeparator: \.isWhitespace) {
            let raw = String(piece)
            if structured(raw) {
                var token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`?!,;()[]{}。，！？；："))
                while token.last == "." || token.last == ":" { token.removeLast() }
                token = normalize(token)
                if !token.isEmpty { result.append(.init(text: token, quoted: false)) }
                continue
            }
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = raw
            for range in tokenizer.tokens(for: raw.startIndex..<raw.endIndex) {
                let token = normalize(String(raw[range]))
                if !token.isEmpty { result.append(.init(text: token, quoted: false)) }
            }
        }
        return result
    }

    private static func structured(_ token: String) -> Bool {
        if token.hasPrefix("/"), token.count > 1 { return true }
        if token.hasPrefix("-"), token.count > 1 { return true }
        if token.hasPrefix("."), token.count > 1 { return true }
        if token.hasPrefix("~/"), token.count > 2 { return true }
        let interior = token.dropFirst().dropLast()
        return interior.contains { "-_/\\.:".contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
