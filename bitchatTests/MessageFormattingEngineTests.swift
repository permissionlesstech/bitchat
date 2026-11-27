//
// MessageFormattingEngineTests.swift
// bitchatTests
//
// Tests for MessageFormattingEngine regex patterns and utility functions.
// This is free and unencumbered software released into the public domain.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct MessageFormattingEngineTests {
    // MARK: - Regex Pattern Tests

    @Test func hashtagPattern_standaloneHashtag() {
        let content = "#bitcoin is great"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.hashtag.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    @Test func hashtagPattern_multipleHashtags() {
        let content = "#bitcoin #lightning #nostr"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.hashtag.matches(in: content, options: [], range: range)
        #expect(matches.count == 3)
    }

    @Test func hashtagPattern_hashInMiddleOfWord() {
        let content = "test#notahashtag"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.hashtag.matches(in: content, options: [], range: range)
        // This will match because the regex doesn't check for word boundaries
        #expect(matches.count == 1)
    }

    @Test func bolt11Pattern_mainnet() {
        let content = "Pay this: lnbc10u1pjexampleinvoice0000000000000000000000000000000000000000000"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.bolt11.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    @Test func bolt11Pattern_testnet() {
        let content = "Test: lntb10u1pjexampleinvoice0000000000000000000000000000000000000000000"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.bolt11.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    @Test func lnurlPattern_valid() {
        let content = "LNURL: lnurl1dp68gurn8ghj7um9wfmxjcm99e3k7mf0v9cxj0m385ekvcenxc6r2c35xvukxefcv5mkvv34x5ekzd3ev56nyd3hxqurzepexejxxepnxscrvwfnv9nxzcn9xq6xyefhvgcxxcmyxymnserx"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.lnurl.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    @Test func lightningSchemePattern_valid() {
        let content = "Click: lightning:lnbc10u1example"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.lightningScheme.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    @Test func cashuPattern_valid() {
        let content = "Token: cashuAeyJwcm9vZnMiOlt7ImlkIjoiMDAwMDAwMDAwMDAwMDAwMCJ9XX0="
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.cashu.matches(in: content, options: [], range: range)
        #expect(matches.count == 1)
    }

    // MARK: - URL Detection Tests

    @Test func linkDetector_httpURL() {
        let content = "Check out http://example.com"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.linkDetector?.matches(in: content, options: [], range: range) ?? []
        #expect(matches.count == 1)
    }

    @Test func linkDetector_httpsURL() {
        let content = "Visit https://example.com/path?query=value"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.linkDetector?.matches(in: content, options: [], range: range) ?? []
        #expect(matches.count == 1)
    }

    @Test func linkDetector_multipleURLs() {
        let content = "See https://a.com and http://b.com"
        let nsContent = content as NSString
        let range = NSRange(location: 0, length: nsContent.length)
        let matches = MessageFormattingEngine.Patterns.linkDetector?.matches(in: content, options: [], range: range) ?? []
        #expect(matches.count == 2)
    }

    // MARK: - String Extension Tests

    @Test func splitSuffix_withSuffix() {
        let name = "alice#a1b2"
        let (base, suffix) = name.splitSuffix()
        #expect(base == "alice")
        #expect(suffix == "#a1b2")
    }

    @Test func splitSuffix_withoutSuffix() {
        let name = "alice"
        let (base, suffix) = name.splitSuffix()
        #expect(base == "alice")
        #expect(suffix == "")
    }

    @Test func splitSuffix_withAtPrefix() {
        let name = "@alice#a1b2"
        let (base, suffix) = name.splitSuffix()
        #expect(base == "alice")
        #expect(suffix == "#a1b2")
    }

    @Test func hasVeryLongToken_noLongToken() {
        let content = "Short words only here"
        #expect(!content.hasVeryLongToken(threshold: 50))
    }

    @Test func hasVeryLongToken_withLongToken() {
        let longToken = String(repeating: "a", count: 100)
        let content = "Here is a \(longToken) token"
        #expect(content.hasVeryLongToken(threshold: 50))
    }

    @Test func hasVeryLongToken_exactThreshold() {
        let exactToken = String(repeating: "a", count: 50)
        let content = "Token: \(exactToken)"
        // Exactly at threshold DOES trigger (uses >= comparison)
        #expect(content.hasVeryLongToken(threshold: 50))
    }

    @Test func isLongForDisplay_doesNotIgnoreCashuLinks() {
        let cashu = "cashuA" + String(repeating: "a", count: 40)
        let content = String(repeating: "a", count: TransportConfig.uiLongMessageLengthThreshold + 1) + " " + cashu

        #expect(content.extractCashuLinks().count == 1)
        #expect(content.isLongForDisplay())
    }

    @Test func contentScan_matchesTheStringScansAndIsCachedOnTheMessage() {
        let cashu = "cashuA" + String(repeating: "a", count: 40)
        let invoice = "lnbc1" + String(repeating: "q", count: 60)
        let long = String(repeating: "a", count: TransportConfig.uiLongMessageLengthThreshold + 1)
        let contents = [
            "plain words",
            "pay \(cashu) or lightning:\(invoice) or \(invoice)",
            "\(long) \(cashu)",
            "same \(cashu) twice \(cashu)"
        ]

        for content in contents {
            let message = BitchatMessage(sender: "alice", content: content, timestamp: Date(), isRelay: false)
            #expect(message.getCachedContentScan() == nil)

            let scan = message.contentScan
            #expect(scan.cashuLinks == content.extractCashuLinks())
            #expect(scan.lightningLinks == content.extractLightningLinks())
            #expect(scan.isLongForDisplay == content.isLongForDisplay())
            #expect(message.getCachedContentScan() == scan)
        }
    }

    @Test func contentScan_servesTheCachedScanWithoutRescanning() {
        let cashu = "cashuA" + String(repeating: "a", count: 40)
        let message = BitchatMessage(sender: "alice", content: "pay \(cashu)", timestamp: Date(), isRelay: false)
        // A sentinel no scan of this content could produce.
        let sentinel = BitchatMessage.ContentScan(cashuLinks: [], lightningLinks: ["lightning:sentinel"], isLongForDisplay: true)

        message.setCachedContentScan(sentinel)

        #expect(message.contentScan == sentinel)
    }
}
