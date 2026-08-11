//
// ConversationNotificationMuteStoreTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

struct ConversationNotificationMuteStoreTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "ConversationNotificationMuteStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func directMuteKeysOnTheFingerprint() throws {
        let defaults = isolatedDefaults()
        let scope = try #require(ConversationNotificationMuteStore.Scope.direct(fingerprint: "ABCD1234"))
        ConversationNotificationMuteStore.setMuted(true, for: scope, in: defaults)
        #expect(ConversationNotificationMuteStore.isMuted(scope, in: defaults))
        #expect(ConversationNotificationMuteStore.mutedKeys(in: defaults) == ["dm:abcd1234"])
    }

    /// There is no routing-peer-ID fallback on purpose: peer IDs rotate, so a
    /// mute keyed on one would silently stop applying while the UI still
    /// showed the conversation muted.
    @Test func directMuteIsUnavailableWithoutAFingerprint() {
        #expect(ConversationNotificationMuteStore.Scope.direct(fingerprint: nil) == nil)
        #expect(ConversationNotificationMuteStore.Scope.direct(fingerprint: "") == nil)
        #expect(ConversationNotificationMuteStore.Scope.direct(fingerprint: "   ") == nil)
    }

    /// The bug this replaced: writing `dm:<fingerprint>` on the toggle side and
    /// looking up `dm:<peerid>` on the notification side left the mute silently
    /// ineffective. One resolver means one key.
    @Test func aFingerprintKeyIsNeverConfusedWithAPeerIDKey() throws {
        let defaults = isolatedDefaults()
        let byFingerprint = try #require(ConversationNotificationMuteStore.Scope.direct(fingerprint: "ABCD1234"))
        ConversationNotificationMuteStore.setMuted(true, for: byFingerprint, in: defaults)
        // A scope built from what used to be the peer-ID fallback must not read
        // as muted.
        let byPeerID = try #require(ConversationNotificationMuteStore.Scope.direct(fingerprint: "deadbeef"))
        #expect(!ConversationNotificationMuteStore.isMuted(byPeerID, in: defaults))
    }

    @Test func geohashMuteIsCaseInsensitive() {
        let defaults = isolatedDefaults()
        let scope = ConversationNotificationMuteStore.Scope.geohash("U4PRUY")
        ConversationNotificationMuteStore.setMuted(true, for: scope, in: defaults)
        #expect(
            ConversationNotificationMuteStore.isMuted(
                .geohash("u4pruy"),
                in: defaults
            )
        )
    }

    @Test func unmuteRemovesKeyAndResetClearsAll() throws {
        let defaults = isolatedDefaults()
        let dm = try #require(ConversationNotificationMuteStore.Scope.direct(fingerprint: "fp"))
        let geo = ConversationNotificationMuteStore.Scope.geohash("u4pru")
        ConversationNotificationMuteStore.setMuted(true, for: dm, in: defaults)
        ConversationNotificationMuteStore.setMuted(true, for: geo, in: defaults)
        ConversationNotificationMuteStore.setMuted(false, for: dm, in: defaults)
        #expect(!ConversationNotificationMuteStore.isMuted(dm, in: defaults))
        #expect(ConversationNotificationMuteStore.isMuted(geo, in: defaults))
        ConversationNotificationMuteStore.reset(in: defaults)
        #expect(ConversationNotificationMuteStore.mutedKeys(in: defaults).isEmpty)
    }
}
