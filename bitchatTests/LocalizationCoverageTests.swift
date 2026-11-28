import Testing
import Foundation
@testable import bitchat

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

    /// The catalog's `strings` table: key -> entry.
    private static func loadStrings(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: Any])
    }

    private static func loadCatalog(_ relativePath: String) throws -> Catalog {
        let strings = try loadStrings(relativePath)

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

    /// SwiftPM's default build system on Swift 6.4+ (swiftbuild) generates a
    /// Swift symbol for every manually managed catalog key, and fails the
    /// whole build on a key it cannot name ("%@", "#%@", "%lld/%lld"). CI may
    /// still run the native build system, which never generates symbols, so
    /// check the rule here rather than wait for the runner image to move.
    /// This covers nameability only: the tool also fails on two manual keys
    /// that generate the same symbol ("1" and "_1") and on skipped positional
    /// arguments ("%1$@ %3$@"), which this does not check.
    @Test func everyManualKeyCanDeriveAGeneratedSymbol() throws {
        for path in [Self.mainCatalogPath, Self.shareExtensionCatalogPath] {
            let unnameable = try Self.loadStrings(path).compactMap { key, value -> String? in
                guard (value as? [String: Any])?["extractionState"] as? String == "manual" else { return nil }
                return Self.canDeriveSymbol(from: key) ? nil : key
            }.sorted()
            #expect(
                unnameable.isEmpty,
                """
                manual keys in \(path) that string catalog symbol generation \
                cannot name, which breaks `swift build`: \(unnameable). Use \
                Text(verbatim:) at the call site, or give the key a name.
                """
            )
        }
    }

    /// Mirrors `xcstringstool generate-symbols`: printf-style format specifiers
    /// split the key into words, and a character (grapheme cluster) can only
    /// be part of the symbol name if every scalar in it can be part of a Swift
    /// identifier. This approximates that, erring towards rejection, with
    /// letters, numbers, marks, `_`, `$`, the joiners ZWJ and ZWNJ, and emoji
    /// outside the Basic Multilingual Plane. So 🔒, 👋🏽 and 🧑‍🎄 count, but BMP
    /// emoji (✅ ⚡ ❤️) and sequences built on one (🏃‍♂️ ✌🏽) do not.
    private static func canDeriveSymbol(from key: String) -> Bool {
        let words = key.replacingOccurrences(
            of: #"%(\d+\$)?[-+0]*\d*(\.\d+)?(hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA]|%%"#,
            with: " ",
            options: .regularExpression
        )
        return words.contains { character in
            character.unicodeScalars.allSatisfy { scalar in
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .decimalNumber, .letterNumber, .otherNumber,
                     .nonspacingMark, .spacingMark, .enclosingMark:
                    return true
                default:
                    return scalar == "_" || scalar == "$" || scalar == "\u{200C}" || scalar == "\u{200D}"
                        || (scalar.value >= 0x10000 && scalar.properties.isEmoji)
                }
            }
        }
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

        // Files under `bitchat/` that the share extension also compiles have to
        // resolve in both catalogs, since each target bundles only its own.
        let sharedSources = try Self.shareExtensionMembershipExceptions()

        for (sourceRoot, ownKeys, otherKeys, ownCatalog, otherCatalog) in [
            ("bitchat", mainKeys, shareKeys, Self.mainCatalogPath, Self.shareExtensionCatalogPath),
            ("bitchatShareExtension", shareKeys, mainKeys,
             Self.shareExtensionCatalogPath, Self.mainCatalogPath)
        ] {
            let references = try Self.localizedKeyReferences(in: sourceRoot)

            let missing = references
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

            guard sourceRoot == "bitchat" else { continue }
            let missingInBoth = references
                .filter { sharedSources.contains($0.location.prefix(while: { $0 != ":" }).description) }
                .filter { !shareKeys.contains($0.key) }
                .map { "\($0.location) \($0.key)" }

            #expect(
                missingInBoth.isEmpty,
                """
                keys referenced from files the share extension also compiles, but absent \
                from \(Self.shareExtensionCatalogPath) — these ship English inside the \
                extension:
                \(missingInBoth.sorted().joined(separator: "\n"))
                """
            )
        }
    }

    /// The files under `bitchat/` that the share-extension target compiles, read
    /// from the project's membership exceptions so this cannot drift when the
    /// set changes.
    private static func shareExtensionMembershipExceptions() throws -> Set<String> {
        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("bitchat.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let marker = #"Exceptions for "bitchat" folder in "bitchatShareExtension" target"#
        guard let markerRange = project.range(of: marker),
              let listStart = project.range(
                of: "membershipExceptions = (", range: markerRange.upperBound..<project.endIndex
              ),
              let listEnd = project.range(
                of: ");", range: listStart.upperBound..<project.endIndex
              )
        else { return [] }

        return Set(
            project[listStart.upperBound..<listEnd.lowerBound]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasSuffix(".swift") }
                .map { "bitchat/\($0)" }
        )
    }

    private static let mainCatalogPath = "bitchat/Localizable.xcstrings"
    private static let pluralsCatalogPath = "bitchat/Resources/LocalizablePlurals.xcstrings"
    private static let shareExtensionCatalogPath =
        "bitchatShareExtension/Localization/Localizable.xcstrings"

    /// Ensures `LocalizablePlurals.xcstrings` stays strictly in sync with all
    /// plural/substitution entries in `bitchat/Localizable.xcstrings`.
    /// Regenerate with:
    /// `python3 scripts/compress_localizations.py --input bitchat/Localizable.xcstrings --plurals-out bitchat/Resources/LocalizablePlurals.xcstrings`
    @Test func localizablePluralsMatchesMainCatalog() throws {
        let mainStrings = try Self.loadStrings(Self.mainCatalogPath)
        let pluralStrings = try Self.loadStrings(Self.pluralsCatalogPath)

        let expectedPluralKeys = Set(mainStrings.compactMap { key, value -> String? in
            guard let entry = value as? [String: Any],
                  let locs = entry["localizations"] as? [String: Any]
            else { return nil }
            let hasPlural = locs.values.contains { rawLoc in
                guard let loc = rawLoc as? [String: Any] else { return false }
                return loc["variations"] != nil || loc["substitutions"] != nil
            }
            return hasPlural ? key : nil
        })

        #expect(Set(pluralStrings.keys) == expectedPluralKeys)
        for key in expectedPluralKeys.sorted() {
            let mainData = try JSONSerialization.data(
                withJSONObject: try #require(mainStrings[key]),
                options: [.sortedKeys]
            )
            let pluralData = try JSONSerialization.data(
                withJSONObject: try #require(pluralStrings[key]),
                options: [.sortedKeys]
            )
            #expect(
                mainData == pluralData,
                "LocalizablePlurals.xcstrings entry for '\(key)' drifted from Localizable.xcstrings"
            )
        }
    }

    /// Exercises raw-deflate decompression, multi-locale lookup, English
    /// fallback, and (when hosted inside the app bundle) runtime resolution of
    /// both compressed plain strings and native CLDR plural strings.
    @Test func compressedLocalizationsRoundTripAndBundleResolution() throws {
        let payload: [String: Any] = [
            "k": ["common.cancel", "only.en"],
            "l": [
                "en": ["cancel", "english only"],
                "es": ["cancelar", ""],
                "fa": ["لغو", ""],
                "ja": ["キャンセル", ""],
                "ar": ["إلغاء", ""]
            ]
        ]
        let raw = try JSONSerialization.data(withJSONObject: payload)
        let compressed = try (raw as NSData).compressed(using: .zlib) as Data

        let spanish = CompressedLocalizations(compressedData: compressed, preferredLanguages: ["es-MX"])
        #expect(spanish.lookup("common.cancel") == "cancelar")
        #expect(spanish.lookup("only.en") == "english only")
        #expect(spanish.lookup("missing.key") == nil)

        let farsi = CompressedLocalizations(compressedData: compressed, preferredLanguages: ["fa"])
        #expect(farsi.lookup("common.cancel") == "لغو")

        let japanese = CompressedLocalizations(compressedData: compressed, preferredLanguages: ["ja-JP"])
        #expect(japanese.lookup("common.cancel") == "キャンセル")

        let arabic = CompressedLocalizations(compressedData: compressed, preferredLanguages: ["ar"])
        #expect(arabic.lookup("common.cancel") == "إلغاء")

        let unsupported = CompressedLocalizations(compressedData: compressed, preferredLanguages: ["xx"])
        #expect(unsupported.lookup("common.cancel") == "cancel")

        if Bundle.main.bundlePath.hasSuffix(".app") {
            #expect(CompressedLocalizations.shared.lookup("common.cancel") != nil)
            #expect(String(localized: "common.cancel") != "common.cancel")
            #expect(!String(localized: "common.cancel").isEmpty)

            let onePerson = String(
                format: String(localized: "app_info.settings.bridge.cell_people"),
                locale: Locale(identifier: "en"),
                "9q8yy",
                1
            )
            let twoPeople = String(
                format: String(localized: "app_info.settings.bridge.cell_people"),
                locale: Locale(identifier: "en"),
                "9q8yy",
                2
            )
            #expect(onePerson.contains("1"))
            #expect(twoPeople.contains("2"))
            #expect(onePerson != twoPeople)

            let mainCatalog = try Self.loadCatalog(Self.mainCatalogPath)
            #expect(Set(AppLanguageSettings.availableLanguages) == mainCatalog.allLocales)
        }
    }

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
