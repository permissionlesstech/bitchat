import Testing
import Foundation

/// Locale-completeness guards for the string catalogs.
///
/// Two separate failure modes matter for i18n:
/// 1. **Missing locales** — key exists, but some languages have no string
///    (this file). Users in those locales see English.
/// 2. **Missing keys** — `String(localized:)` call site never got a catalog
///    row (see `catalogContainsEveryStringLocalizedKeyInProductionSources`
///    below, backed by `LocalizationKeyScanner`). Same user-visible fallback,
///    but `mainCatalogCoversAllLocalesForEveryKey` cannot see it.
///
/// Both checks are required; neither implies the other (see PR #1391 review).
struct LocalizationCoverageTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // bitchatTests/
        .deletingLastPathComponent()  // repo root

    /// Parsed view of one `.xcstrings` file.
    private struct Catalog {
        /// key → locales that have a usable localization entry
        let coverage: [String: Set<String>]
        /// Union of every locale that appears on any key
        var allLocales: Set<String> {
            coverage.values.reduce(into: []) { $0.formUnion($1) }
        }
    }

    /// Loads `relativePath` (from the repo root) and builds locale coverage.
    ///
    /// Keys marked `shouldTranslate: false` are skipped — they are intentional
    /// non-UI strings and must not force 30 locale rows.
    private static func loadCatalog(_ relativePath: String) throws -> Catalog {
        let url = repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])

        var coverage: [String: Set<String>] = [:]
        for (key, value) in strings {
            guard let entry = value as? [String: Any] else { continue }
            if entry["shouldTranslate"] as? Bool == false { continue }

            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            var locales: Set<String> = []
            for (locale, loc) in localizations {
                guard let loc = loc as? [String: Any] else { continue }
                // Count a locale when it has a non-empty stringUnit, or when it
                // uses variations/substitutions (plural / device idiom forms).
                if let unit = loc["stringUnit"] as? [String: Any],
                   let unitValue = unit["value"] as? String,
                   !unitValue.isEmpty {
                    locales.insert(locale)
                } else if loc["variations"] != nil || loc["substitutions"] != nil {
                    locales.insert(locale)
                }
            }
            coverage[key] = locales
        }
        return Catalog(coverage: coverage)
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

    @Test func shareExtensionSupportsSameLocalesAsMainApp() throws {
        let main = try Self.loadCatalog("bitchat/Localizable.xcstrings")
        let shareExt = try Self.loadCatalog("bitchatShareExtension/Localization/Localizable.xcstrings")
        let missing = main.allLocales.subtracting(shareExt.allLocales).sorted()
        #expect(missing.isEmpty, "share extension is missing locales: \(missing.joined(separator: ", "))")
    }

    /// Every `String(localized:)` key in app / share-extension sources must
    /// exist in the matching catalog so `defaultValue:` English cannot ship as
    /// a silent production fallback (#1391).
    ///
    /// Share-extension files are checked against the share catalog only;
    /// main-app files against `bitchat/Localizable.xcstrings`. Mixing the two
    /// would hide missing share keys behind the larger main catalog.
    @Test func catalogContainsEveryStringLocalizedKeyInProductionSources() throws {
        let refs = try LocalizationKeyScanner.scanProductionSources(repoRoot: Self.repoRoot)
        #expect(!refs.isEmpty, "expected at least one String(localized:) reference")

        let main = try Self.loadCatalog("bitchat/Localizable.xcstrings")
        let shareExt = try Self.loadCatalog("bitchatShareExtension/Localization/Localizable.xcstrings")

        var missingMain: [String] = []
        var missingShare: [String] = []
        for ref in refs {
            if ref.file.hasPrefix("bitchatShareExtension/") {
                if !shareExt.coverage.keys.contains(ref.key) {
                    missingShare.append("\(ref.key) (\(ref.file):\(ref.line))")
                }
            } else if !main.coverage.keys.contains(ref.key) {
                missingMain.append("\(ref.key) (\(ref.file):\(ref.line))")
            }
        }
        #expect(
            missingMain.isEmpty,
            "main catalog missing String(localized:) keys: \(missingMain.joined(separator: ", "))"
        )
        #expect(
            missingShare.isEmpty,
            "share extension catalog missing String(localized:) keys: \(missingShare.joined(separator: ", "))"
        )
    }
}
