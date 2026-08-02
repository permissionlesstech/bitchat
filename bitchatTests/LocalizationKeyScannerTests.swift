import Testing

struct LocalizationKeyScannerTests {
    @Test func extractsKeyWithDefaultValue() {
        let line = """
        String(localized: "channel.share.action", defaultValue: "share channel", comment: "…")
        """
        #expect(LocalizationKeyScanner.keys(in: line) == ["channel.share.action"])
    }

    @Test func extractsKeyWithoutDefaultValue() {
        let line = """
        String(localized: "common.done", comment: "Dismisses a sheet")
        """
        #expect(LocalizationKeyScanner.keys(in: line) == ["common.done"])
    }

    @Test func ignoresNonLocalizedStrings() {
        let line = #""content.actions.mention""#
        #expect(LocalizationKeyScanner.keys(in: line).isEmpty)
    }

    @Test func productionSourcesHaveCatalogEntries() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let refs = try LocalizationKeyScanner.scanProductionSources(repoRoot: repoRoot)
        #expect(!refs.isEmpty, "expected at least one String(localized:) reference")

        let catalogData = try Data(contentsOf: repoRoot.appendingPathComponent("bitchat/Localizable.xcstrings"))
        let catalogRoot = try #require(try JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try #require(catalogRoot["strings"] as? [String: Any])
        let catalogKeys = Set(strings.keys)

        let shareData = try Data(contentsOf: repoRoot.appendingPathComponent("bitchatShareExtension/Localization/Localizable.xcstrings"))
        let shareRoot = try #require(try JSONSerialization.jsonObject(with: shareData) as? [String: Any])
        let shareStrings = try #require(shareRoot["strings"] as? [String: Any])
        let shareKeys = Set(shareStrings.keys)

        var missingMain: [String] = []
        var missingShare: [String] = []
        for ref in refs {
            let isShare = ref.file.hasPrefix("bitchatShareExtension/")
            if isShare {
                if !shareKeys.contains(ref.key) { missingShare.append("\(ref.key) (\(ref.file):\(ref.line))") }
            } else {
                if !catalogKeys.contains(ref.key) { missingMain.append("\(ref.key) (\(ref.file):\(ref.line))") }
            }
        }
        #expect(missingMain.isEmpty, "main catalog missing keys: \(missingMain.joined(separator: ", "))")
        #expect(missingShare.isEmpty, "share extension catalog missing keys: \(missingShare.joined(separator: ", "))")
    }
}
