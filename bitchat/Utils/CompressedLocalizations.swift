import Foundation

/// Loads non-plural UI localizations on demand from the raw-deflate compressed
/// `Localizations.zlib` bundle resource (generated from `Localizable.xcstrings`
/// at Xcode build time), keeping only the active locale and English fallback in
/// memory instead of shipping 30 uncompressed `.lproj/Localizable.strings` files.
final class CompressedLocalizations: @unchecked Sendable {
    static let shared = CompressedLocalizations(bundle: .main)

    private struct Payload: Decodable {
        let k: [String]
        let l: [String: [String]]
    }

    private let activeTable: [String: String]?
    private let fallbackTable: [String: String]?

    convenience init(bundle: Bundle) {
        if let url = bundle.url(forResource: "Localizations", withExtension: "zlib"),
           let compressed = try? Data(contentsOf: url) {
            self.init(compressedData: compressed, preferredLanguages: nil)
        } else {
            self.init(activeTable: nil, fallbackTable: nil)
        }
    }

    convenience init(compressedData: Data, preferredLanguages: [String]? = nil) {
        guard let raw = Self.decompress(compressedData),
              let payload = try? JSONDecoder().decode(Payload.self, from: raw)
        else {
            self.init(activeTable: nil, fallbackTable: nil)
            return
        }

        let available = Array(payload.l.keys)
        let selected: String
        if let preferredLanguages {
            selected = Bundle.preferredLocalizations(
                from: available,
                forPreferences: preferredLanguages
            ).first ?? "en"
        } else {
            selected = Bundle.preferredLocalizations(from: available).first ?? "en"
        }

        let active = Self.buildDictionary(keys: payload.k, values: payload.l[selected])
        let fallback = selected == "en"
            ? nil
            : Self.buildDictionary(keys: payload.k, values: payload.l["en"])
        self.init(activeTable: active, fallbackTable: fallback)
    }

    private init(activeTable: [String: String]?, fallbackTable: [String: String]?) {
        self.activeTable = activeTable
        self.fallbackTable = fallbackTable
    }

    func lookup(_ key: String) -> String? {
        if let value = activeTable?[key], !value.isEmpty {
            return value
        }
        if let fallback = fallbackTable?[key], !fallback.isEmpty {
            return fallback
        }
        return nil
    }

    private static func decompress(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .zlib) as Data
    }

    private static func buildDictionary(keys: [String], values: [String]?) -> [String: String]? {
        guard let values, values.count == keys.count else { return nil }
        var dict: [String: String] = [:]
        dict.reserveCapacity(keys.count)
        for index in keys.indices {
            let value = values[index]
            if !value.isEmpty {
                dict[keys[index]] = value
            }
        }
        return dict
    }
}

extension String {
    private static let missingLocalizationSentinel = "\u{0000}__bitchat_missing_l10n__"

    /// Resolves literal localization keys from `CompressedLocalizations` when
    /// running in the Xcode app bundle, falling back to `LocalizablePlurals`
    /// (native CLDR plural/substitution keys) and `Bundle.main`'s default table.
    init(localized key: StaticString, comment _: StaticString? = nil) {
        self = Self.resolveCompressedLocalization(key: key, defaultValue: nil)
    }

    init(
        localized key: StaticString,
        defaultValue: StaticString,
        comment _: StaticString? = nil
    ) {
        self = Self.resolveCompressedLocalization(key: key, defaultValue: defaultValue)
    }

    private static func resolveCompressedLocalization(
        key: StaticString,
        defaultValue: StaticString?
    ) -> String {
        let keyString = String(describing: key)
        if let resolved = CompressedLocalizations.shared.lookup(keyString) {
            return resolved
        }

        let plural = Bundle.main.localizedString(
            forKey: keyString,
            value: Self.missingLocalizationSentinel,
            table: "LocalizablePlurals"
        )
        if plural != Self.missingLocalizationSentinel {
            return plural
        }

        let standard = Bundle.main.localizedString(
            forKey: keyString,
            value: Self.missingLocalizationSentinel,
            table: nil
        )
        if standard != Self.missingLocalizationSentinel {
            return standard
        }

        if let defaultValue {
            return String(describing: defaultValue)
        }
        return keyString
    }
}
