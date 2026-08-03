import Foundation
import Testing

/// Unit coverage for `LocalizationKeyScanner` parsing and the end-to-end
/// “every production call site has a catalog entry” check.
///
/// The membership assertion here overlaps `LocalizationCoverageTests`, on
/// purpose: this file owns the scanner’s behavior (extract / skip / sort),
/// while `LocalizationCoverageTests` owns catalog *locale completeness*.
/// Keeping a thin membership check here means a broken scanner fails next to
/// the parser tests instead of only in the coverage suite.
struct LocalizationKeyScannerTests {

    // MARK: - Line parsing

    /// `defaultValue:` is the usual shape when a key is first introduced; the
    /// catalog entry may still be missing, which is exactly what CI should catch.
    @Test func extractsKeyWithDefaultValue() {
        let line = """
        String(localized: "channel.share.action", defaultValue: "share channel", comment: "…")
        """
        #expect(LocalizationKeyScanner.keys(in: line) == ["channel.share.action"])
    }

    /// Keys that already live in the catalog often omit `defaultValue:`.
    @Test func extractsKeyWithoutDefaultValue() {
        let line = """
        String(localized: "common.done", comment: "Dismisses a sheet")
        """
        #expect(LocalizationKeyScanner.keys(in: line) == ["common.done"])
    }

    /// Bare string literals (table identifiers, SF Symbol names, …) must not
    /// be mistaken for localization keys.
    @Test func ignoresNonLocalizedStrings() {
        let line = #""content.actions.mention""#
        #expect(LocalizationKeyScanner.keys(in: line).isEmpty)
    }

    /// Two call sites on one line should both be reported (unusual, but the
    /// scanner must not stop after the first match).
    @Test func extractsMultipleKeysOnOneLine() {
        let line = """
        let a = String(localized: "common.cancel"); let b = String(localized: "common.done")
        """
        #expect(LocalizationKeyScanner.keys(in: line) == ["common.cancel", "common.done"])
    }

    /// Non-literal keys (`String(localized: someKey)`) are invisible to the
    /// scanner — document that so a future change does not “fix” it by accident.
    @Test func ignoresNonLiteralLocalizedKeys() {
        let line = #"String(localized: String.LocalizationValue(dynamicKey))"#
        #expect(LocalizationKeyScanner.keys(in: line).isEmpty)
    }

    // MARK: - Production tree scan

    /// End-to-end: walk the real `bitchat` / `bitchatShareExtension` trees and
    /// require every extracted key to exist in the matching `.xcstrings` file.
    @Test func productionSourcesHaveCatalogEntries() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // bitchatTests/
            .deletingLastPathComponent() // repo root

        let refs = try LocalizationKeyScanner.scanProductionSources(repoRoot: repoRoot)
        #expect(!refs.isEmpty, "expected at least one String(localized:) reference")

        // Preview helpers are skipped so this set stays free of throwaway keys.
        #expect(
            refs.allSatisfy { !$0.file.contains("/_PreviewHelpers/") },
            "scanner should skip _PreviewHelpers paths"
        )

        let catalogKeys = try Self.loadCatalogKeys(
            at: repoRoot.appendingPathComponent("bitchat/Localizable.xcstrings")
        )
        let shareKeys = try Self.loadCatalogKeys(
            at: repoRoot.appendingPathComponent("bitchatShareExtension/Localization/Localizable.xcstrings")
        )

        var missingMain: [String] = []
        var missingShare: [String] = []
        for ref in refs {
            let isShare = ref.file.hasPrefix("bitchatShareExtension/")
            if isShare {
                if !shareKeys.contains(ref.key) {
                    missingShare.append("\(ref.key) (\(ref.file):\(ref.line))")
                }
            } else if !catalogKeys.contains(ref.key) {
                missingMain.append("\(ref.key) (\(ref.file):\(ref.line))")
            }
        }

        #expect(
            missingMain.isEmpty,
            "main catalog missing keys: \(missingMain.joined(separator: ", "))"
        )
        #expect(
            missingShare.isEmpty,
            "share extension catalog missing keys: \(missingShare.joined(separator: ", "))"
        )
    }

    // MARK: - Helpers

    /// Reads the top-level `"strings"` object keys from an `.xcstrings` file.
    private static func loadCatalogKeys(at url: URL) throws -> Set<String> {
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        return Set(strings.keys)
    }
}
