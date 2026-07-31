//
// NicknameNormalizationTests.swift
// bitchatTests
//
// Nicknames must compare equal regardless of how the user's keyboard
// produced them: "café" as precomposed U+00E9 and as "e" + combining
// U+0301 are canonically equivalent but bytewise different, which broke
// mention matching, DM resolution, and autocomplete (#214). Storage and
// comparison both canonicalize to NFC via String.normalizedNickname.
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

struct NicknameNormalizationTests {
    /// "café" with a combining acute accent (NFD form)
    private let decomposed = "cafe\u{0301}"
    /// "café" with precomposed é (NFC form)
    private let precomposed = "caf\u{00E9}"

    @Test
    func canonicallyEquivalentFormsNormalizeIdentically() {
        // Sanity: the raw forms really are different strings byte-wise …
        #expect(decomposed.unicodeScalars.count != precomposed.unicodeScalars.count)
        // … and normalization unifies them.
        #expect(decomposed.normalizedNickname == precomposed.normalizedNickname)
        #expect(decomposed.normalizedNickname == precomposed)
    }

    @Test
    func asciiNicknamesPassThroughUnchanged() {
        #expect("alice_42".normalizedNickname == "alice_42")
        #expect("".normalizedNickname == "")
    }

    @Test
    func validateNicknameReturnsCanonicalForm() {
        #expect(InputValidator.validateNickname(decomposed) == precomposed)
        #expect(InputValidator.validateNickname("  \(decomposed)  ") == precomposed)
        // Validation behavior is otherwise unchanged.
        #expect(InputValidator.validateNickname("   ") == nil)
    }

    @Test
    func collisionSuffixSplittingSurvivesNormalization() {
        let (base, suffix) = (decomposed.normalizedNickname + "#ab12").splitSuffix()
        #expect(base == precomposed)
        #expect(suffix == "#ab12")
    }
}
