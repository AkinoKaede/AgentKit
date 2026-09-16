import Foundation
import Testing

@testable import AgentKit

/// Check resource delivery and locale selection, not the wording of translations.
@Suite
struct AgentLocalizationTests {
    @Test(arguments: ["zh-Hans", "zh-Hant"])
    func requestedLocaleResolvesItsPackagedTranslation(_ language: String) throws {
        let localization = try #require(
            Bundle.module.localizations.first { $0.caseInsensitiveCompare(language) == .orderedSame }
        )
        let path = try #require(Bundle.module.path(forResource: localization, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let expected = bundle.localizedString(forKey: "Scratch path", value: nil, table: nil)
        #expect(expected != "Scratch path")
        #expect(AgentLocalization.string("Scratch path", locale: Locale(identifier: language)) == expected)
    }

    @Test
    func everyCatalogEntryHasFinishedChineseTranslations() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Localizations/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let strings = try #require(
            (catalog as? [String: Any])?["strings"] as? [String: [String: Any]]
        )
        #expect(!strings.isEmpty)

        for language in ["zh-Hans", "zh-Hant"] {
            var untranslated: [String] = []
            for (key, entry) in strings {
                guard
                    let localizations = entry["localizations"] as? [String: Any],
                    let chinese = localizations[language] as? [String: Any]
                else {
                    untranslated.append(key)
                    continue
                }
                // A plural key carries `variations` instead of one `stringUnit`.
                if Self.isTranslated(chinese["stringUnit"]) { continue }
                if chinese["variations"] != nil { continue }
                untranslated.append(key)
            }
            #expect(untranslated.isEmpty, "Untranslated \(language): \(untranslated.sorted().prefix(5))")
        }
    }

    private static func isTranslated(_ unit: Any?) -> Bool {
        guard let unit = unit as? [String: Any] else { return false }
        return unit["state"] as? String == "translated"
            && (unit["value"] as? String)?.isEmpty == false
    }
}
