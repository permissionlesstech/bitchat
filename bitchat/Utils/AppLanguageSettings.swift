import Foundation

/// In-app override for the UI language, on top of the system per-app
/// language. Apple resolves localization from the AppleLanguages default at
/// process start, so a new choice takes effect on the next launch — callers
/// surface a "restart to apply" note after changing it.
enum AppLanguageSettings {
    /// "" means no override: follow the device (or per-app system) language.
    static let overrideKey = "app.languageOverride"
    private static let appleLanguagesKey = "AppleLanguages"

    /// Language codes the app ships translations for, straight from the
    /// built bundle so this never drifts from the string catalog.
    static var availableLanguages: [String] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted { endonym(for: $0).localizedCaseInsensitiveCompare(endonym(for: $1)) == .orderedAscending }
    }

    /// The language's name in that language ("فارسی", "한국어") so every user
    /// can find their own entry regardless of the current UI language.
    static func endonym(for code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.lowercased(with: locale)
    }

    static var currentOverride: String? {
        let value = UserDefaults.standard.string(forKey: overrideKey) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Persists the override (nil clears it). AppleLanguages drives the
    /// actual localization lookup on next launch.
    static func setOverride(_ code: String?) {
        let defaults = UserDefaults.standard
        if let code, !code.isEmpty {
            defaults.set(code, forKey: overrideKey)
            defaults.set([code], forKey: appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: overrideKey)
            defaults.removeObject(forKey: appleLanguagesKey)
        }
    }
}
