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
        /// all locales appearing anywhere in the catalog
        var allLocales: Set<String> { coverage.values.reduce(into: []) { $0.formUnion($1) } }
    }

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
                // A localization counts if it has a non-empty stringUnit value
                // or uses variations/substitutions (plural forms).
                if let unit = loc["stringUnit"] as? [String: Any],
                   let unitValue = unit["value"] as? String, !unitValue.isEmpty {
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

    /// The catalog tests above validate the CATALOG; this one validates the
    /// CODE. A `String(localized:)` whose key is absent from every catalog
    /// compiles and runs fine — it just silently ships its English
    /// `defaultValue` to all 29 non-source locales. That blind spot let the
    /// entire notices/board composer (10 keys), two delivery states, and two
    /// media-failure reasons go untranslated while the coverage tests stayed
    /// green. Interpolated keys can't be checked statically and are skipped;
    /// every literal key must resolve.
    @Test func everyCodeReferencedKeyExistsInACatalog() throws {
        let main = try Self.loadCatalog("bitchat/Localizable.xcstrings")
        let shareExt = try Self.loadCatalog("bitchatShareExtension/Localization/Localizable.xcstrings")
        let knownKeys = Set(main.coverage.keys).union(shareExt.coverage.keys)

        let pattern = try NSRegularExpression(pattern: #"String\(\s*localized:\s*"([^"\\]+)""#)
        var missing: [String] = []

        for sourceRoot in ["bitchat", "bitchatShareExtension"] {
            let rootURL = Self.repoRoot.appendingPathComponent(sourceRoot)
            let enumerator = try #require(FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: nil
            ))
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                pattern.enumerateMatches(in: source, range: range) { match, _, _ in
                    guard let match, let keyRange = Range(match.range(at: 1), in: source) else { return }
                    let key = String(source[keyRange])
                    if !knownKeys.contains(key) {
                        missing.append("\(key) (\(fileURL.lastPathComponent))")
                    }
                }
            }
        }

        #expect(
            missing.isEmpty,
            "keys referenced in code but absent from every catalog — these ship English to all non-source locales: \(missing.sorted().joined(separator: ", "))"
        )
    }
}
