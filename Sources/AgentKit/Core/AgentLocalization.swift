import Foundation
import Synchronization

/// Looks a string up in this package's own tables, in a caller-chosen locale.
///
/// Two things make it necessary. A package's strings live in `Bundle.module`
/// rather than the app's bundle, so every lookup here has to name `.module`
/// explicitly or it silently returns the key. And a tool card is rendered
/// *after* the fact, sometimes long after, in whatever language the reader is
/// using now — so the locale is a parameter rather than `.current`, and a
/// persisted card follows the viewer instead of freezing whichever language
/// produced it.
///
/// The bundle hop is what makes the second part work: passing `locale` to
/// `String(localized:)` picks number and date formatting, not which table is
/// read, so the matching `.lproj` has to be resolved first.
public enum AgentLocalization {
    public static func string(
        _ key: String.LocalizationValue, locale: Locale = .current
    ) -> String {
        String(localized: key, bundle: bundle(for: locale), locale: locale)
    }

    /// Resolved through `Bundle.preferredLocalizations`, not by building an
    /// `.lproj` name out of the language code.
    ///
    /// The two build systems that ship this package disagree about the case of
    /// those directory names — SwiftPM lowercases `zh-Hans.lproj`, Xcode keeps
    /// it — and matching a locale to a script- or region-tagged table is exactly
    /// what that API is for. Doing it by hand got `zh-hans` wrong and returned
    /// English to every Chinese reader, silently.
    private static func bundle(for locale: Locale) -> Bundle {
        let identifier = locale.identifier
        if let cached = cache.withLock({ $0[identifier] }) { return cached ?? .module }
        let matched = Bundle.preferredLocalizations(
            from: Bundle.module.localizations, forPreferences: [identifier]
        ).first
        let resolved =
            matched
            .flatMap { Bundle.module.path(forResource: $0, ofType: "lproj") }
            .flatMap(Bundle.init(path:))
        cache.withLock { $0[identifier] = resolved }
        return resolved ?? .module
    }

    /// Every localized string on a tool card goes through here, and a card is
    /// redrawn on every transcript update. Resolving a bundle touches the
    /// filesystem, so the answer is kept.
    private static let cache = Mutex<[String: Bundle?]>([:])
}
