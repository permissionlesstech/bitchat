//
// NicknameUnicodeTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
@testable import bitchat

struct NicknameUnicodeTests {
    @Test func nfcAndNfdFormsMatch() {
        // U+00E9 LATIN SMALL LETTER E WITH ACUTE (NFC)
        let nfc = "caf\u{00E9}"
        // e + U+0301 COMBINING ACUTE ACCENT (NFD)
        let nfd = "cafe\u{0301}"

        #expect(nfc != nfd)
        #expect(nfc.bitchatNicknameMatches(nfd))
        #expect(nfc.bitchatCanonicalNickname == nfd.bitchatCanonicalNickname)
    }

    @Test func caseFoldingUsesCanonicalForm() {
        let upperNFC = "CAF\u{00C9}"
        let lowerNFD = "cafe\u{0301}"
        #expect(upperNFC.bitchatNicknameMatches(lowerNFD))
    }
}
