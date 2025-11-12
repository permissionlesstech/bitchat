//
// StringUtilsTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct StringUtilsTests {

    // MARK: - DJB2 Hash Tests

    @Test func djb2_producesConsistentHash() {
        let testString = "test"
        let hash1 = testString.djb2()
        let hash2 = testString.djb2()

        #expect(hash1 == hash2, "DJB2 should produce consistent hash for same input")
    }

    @Test func djb2_producesDifferentHashForDifferentStrings() {
        let hash1 = "alice".djb2()
        let hash2 = "bob".djb2()

        #expect(hash1 != hash2, "DJB2 should produce different hashes for different inputs")
    }

    @Test func djb2_emptyStringProducesSeedValue() {
        let hash = "".djb2()

        // Empty string should return the seed value 5381
        #expect(hash == 5381, "DJB2 of empty string should be the seed value")
    }

    @Test func djb2_singleCharacter() {
        let hash = "a".djb2()

        // hash = ((5381 << 5) + 5381) + 97 (ASCII 'a')
        // hash = (5381 * 33) + 97 = 177573 + 97 = 177670
        #expect(hash == 177670, "DJB2 should calculate correctly for single character")
    }

    @Test func djb2_caseMatters() {
        let hash1 = "Alice".djb2()
        let hash2 = "alice".djb2()

        #expect(hash1 != hash2, "DJB2 should be case-sensitive")
    }

    @Test func djb2_unicodeCharacters() {
        let hash1 = "hello".djb2()
        let hash2 = "héllo".djb2()

        #expect(hash1 != hash2, "DJB2 should handle unicode characters")
    }

    @Test func djb2_longString() {
        let longString = String(repeating: "a", count: 1000)
        let hash = longString.djb2()

        #expect(hash > 0, "DJB2 should handle long strings without overflow issues")
    }

    // MARK: - Nickname Suffix Tests

    @Test func splitSuffix_withValidSuffix() {
        let (base, suffix) = "alice#1a2b".splitSuffix()

        #expect(base == "alice", "Base should be 'alice'")
        #expect(suffix == "#1a2b", "Suffix should be '#1a2b'")
    }

    @Test func splitSuffix_withoutSuffix() {
        let (base, suffix) = "bob".splitSuffix()

        #expect(base == "bob", "Base should be 'bob'")
        #expect(suffix == "", "Suffix should be empty")
    }

    @Test func splitSuffix_withMentionSymbol() {
        let (base, suffix) = "@charlie#ffff".splitSuffix()

        #expect(base == "charlie", "Base should be 'charlie' with @ removed")
        #expect(suffix == "#ffff", "Suffix should be '#ffff'")
    }

    @Test func splitSuffix_invalidHexInSuffix() {
        let (base, suffix) = "eve#xyz1".splitSuffix()

        #expect(base == "eve#xyz1", "Should return full string as base when suffix is invalid")
        #expect(suffix == "", "Suffix should be empty for invalid hex")
    }

    @Test func splitSuffix_uppercaseHex() {
        let (base, suffix) = "frank#ABCD".splitSuffix()

        #expect(base == "frank", "Base should be 'frank'")
        #expect(suffix == "#ABCD", "Suffix should handle uppercase hex")
    }

    @Test func splitSuffix_mixedCaseHex() {
        let (base, suffix) = "grace#1A2b".splitSuffix()

        #expect(base == "grace", "Base should be 'grace'")
        #expect(suffix == "#1A2b", "Suffix should handle mixed case hex")
    }

    @Test func splitSuffix_tooShortForSuffix() {
        let (base, suffix) = "dan".splitSuffix()

        #expect(base == "dan", "Base should be 'dan'")
        #expect(suffix == "", "Suffix should be empty for strings too short")
    }

    @Test func splitSuffix_exactlyFiveChars() {
        let (base, suffix) = "#1234".splitSuffix()

        #expect(base == "", "Base should be empty")
        #expect(suffix == "#1234", "Suffix should be '#1234'")
    }

    @Test func splitSuffix_hashButNoSuffix() {
        let (base, suffix) = "user#".splitSuffix()

        #expect(base == "user#", "Base should include the # when suffix is incomplete")
        #expect(suffix == "", "Suffix should be empty")
    }

    @Test func splitSuffix_multipleMentionSymbols() {
        let (base, suffix) = "@@user#1a2b".splitSuffix()

        // All @ symbols should be removed
        #expect(base == "user", "All @ symbols should be removed")
        #expect(suffix == "#1a2b", "Suffix should be '#1a2b'")
    }

    @Test func splitSuffix_zeroesInHex() {
        let (base, suffix) = "zero#0000".splitSuffix()

        #expect(base == "zero", "Base should be 'zero'")
        #expect(suffix == "#0000", "Suffix should handle all zeros")
    }

    @Test func splitSuffix_onlyThreeHexDigits() {
        let (base, suffix) = "short#123".splitSuffix()

        #expect(base == "short#123", "Should not recognize 3-digit suffix")
        #expect(suffix == "", "Suffix should be empty for wrong length")
    }

    @Test func splitSuffix_fiveHexDigits() {
        let (base, suffix) = "long#12345".splitSuffix()

        #expect(base == "long#12345", "Should not recognize 5-digit suffix")
        #expect(suffix == "", "Suffix should be empty for wrong length")
    }

    @Test func splitSuffix_multipleHashSymbols() {
        let (base, suffix) = "test##1234".splitSuffix()

        // Should only look at the last 5 characters
        #expect(base == "test##1234", "Should not recognize suffix with double hash")
        #expect(suffix == "", "Suffix should be empty")
    }

    @Test func splitSuffix_emptyString() {
        let (base, suffix) = "".splitSuffix()

        #expect(base == "", "Base should be empty")
        #expect(suffix == "", "Suffix should be empty")
    }

    @Test func splitSuffix_realWorldExample() {
        let (base1, suffix1) = "alice#a1b2".splitSuffix()
        let (base2, suffix2) = "alice#c3d4".splitSuffix()

        #expect(base1 == base2, "Base nicknames should match")
        #expect(suffix1 != suffix2, "Suffixes should differ")
        #expect(base1 == "alice", "Base should be 'alice'")
    }
}
