import Foundation
import SwiftUI

enum Localization {
    private static var bundleCache: [String: Bundle] = [:]

    static func bundle(for locale: String) -> Bundle {
        if let cached = bundleCache[locale] { return cached }
        // Try exact match (e.g., "pt-BR", "ja_JP")
        if let path = Bundle.main.path(forResource: locale, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            bundleCache[locale] = bundle
            return bundle
        }
        // Fallback to language-only (e.g., "ja", "pt") if a region was provided
        let separators: [Character] = ["-", "_"]
        if let sep = locale.first(where: { separators.contains($0) }) {
            let lang = String(locale.split(separator: sep).first ?? Substring(locale))
            if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                bundleCache[locale] = bundle
                return bundle
            }
        }
        // Fallback to Base
        if let basePath = Bundle.main.path(forResource: "Base", ofType: "lproj"),
           let baseBundle = Bundle(path: basePath) {
            bundleCache["Base"] = baseBundle
            return baseBundle
        }
        bundleCache["main"] = .main
        return .main
    }

    /// Convenience to get a SwiftUI LocalizedStringKey
    static func key(_ k: String) -> LocalizedStringKey { LocalizedStringKey(k) }

    /// Resolve a string from the catalog, optionally for a specific locale
    static func string(_ key: String, table: String? = nil, locale: String? = nil) -> String {
        if let loc = locale {
            // Load from the requested lproj bundle when provided
            let b = bundle(for: loc)
            return b.localizedString(forKey: key, value: "", table: table)
        }
        return Bundle.main.localizedString(forKey: key, value: "", table: table)
    }

    /// Pluralization helper using CLDR-style categories via key suffixes.
    /// Supported categories: one, few, many, other. Falls back to one/other.
    /// You can pass a BCP-47 language tag (e.g., "ru", "es"); default uses current locale.
    static func plural(_ baseKey: String, count: Int, locale: String? = nil, _ args: CVarArg...) -> String {
        // Prefer single-key plural in catalog/stringsdict if available
        let localeCode = locale
        let fmtCandidate = string(baseKey, table: nil, locale: localeCode)
        if !fmtCandidate.isEmpty && fmtCandidate != baseKey && fmtCandidate.contains("%") {
            return String.localizedStringWithFormat(fmtCandidate, count)
        }

        let lang: String = {
            if let loc = locale { return loc.lowercased() }
            if let preferred = Locale.preferredLanguages.first { return String(preferred.prefix(2)).lowercased() }
            return "en"
        }()
        let category: String
        switch lang {
        case "ru":
            let n = count
            let mod10 = n % 10
            let mod100 = n % 100
            if mod10 == 1 && mod100 != 11 {
                category = "one"
            } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
                category = "few"
            } else if mod10 == 0 || (5...9).contains(mod10) || (11...14).contains(mod100) {
                category = "many"
            } else {
                category = "other"
            }
        default:
            category = (count == 1) ? "one" : "other"
        }
        let key = "\(baseKey).\(category)"
        let fmt = string(key, table: nil, locale: locale)
        if args.isEmpty { return String(format: fmt, count) }
        return String(format: fmt, arguments: args)
    }

    static func localized(_ key: String, locale: String, table: String? = nil) -> String {
        // Resolve from the requested locale bundle first (covers InfoPlist and Localizable)
        let langBundle = bundle(for: locale)
        let res = langBundle.localizedString(forKey: key, value: "", table: table)
        if !res.isEmpty { return res }
        // Explicit fallback to Base lproj for legacy tables
        if let basePath = Bundle.main.path(forResource: "Base", ofType: "lproj"),
           let baseBundle = Bundle(path: basePath) {
            let baseRes = baseBundle.localizedString(forKey: key, value: "", table: table)
            if !baseRes.isEmpty { return baseRes }
        }
        return key
    }
}
