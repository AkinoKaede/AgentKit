import importlib.util
import json
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "localization", Path(__file__).resolve().parents[1] / "check-localization.py"
)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def plural(**forms):
    return {"variations": {"plural": {key: unit(value) for key, value in forms.items()}}}


def catalog(key, language, target, source=None):
    localizations = {language: target}
    if source is not None:
        localizations["en"] = source
    return {"sourceLanguage": "en", "strings": {key: {"localizations": localizations}}}


class LocalizationTests(unittest.TestCase):
    def test_all_languages_are_checked_by_default(self):
        failures = CHECK.problems({"sourceLanguage": "en", "strings": {"Title": {}}})
        self.assertEqual(len(failures), 6)
        for language in CHECK.SUPPORTED_LANGUAGES:
            self.assertTrue(any(f"missing {language} translation" in failure for failure in failures))

    def test_missing_and_unfinished_translations(self):
        for target in ({}, unit(""), unit("제목", "needs_review")):
            with self.subTest(target=target):
                self.assertTrue(CHECK.problems(catalog("Title", "ko", target), ("ko",)))

    def test_nontranslatable_entries_are_exempt(self):
        self.assertFalse(CHECK.problems({"sourceLanguage": "en", "strings": {"ID": {"shouldTranslate": False}}}))

    def test_korean_spaces_and_latin_terms_are_preserved(self):
        data = catalog("Read %@ file", "ko", unit("%@ 파일 읽기"))
        self.assertFalse(CHECK.problems(data, ("ko",)))

    def test_chinese_and_japanese_spacing_rules_remain_enforced(self):
        for language, value in (("zh-Hans", "读取 %@"), ("zh-Hant", "讀取 %@"), ("ja", "%@ ファイル")):
            with self.subTest(language=language):
                failures = CHECK.problems(catalog("Read %@", language, unit(value)), (language,))
                self.assertTrue(any("spacing" in failure for failure in failures))

    def test_positional_arguments_can_change_order_but_not_types(self):
        for value, valid in (("%2$@ 결과 %1$lld개", True), ("%1$@ 결과 %2$lld개", False),
                             ("%2$@ 결과", False), ("%2$@ %1$lld %1$lld", False)):
            with self.subTest(value=value):
                failures = CHECK.problems(catalog("%lld results for %@", "ko", unit(value)), ("ko",))
                self.assertEqual(not failures, valid)

    def test_english_plural_requires_localized_categories(self):
        source = plural(one="%lld result", other="%lld results")
        for language in CHECK.SUPPORTED_LANGUAGES:
            target = plural(one="%lld item", other="%lld items") if language in ("de", "fr") else plural(other="%lld")
            with self.subTest(language=language):
                self.assertFalse(CHECK.problems(catalog("%lld results", language, target, source), (language,)))
                self.assertTrue(CHECK.problems(catalog("%lld results", language, unit("%lld"), source), (language,)))

    def test_target_only_plurals_require_one_and_other(self):
        for language in ("de", "fr"):
            with self.subTest(language=language):
                self.assertTrue(CHECK.problems(catalog("%lld entries", language, plural(other="%lld")), (language,)))
                self.assertFalse(CHECK.problems(
                    catalog("%lld entries", language, plural(one="%lld", other="%lld")), (language,)
                ))

    def test_only_french_accepts_optional_many(self):
        target = plural(one="%lld", other="%lld", many="%lld")
        self.assertFalse(CHECK.problems(catalog("%lld items", "fr", target), ("fr",)))
        self.assertTrue(CHECK.problems(catalog("%lld items", "de", target), ("de",)))

    def test_korean_rejects_one_category(self):
        target = plural(one="%lld개", other="%lld개")
        self.assertTrue(CHECK.problems(catalog("%lld items", "ko", target), ("ko",)))

    def test_every_plural_variant_is_validated(self):
        target = plural(one="Ein Eintrag", other="%lld Einträge")
        self.assertTrue(CHECK.problems(catalog("%lld entries", "de", target), ("de",)))

    def test_unsupported_language_is_not_silently_skipped(self):
        with self.assertRaises(ValueError):
            CHECK.problems({"sourceLanguage": "en", "strings": {}}, ("unknown",))

    def test_duplicate_json_keys_are_rejected(self):
        with self.assertRaises(ValueError):
            json.loads('{"ko": {}, "ko": {}}', object_pairs_hook=CHECK.unique_object)


if __name__ == "__main__":
    unittest.main()
