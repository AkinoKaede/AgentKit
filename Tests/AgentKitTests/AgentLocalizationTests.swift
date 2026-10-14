import Foundation
import Testing

@testable import AgentKit

/// Check resource delivery and locale selection, not the wording of translations.
@Suite
struct AgentLocalizationTests {
    @Test(arguments: ["ja", "zh-Hans", "zh-Hant", "de", "fr", "ko"])
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
    func everyCatalogEntryHasFinishedTranslations() throws {
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

        for language in ["ja", "zh-Hans", "zh-Hant", "de", "fr", "ko"] {
            var untranslated: [String] = []
            for (key, entry) in strings {
                guard
                    let localizations = entry["localizations"] as? [String: Any],
                    let localization = localizations[language] as? [String: Any]
                else {
                    untranslated.append(key)
                    continue
                }
                // A plural key carries `variations` instead of one `stringUnit`.
                if Self.isTranslated(localization["stringUnit"]) { continue }
                if let variations = localization["variations"] as? [String: Any],
                    let plural = variations["plural"] as? [String: [String: Any]],
                    !plural.isEmpty,
                    plural.values.allSatisfy({ Self.isTranslated($0["stringUnit"]) })
                {
                    continue
                }
                untranslated.append(key)
            }
            #expect(untranslated.isEmpty, "Untranslated \(language): \(untranslated.sorted().prefix(5))")
        }
    }

    @Test(arguments: ["ja", "ja-JP", "ja_JP"])
    func japaneseRegionalLocalesResolvePackagedCountsAndErrors(_ identifier: String) {
        let locale = Locale(identifier: identifier)
        #expect(AgentLocalization.string("Scratch path", locale: locale) == "一時保存パス")
        #expect(AgentLocalization.string("\(3) results", locale: locale) == "3件の結果")
        let status = 403
        let message = "Forbidden"
        #expect(
            AgentLocalization.string("The model endpoint returned \(status): \(message)", locale: locale)
                == "モデルのエンドポイントが403を返しました：Forbidden")
    }

    @Test(arguments: ["de-DE", "de-AT", "fr-FR", "fr-CA", "ko-KR", "ko_KR"])
    func regionalLocalesResolveCountsAndErrors(_ identifier: String) {
        let locale = Locale(identifier: identifier)
        let language = String(identifier.prefix(2))
        let paths = ["de": "Temporärer Pfad", "fr": "Chemin temporaire", "ko": "임시 저장 경로"]
        let counts = [
            "de": ["0 Ergebnisse", "1 Ergebnis", "2 Ergebnisse"],
            "fr": ["0 résultat", "1 résultat", "2 résultats"],
            "ko": ["결과 0개", "결과 1개", "결과 2개"],
        ]
        let errors = [
            "de": "Der Modellendpunkt hat 403 zurückgegeben: Forbidden",
            "fr": "Le point de terminaison du modèle a renvoyé 403\u{00A0}: Forbidden",
            "ko": "모델 엔드포인트 응답 403: Forbidden",
        ]
        #expect(AgentLocalization.string("Scratch path", locale: locale) == paths[language])
        for count in 0...2 {
            #expect(AgentLocalization.string("\(count) results", locale: locale) == counts[language]?[count])
        }
        let status = 403
        let message = "Forbidden"
        #expect(
            AgentLocalization.string("The model endpoint returned \(status): \(message)", locale: locale)
                == errors[language])
    }

    @Test(arguments: ["de-DE", "fr-CA", "ko-KR"])
    func toolPresentersUseRequestedLocaleForInterpolatedMessages(_ identifier: String) {
        let locale = Locale(identifier: identifier)
        let plan = PresentPlanTool.present(
            .init(result: .object(["scratch_path": .string("plan.md")]), arguments: [:], locale: locale))
        #expect(
            plan == [.message(AgentLocalization.string("Plan presented from \("plan.md")", locale: locale), .success)])
        let tasks = ManageTasksTool.present(
            .init(
                result: .object(["tasks": .number(3), "completed": .number(1)]),
                arguments: [:], locale: locale))
        #expect(
            tasks == [.message(AgentLocalization.string("\(3) tasks · \(1) completed", locale: locale), .secondary)])
        let results = WebSearchTool.present(
            .init(result: .array([.object(["title": .string("Example")])]), arguments: [:], locale: locale))
        #expect(results.first == .message(AgentLocalization.string("\(1) results", locale: locale), .secondary))
    }

    @Test
    func koreanScratchDetailsReorderArgumentsAndLocalizeQuotaAndLineEndings() {
        let locale = Locale(identifier: "ko-KR")
        let search = ScratchSearchTool.present(
            .init(
                result: .object([
                    "matching_lines": .number(7), "searched_files": .number(2),
                    "returned_matches": .number(3), "truncated": .bool(true),
                    "skipped_binary_files": .number(1),
                ]),
                arguments: [:], locale: locale))
        #expect(search.contains(.message("파일 2개에서 일치하는 줄 7개 찾음", .success)))
        #expect(search.contains(.message("일치하는 줄 7개 중 3개 표시 중", .warning)))
        #expect(search.contains(.message("바이너리 파일 1개 건너뜀", .secondary)))
        let list = ScratchListTool.present(
            .init(
                result: .object(["entry_count": .number(2), "entry_quota": .number(100)]),
                arguments: [:], locale: locale))
        #expect(
            list.contains { item in
                if case .message(let text, _) = item { return text.hasPrefix("항목 2 / 100개 · ") }
                return false
            })
        let diff = ScratchDiffTool.present(
            .init(
                result: .object([
                    "line_ending_a": .string("lf"), "line_ending_b": .string("crlf"),
                ]),
                arguments: [:], locale: locale))
        #expect(diff.contains(.message("텍스트는 같지만 줄바꿈 형식이 다름: LF → CRLF", .warning)))
    }

    private static func isTranslated(_ unit: Any?) -> Bool {
        guard let unit = unit as? [String: Any] else { return false }
        return unit["state"] as? String == "translated"
            && (unit["value"] as? String)?.isEmpty == false
    }
}
