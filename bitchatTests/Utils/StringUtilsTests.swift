//
// StringUtilsTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
@testable import bitchat

struct StringUtilsTests {

    // MARK: - DJB2

    @Test func djb2_isDeterministic() {
        let input = "alice"

        #expect(input.djb2() == input.djb2())
    }

    @Test func djb2_isCaseSensitive() {
        let hashes = Set([
            "Alice".djb2(),
            "alice".djb2(),
            "ALICE".djb2()
        ])

        #expect(hashes.count > 1, "DJB2 should not collapse differently cased strings to one value")
    }

    @Test func djb2_unicodeContentIsDeterministic() {
        let unicodeName = "caf\u{00E9}"

        #expect(unicodeName.djb2() == unicodeName.djb2())
        #expect(unicodeName.djb2() != "cafe".djb2())
        #expect("\u{1F44B}".djb2() != "\u{1F44B}!".djb2())
    }

    @Test func djb2_emptyStringUsesSeedValue() {
        #expect("".djb2() == 5381)
    }

    // MARK: - Nickname suffixes

    @Test func splitSuffix_parsesValidSuffix() {
        let (base, suffix) = "alice#1a2b".splitSuffix()

        #expect(base == "alice")
        #expect(suffix == "#1a2b")
    }

    @Test func splitSuffix_parsesMentionSuffix() {
        let (base, suffix) = "@charlie#ffff".splitSuffix()

        #expect(base == "charlie")
        #expect(suffix == "#ffff")
    }

    @Test func splitSuffix_returnsNameWhenNoSuffixExists() {
        let (base, suffix) = "bob".splitSuffix()

        #expect(base == "bob")
        #expect(suffix == "")
    }

    @Test func splitSuffix_rejectsInvalidHex() {
        let (base, suffix) = "eve#xyz1".splitSuffix()

        #expect(base == "eve#xyz1")
        #expect(suffix == "")
    }

    @Test func splitSuffix_rejectsShortSuffix() {
        let (base, suffix) = "a#123".splitSuffix()

        #expect(base == "a#123")
        #expect(suffix == "")
    }

    @Test func splitSuffix_rejectsDoubleHashSuffix() {
        let (base, suffix) = "test##1234".splitSuffix()

        #expect(base == "test##1234", "Double-hash nicknames must remain unsplit")
        #expect(suffix == "", "Double-hash nicknames must not produce a suffix")
    }
}
