import Foundation
import Testing

@testable import AgentKit

/// The one failure mode a string catalog in a package has: it resolves to the
/// key instead of the translation, silently, because `String(localized:)`
/// defaults to `Bundle.main` and a package's strings are not there.
///
/// Every check below would pass on an empty catalog if it only compared against
/// English, so each asserts the *Chinese* value — which cannot come from the key.
@Suite
struct AgentLocalizationTests {
    private let chinese = Locale(identifier: "zh-Hans")

    @Test
    func toolCardVocabularyResolvesFromThePackageBundle() {
        let localized = AgentLocalization.string("Scratch path", locale: chinese)
        #expect(localized != "Scratch path")
        let hasHan = localized.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        #expect(hasHan)
    }

    @Test
    func runtimeErrorsAreLocalized() {
        let message = AgentRuntimeError.turnBudgetExceeded.localizedDescription
        // `errorDescription` reads `.current`, so this asserts only that the
        // catalog answers at all — an unresolved key would come back verbatim
        // with its interpolation markers intact.
        #expect(!message.isEmpty)
        #expect(!message.contains("%@"))
    }

    @Test
    func everyCatalogEntryHasAFinishedChineseTranslation() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings")
        )
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let strings = try #require(
            (catalog as? [String: Any])?["strings"] as? [String: [String: Any]]
        )
        #expect(!strings.isEmpty)

        var untranslated: [String] = []
        for (key, entry) in strings {
            guard
                let localizations = entry["localizations"] as? [String: Any],
                let chinese = localizations["zh-Hans"] as? [String: Any]
            else {
                untranslated.append(key)
                continue
            }
            // A plural key carries `variations` instead of one `stringUnit`.
            if Self.isTranslated(chinese["stringUnit"]) { continue }
            if chinese["variations"] != nil { continue }
            untranslated.append(key)
        }
        #expect(untranslated.isEmpty, "Untranslated: \(untranslated.sorted().prefix(5))")
    }

    private static func isTranslated(_ unit: Any?) -> Bool {
        guard let unit = unit as? [String: Any] else { return false }
        return unit["state"] as? String == "translated"
            && (unit["value"] as? String)?.isEmpty == false
    }
}
