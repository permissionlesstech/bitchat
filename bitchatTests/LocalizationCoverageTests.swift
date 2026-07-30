import Testing
import Foundation

/// Guards against locale gaps in the string catalogs: every translatable key
/// must have a localization for every supported locale, so no user ever sees
/// an English fallback (see PR #1391 review).
struct LocalizationCoverageTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // bitchatTests
        .deletingLastPathComponent()  // repo root

    private struct Catalog {
        /// key -> set of locales with a localization entry
        let coverage: [String: Set<String>]
        /// key -> locale -> the translated text itself
        let values: [String: [String: String]]
        /// all locales appearing anywhere in the catalog
        var allLocales: Set<String> { coverage.values.reduce(into: []) { $0.formUnion($1) } }
    }

    /// Counts each kind of format specifier, treating `%1$@` as `%@`.
    ///
    /// Positional and plain forms are both in the catalog and mean the same
    /// thing when the argument order matches, so comparing the exact spelling
    /// would report style rather than defects. What matters is that a
    /// translation consumes the same arguments the source does.
    private static func specifierCounts(in value: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        var rest = Substring(value)
        while let percent = rest.firstIndex(of: "%") {
            var index = rest.index(after: percent)
            // Skip a positional prefix such as the "1$" in "%1$@".
            var digits = ""
            while index < rest.endIndex, rest[index].isNumber {
                digits.append(rest[index])
                index = rest.index(after: index)
            }
            if !digits.isEmpty, index < rest.endIndex, rest[index] == "$" {
                index = rest.index(after: index)
            } else {
                index = rest.index(after: percent)
            }
            guard index < rest.endIndex else { break }
            // Length modifiers ("lld", "ld") belong to the specifier.
            var kind = ""
            while index < rest.endIndex, rest[index] == "l" {
                kind.append(rest[index])
                index = rest.index(after: index)
            }
            guard index < rest.endIndex else { break }
            kind.append(rest[index])
            // Only recognised conversions count. Anything else after a percent
            // is a literal -- "50% off" and an escaped "%%" must not read as
            // arguments, or every string containing one reports a false defect.
            if ["@", "d", "s", "f", "u", "ld", "lld"].contains(kind) {
                counts[kind, default: 0] += 1
            }
            rest = rest[rest.index(after: index)...]
        }
        return counts
    }

    private static func loadCatalog(_ relativePath: String) throws -> Catalog {
        let url = repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])

        var coverage: [String: Set<String>] = [:]
        var values: [String: [String: String]] = [:]
        for (key, value) in strings {
            guard let entry = value as? [String: Any] else { continue }
            if entry["shouldTranslate"] as? Bool == false { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            var locales: Set<String> = []
            var texts: [String: String] = [:]
            for (locale, loc) in localizations {
                guard let loc = loc as? [String: Any] else { continue }
                // A localization counts if it has a non-empty stringUnit value
                // or uses variations/substitutions (plural forms).
                if let unit = loc["stringUnit"] as? [String: Any],
                   let unitValue = unit["value"] as? String, !unitValue.isEmpty {
                    locales.insert(locale)
                    texts[locale] = unitValue
                } else if loc["variations"] != nil || loc["substitutions"] != nil {
                    locales.insert(locale)
                }
            }
            coverage[key] = locales
            values[key] = texts
        }
        return Catalog(coverage: coverage, values: values)
    }

    @Test func mainCatalogCoversAllLocalesForEveryKey() throws {
        let catalog = try Self.loadCatalog("bitchat/Localizable.xcstrings")
        let expected = catalog.allLocales
        #expect(expected.count > 1, "catalog should declare more locales than the source language")
        for (key, locales) in catalog.coverage.sorted(by: { $0.key < $1.key }) {
            let missing = expected.subtracting(locales).sorted()
            #expect(missing.isEmpty, "\(key) is missing locales: \(missing.joined(separator: ", "))")
        }
    }

    @Test func shareExtensionCatalogCoversAllLocalesForEveryKey() throws {
        let catalog = try Self.loadCatalog("bitchatShareExtension/Localization/Localizable.xcstrings")
        let expected = catalog.allLocales
        for (key, locales) in catalog.coverage.sorted(by: { $0.key < $1.key }) {
            let missing = expected.subtracting(locales).sorted()
            #expect(missing.isEmpty, "\(key) is missing locales: \(missing.joined(separator: ", "))")
        }
    }

    /// A specifier dropped in translation fails silently and only in that
    /// language: the Tor status lines put the transport name in `%@`, so a
    /// locale that loses it renders "stopped unexpectedly" with nothing saying
    /// which route stopped. The coverage check above cannot see this, because
    /// the localization is present and non-empty either way.
    @Test func everyLocalizationConsumesTheSameArgumentsAsItsSource() throws {
        for catalogPath in [
            "bitchat/Localizable.xcstrings",
            "bitchatShareExtension/Localization/Localizable.xcstrings"
        ] {
            let catalog = try Self.loadCatalog(catalogPath)
            for (key, texts) in catalog.values.sorted(by: { $0.key < $1.key }) {
                guard let source = texts["en"] else { continue }
                let expected = Self.specifierCounts(in: source)
                guard !expected.isEmpty else { continue }
                for (locale, text) in texts.sorted(by: { $0.key < $1.key }) {
                    let actual = Self.specifierCounts(in: text)
                    #expect(
                        actual == expected,
                        "\(catalogPath) \(key) [\(locale)] takes \(actual), source takes \(expected)"
                    )
                }
            }
        }
    }

    @Test func shareExtensionSupportsSameLocalesAsMainApp() throws {
        let main = try Self.loadCatalog("bitchat/Localizable.xcstrings")
        let shareExt = try Self.loadCatalog("bitchatShareExtension/Localization/Localizable.xcstrings")
        let missing = main.allLocales.subtracting(shareExt.allLocales).sorted()
        #expect(missing.isEmpty, "share extension is missing locales: \(missing.joined(separator: ", "))")
    }
}
