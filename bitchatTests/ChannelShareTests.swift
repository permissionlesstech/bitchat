//
// ChannelShareTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

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

    @Test func precisionWarningStartsAtNeighborhood() {
        #expect(!ChannelShare.shouldWarn(forGeohash: "u4pru")) // city = 5
        #expect(ChannelShare.shouldWarn(forGeohash: "u4pruy")) // neighborhood = 6
        #expect(ChannelShare.shouldWarn(forGeohash: "u4pruyzd"))
    }
}
