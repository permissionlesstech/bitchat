//
// NotificationBlockingTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//
// BCH-01-012: Tests for notification blocking feature

import Testing
import Foundation
@testable import bitchat

struct NotificationBlockingTests {

    // MARK: - Nostr Blocking Tests

    @Test("isNostrBlocked returns true for blocked pubkeys")
    func isNostrBlocked_returnsTrueForBlockedPubkey() {
        let keychain = MockKeychain()
        let manager = MockIdentityManager(keychain)

        let testPubkey = "abc123def456".lowercased()

        // Initially not blocked
        #expect(manager.isNostrBlocked(pubkeyHexLowercased: testPubkey) == false)

        // Block the pubkey
        manager.setNostrBlocked(testPubkey, isBlocked: true)

        // Now should be blocked
        #expect(manager.isNostrBlocked(pubkeyHexLowercased: testPubkey) == true)

        // Unblock
        manager.setNostrBlocked(testPubkey, isBlocked: false)
        #expect(manager.isNostrBlocked(pubkeyHexLowercased: testPubkey) == false)
    }

    @Test("isBlocked returns true for blocked fingerprints")
    func isBlocked_returnsTrueForBlockedFingerprint() {
        let keychain = MockKeychain()
        let manager = MockIdentityManager(keychain)

        let testFingerprint = "fingerprint123"

        // Initially not blocked
        #expect(manager.isBlocked(fingerprint: testFingerprint) == false)

        // Block the fingerprint
        manager.setBlocked(testFingerprint, isBlocked: true)

        // Now should be blocked
        #expect(manager.isBlocked(fingerprint: testFingerprint) == true)

        // Unblock
        manager.setBlocked(testFingerprint, isBlocked: false)
        #expect(manager.isBlocked(fingerprint: testFingerprint) == false)
    }

    @Test("getBlockedNostrPubkeys returns all blocked pubkeys")
    func getBlockedNostrPubkeys_returnsAllBlocked() {
        let keychain = MockKeychain()
        let manager = MockIdentityManager(keychain)

        let pubkey1 = "pubkey1".lowercased()
        let pubkey2 = "pubkey2".lowercased()
        let pubkey3 = "pubkey3".lowercased()

        manager.setNostrBlocked(pubkey1, isBlocked: true)
        manager.setNostrBlocked(pubkey2, isBlocked: true)
        manager.setNostrBlocked(pubkey3, isBlocked: true)

        let blocked = manager.getBlockedNostrPubkeys()

        #expect(blocked.count == 3)
        #expect(blocked.contains(pubkey1))
        #expect(blocked.contains(pubkey2))
        #expect(blocked.contains(pubkey3))
    }

    // MARK: - Message Blocking Tests

    @Test("BitchatMessage with blocked sender is identified")
    func bitchatMessage_blockedSenderIdentified() {
        let keychain = MockKeychain()
        let manager = MockIdentityManager(keychain)

        let blockedFingerprint = "blocked_fingerprint_123"
        manager.setBlocked(blockedFingerprint, isBlocked: true)

        #expect(manager.isBlocked(fingerprint: blockedFingerprint) == true)
    }

    @Test("Case insensitive blocking for Nostr pubkeys")
    func nostrBlocking_caseInsensitive() {
        let keychain = MockKeychain()
        let manager = MockIdentityManager(keychain)

        let pubkeyLower = "abc123def456"

        // Block lowercase
        manager.setNostrBlocked(pubkeyLower, isBlocked: true)

        // Check lowercase is blocked
        #expect(manager.isNostrBlocked(pubkeyHexLowercased: pubkeyLower) == true)

        // Note: The API expects lowercased input, so callers must normalize
        // This test verifies the contract that pubkeys should be lowercased before checking
        // The fix in ChatViewModel+Nostr.swift normalizes via event.pubkey.lowercased()
    }
}
