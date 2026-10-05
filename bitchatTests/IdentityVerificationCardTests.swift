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
        #expect(!text.lowercased().contains("private key"))
        #expect(!text.lowercased().contains("seed"))
    }

    /// The signed QR URL is deliberately absent. `verifyScannedQR` rejects a
    /// payload older than `verificationQRMaxAgeSeconds` (5 minutes), so a URL
    /// on a card people keep and forward would stop verifying almost at once
    /// while still reading as the card's most authoritative line.
    @Test func plainTextOmitsTheExpiringVerificationURL() {
        let text = IdentityVerificationCard.current(
            nickname: "alice",
            npub: "npub1test",
            noiseFingerprint: "abcd1234"
        ).plainText
        #expect(!text.contains("bitchat://"))
        #expect(!text.lowercased().contains("scan to verify"))
    }

    /// No npub yet means no npub line — not an empty one.
    @Test func plainTextOmitsTheNpubLineWhenThereIsNoNpub() {
        let withNpub = IdentityVerificationCard.current(
            nickname: "alice",
            npub: "npub1test",
            noiseFingerprint: "abcd1234"
        ).plainText
        let withoutNpub = IdentityVerificationCard.current(
            nickname: "alice",
            npub: nil,
            noiseFingerprint: "abcd1234"
        ).plainText
        #expect(withNpub.contains("npub1test"))
        #expect(!withoutNpub.contains("npub"))
        #expect(withoutNpub.contains("alice"))
        #expect(withoutNpub.contains("abcd1234"))
    }

    /// An empty npub string is the same as none — an empty line would look
    /// like a missing key rather than an absent identity.
    @Test func plainTextTreatsAnEmptyNpubAsAbsent() {
        let text = IdentityVerificationCard.current(
            nickname: "alice",
            npub: "",
            noiseFingerprint: "abcd1234"
        ).plainText
        #expect(!text.contains("npub"))
    }
}
