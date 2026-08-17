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
    /// CODE. A `String(localized:)` whose key is absent from the catalog its
    /// target actually ships compiles and runs fine — it just silently ships
    /// its English `defaultValue` to all 29 non-source locales. That blind
    /// spot let the entire notices/board composer (10 keys), two delivery
    /// states, and two media-failure reasons go untranslated while the
    /// coverage tests stayed green. Interpolated keys can't be checked
    /// statically and are skipped; every literal key must resolve.
    ///
    /// The catalogs are checked per target, not as a union: the share
    /// extension bundles only its own catalog, so a key it references that
    /// lives solely in the app catalog is just as untranslated there as one
    /// that exists nowhere.
    @Test func everyCodeReferencedKeyExistsInItsOwnCatalog() throws {
        let main = try Self.loadCatalog(Self.mainCatalogPath)
        let shareExt = try Self.loadCatalog(Self.shareExtensionCatalogPath)
        let mainKeys = Set(main.coverage.keys)
        let shareKeys = Set(shareExt.coverage.keys)

        for (sourceRoot, ownKeys, otherKeys, ownCatalog, otherCatalog) in [
            ("bitchat", mainKeys, shareKeys, Self.mainCatalogPath, Self.shareExtensionCatalogPath),
            ("bitchatShareExtension", shareKeys, mainKeys,
             Self.shareExtensionCatalogPath, Self.mainCatalogPath)
        ] {
            let missing = try Self.localizedKeyReferences(in: sourceRoot)
                .filter { !ownKeys.contains($0.key) }
                .map { reference -> String in
                    let note = otherKeys.contains(reference.key)
                        ? " (present in \(otherCatalog), which this target does not bundle)"
                        : " (present in no catalog)"
                    return "\(reference.location) \(reference.key)\(note)"
                }

            #expect(
                missing.isEmpty,
                """
                keys referenced under \(sourceRoot)/ but absent from \(ownCatalog) — \
                these ship English to all non-source locales:
                \(missing.sorted().joined(separator: "\n"))
                """
            )
        }
    }

    private static let mainCatalogPath = "bitchat/Localizable.xcstrings"
    private static let shareExtensionCatalogPath =
        "bitchatShareExtension/Localization/Localizable.xcstrings"

    /// A literal `String(localized:)` key, with where it was written.
    private struct KeyReference {
        let key: String
        /// `path/to/File.swift:line`, relative to the repository root.
        let location: String
    }

    /// Every literal `String(localized:)` key under `sourceRoot`, with its
    /// repo-relative file and line so a failure points at the call site
    /// instead of just naming a file.
    private static func localizedKeyReferences(in sourceRoot: String) throws -> [KeyReference] {
        let pattern = try NSRegularExpression(pattern: #"String\(\s*localized:\s*"([^"\\]+)""#)
        let rootURL = repoRoot.appendingPathComponent(sourceRoot)
        let enumerator = try #require(FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil
        ))

        var references: [KeyReference] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let relativePath = fileURL.path.replacingOccurrences(
                of: repoRoot.path + "/", with: ""
            )
            let range = NSRange(source.startIndex..., in: source)
            pattern.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let match,
                      let keyRange = Range(match.range(at: 1), in: source),
                      let matchStart = Range(match.range, in: source)?.lowerBound
                else { return }
                let line = source[source.startIndex..<matchStart].count(where: { $0 == "\n" }) + 1
                references.append(KeyReference(
                    key: String(source[keyRange]),
                    location: "\(relativePath):\(line)"
                ))
            }
        }
        return references
    }
}
