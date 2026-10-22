//
// ChannelShareTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

struct ChannelShareTests {
    @Test func payloadIncludesGeohashDeepLinkAndStoreURL() {
        let text = ChannelShare.payload(forGeohash: "u4pru")
        #expect(text.contains("#u4pru"))
        #expect(text.contains("bitchat://geohash/u4pru"))
        #expect(text.contains(ChannelShare.appStoreURL))
        #expect(!text.lowercased().contains("i'm in"))
    }

    /// Both links in an invite should come through link detection intact,
    /// so this runs every locale's format through the shipped formatting and
    /// checks what NSDataDetector finds. Two ways it has broken: a locale
    /// makes Foundation wrap the arguments of a right-to-left format in bidi
    /// isolates, which cut the deep link off at `bitchat://geohash`; and text
    /// attached to a URL with no space (Korean `에서`) is read as part of it.
    @Test func everyLocaleKeepsBothInviteLinksIntact() throws {
        let formats = try Self.payloadFormats()
        #expect(formats.count > 1, "catalog should carry more locales than the source language")
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for (locale, format) in formats.sorted(by: { $0.key < $1.key }) {
            let text = ChannelShare.payload(forGeohash: "u4pru", format: format)
            let links = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { $0.url?.absoluteString }
            #expect(links.contains("bitchat://geohash/u4pru"), "\(locale): deep link not intact in \(links)")
            #expect(links.contains(ChannelShare.appStoreURL), "\(locale): store link not intact in \(links)")
        }
    }

    @Test func precisionWarningStartsAtNeighborhood() {
        #expect(!ChannelShare.shouldWarn(forGeohash: "u4pru")) // city = 5
        #expect(ChannelShare.shouldWarn(forGeohash: "u4pruy")) // neighborhood = 6
        #expect(ChannelShare.shouldWarn(forGeohash: "u4pruyzd"))
    }

    /// Every locale's `channel.share.payload` format, read from the catalog
    /// source the way `LocalizationCoverageTests` reads it.
    private static func payloadFormats() throws -> [String: String] {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // bitchatTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("bitchat/Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings["channel.share.payload"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: [String: Any]])
        return try localizations.mapValues { localization in
            let unit = try #require(localization["stringUnit"] as? [String: Any])
            return try #require(unit["value"] as? String)
        }
    }
}
