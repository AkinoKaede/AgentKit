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
    private let traditionalChinese = Locale(identifier: "zh-Hant")

    @Test
    func toolCardVocabularyResolvesFromThePackageBundle() {
        let localized = AgentLocalization.string("Scratch path", locale: chinese)
        #expect(localized != "Scratch path")
        let hasHan = localized.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        #expect(hasHan)
    }

    @Test
    func traditionalChineseResolvesFromItsOwnPackageBundle() {
        #expect(AgentLocalization.string("Scratch path", locale: traditionalChinese) == "草稿路徑")
        #expect(AgentLocalization.string("Scratch path", locale: chinese) == "草稿路径")
    }

    @Test
    func modelRoleDetailsFollowThePackageLanguage() {
        let usesChinese = AIRole.chat.displayName == "对话"
        let descriptions: [(AIRole, String, String)] = [
            (
                .chat,
                "Used for chat, tools, and the Assistant sidebar.",
                "用于对话、工具和助手侧边栏。"
            ),
            (
                .commandGenerator,
                "Turns the current terminal input into one command. Choose a fast model.",
                "将当前终端输入整理为一条命令。请选择速度较快的模型。"
            ),
            (
                .guardian,
                "Reviews commands before automatic approval. Automatic selects the best available review model.",
                "在自动批准前审查命令。自动模式会选择最佳的可用审查模型。"
            ),
        ]
        for (role, english, chinese) in descriptions {
            #expect(role.detail == (usesChinese ? chinese : english))
        }
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
