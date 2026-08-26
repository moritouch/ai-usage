import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }

    var locale: Locale {
        var components = Locale.Components(identifier: Locale.autoupdatingCurrent.identifier)
        components.languageComponents.languageCode = Locale.LanguageCode(rawValue)
        return Locale(components: components)
    }

    static var systemDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("ja") ? .japanese : .english
    }
}

enum LanguagePreference {
    static let key = "appLanguage"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SnapshotStore.appGroupID)
    }

    static func load() -> AppLanguage {
        guard let stored = defaults?.string(forKey: key),
              let language = AppLanguage(rawValue: stored)
        else { return .systemDefault }
        return language
    }

    static func save(_ language: AppLanguage) {
        defaults?.set(language.rawValue, forKey: key)
    }
}

enum L10n {
    private final class BundleMarker: NSObject {}
    private static let containingBundle = Bundle(for: BundleMarker.self)

    static func text(_ key: String, language: AppLanguage) -> String {
        bundle(for: language).localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(
        _ key: String,
        language: AppLanguage,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: text(key, language: language),
            locale: language.locale,
            arguments: arguments
        )
    }

    static func agentNote(_ note: String?, language: AppLanguage) -> String? {
        guard let note else { return nil }
        let key: String
        switch note {
        case "Run Codex once to populate its session log":
            key = "note.codex.runOnce"
        case "Run Grok once to populate its billing log":
            key = "note.grok.runOnce"
        case "Showing the last successful API response":
            key = "note.claude.lastResponse"
        case "Claude credentials are unavailable; sign in to Claude Code or allow Keychain access":
            key = "note.claude.credentialsUnavailable"
        case "Claude sign-in expired and could not be refreshed; sign in to Claude Code again, then check again":
            key = "note.claude.signInExpired"
        case "Claude credentials were rejected; sign in to Claude Code again":
            key = "note.claude.credentialsRejected"
        case "Claude usage data expired; sign in to Claude Code again, then check again":
            key = "note.claude.dataExpired"
        case "Codex usage data expired; complete a Codex response, then check again":
            key = "note.codex.dataExpired"
        case "Grok usage data expired; use Grok, then check again":
            key = "note.grok.dataExpired"
        case "Stored usage data expired; use the agent, then check again":
            key = "note.agent.dataExpired"
        case "Claude usage API is rate-limited; try again later":
            key = "note.claude.rateLimited"
        case "Claude usage API could not be reached":
            key = "note.claude.unreachable"
        default:
            return note
        }
        return text(key, language: language)
    }

    static func source(_ source: String, language: AppLanguage) -> String {
        let key: String
        switch source {
        case "billing log": key = "source.billingLog"
        case "session log": key = "source.sessionLog"
        case "usage API": key = "source.usageAPI"
        case "statusLine hook": key = "source.statusLine"
        default: return source
        }
        return text(key, language: language)
    }

    static func windowLabel(_ window: UsageWindow, language: AppLanguage) -> String {
        switch (window.id, window.label) {
        case ("primary", "Usage"):
            return text("window.usage", language: language)
        case ("secondary", "Secondary"):
            return text("window.secondary", language: language)
        case ("grok_period", "Period"):
            return text("window.period", language: language)
        default:
            return window.label
        }
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard let url = containingBundle.url(
            forResource: language.rawValue,
            withExtension: "lproj"
        ), let localized = Bundle(url: url) else {
            return containingBundle
        }
        return localized
    }
}
