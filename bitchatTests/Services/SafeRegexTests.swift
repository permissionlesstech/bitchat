//
// SafeRegexTests.swift
// bitchatTests
//
// SafeRegex must never trap: valid patterns compile normally, invalid ones
// degrade to a regex that matches nothing. The production-pattern test keeps
// the compile-time guarantee try! used to provide - a typo in any bundled
// pattern fails here instead of crashing the app at startup.
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

struct SafeRegexTests {

    private func matchCount(_ regex: NSRegularExpression, _ text: String) -> Int {
        regex.numberOfMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
    }

    @Test
    func validPatternCompilesAndMatches() {
        let regex = SafeRegex.compile("#([a-zA-Z0-9_]+)")
        #expect(matchCount(regex, "tag #bitchat here") == 1)
    }

    @Test
    func invalidPatternDegradesToNeverMatching() {
        let regex = SafeRegex.compile("(unclosed")
        #expect(matchCount(regex, "(unclosed anything") == 0)
        #expect(matchCount(regex, "") == 0)
    }

    @Test
    func productionPatternsCompileAndMatchTheirTargets() {
        // A pattern that failed to compile would have degraded to
        // never-matching, so each positive match proves the literal compiled.
        #expect(matchCount(MessageFormattingEngine.Patterns.hashtag, "see #mesh") == 1)
        #expect(matchCount(MessageFormattingEngine.Patterns.mention, "hi @alice#ab12") == 1)

        let cashuToken = "cashuA" + String(repeating: "x", count: 45)
        #expect(matchCount(MessageFormattingEngine.Patterns.cashu, cashuToken) == 1)
        #expect(matchCount(MessageFormattingEngine.Patterns.quickCashuPresence, cashuToken) == 1)

        let bolt11 = "lnbc1" + String(repeating: "q", count: 55)
        #expect(matchCount(MessageFormattingEngine.Patterns.bolt11, bolt11) == 1)

        let lnurl = "lnurl1" + String(repeating: "q", count: 25)
        #expect(matchCount(MessageFormattingEngine.Patterns.lnurl, lnurl) == 1)

        #expect(matchCount(MessageFormattingEngine.Patterns.lightningScheme, "pay lightning:abc123") == 1)
    }

    @Test
    func contentNormalizerStillSimplifiesURLs() {
        // Exercises ContentNormalizer's regex through its public entry point:
        // same URL with different query strings must normalize identically.
        let a = ContentNormalizer.normalizedKey("check https://example.com/page?q=1")
        let b = ContentNormalizer.normalizedKey("check https://example.com/page?q=2")
        #expect(a == b)
    }
}
