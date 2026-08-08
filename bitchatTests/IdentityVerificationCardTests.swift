//
// IdentityVerificationCardTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
@testable import bitchat

struct IdentityVerificationCardTests {
    @Test func plainTextIncludesPublicFieldsOnly() {
        let card = IdentityVerificationCard.current(
            nickname: "alice",
            npub: "npub1test",
            noiseFingerprint: "abcd1234"
        )
        let text = card.plainText
        #expect(text.contains("alice"))
        #expect(text.contains("npub1test"))
        #expect(text.contains("abcd1234"))
        #expect(!text.contains("bitchat://"))
        #expect(!text.lowercased().contains("private key"))
        #expect(!text.lowercased().contains("seed"))
    }
}
