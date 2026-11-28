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
    func collisionSuffixSplittingSurvivesNormalization() {
        let (base, suffix) = (decomposed.normalizedNickname + "#ab12").splitSuffix()
        #expect(base == precomposed)
        #expect(suffix == "#ab12")
    }

    @Test
    func utf8TruncationRespectsByteLimitAndGraphemeBoundaries() {
        let longASCII = String(repeating: "a", count: 300)
        let truncatedASCII = longASCII.truncatedToUTF8Bytes(String.maxNicknameUTF8Bytes)
        #expect(truncatedASCII.utf8.count == 255)

        // 4-byte emoji: 70 * 4 = 280 bytes -> at most 63 emoji (252 bytes), never splitting a scalar.
        let emojiNick = String(repeating: "🔥", count: 70)
        let truncatedEmoji = emojiNick.truncatedToUTF8Bytes(String.maxNicknameUTF8Bytes)
        #expect(truncatedEmoji.count == 63)
        #expect(truncatedEmoji.utf8.count == 252)

        // ZWJ family emoji is 25 UTF-8 bytes as one Character; 11 copies = 275 bytes -> 10 copies (250 bytes).
        let zwjNick = String(repeating: "👨‍👩‍👧‍👦", count: 11)
        let truncatedZWJ = zwjNick.truncatedToUTF8Bytes(String.maxNicknameUTF8Bytes)
        #expect(truncatedZWJ.count == 10)
        #expect(truncatedZWJ.utf8.count <= String.maxNicknameUTF8Bytes)

        let packet = AnnouncementPacket(
            nickname: truncatedEmoji,
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            directNeighbors: nil
        )
        #expect(packet.encode() != nil)
    }
}
