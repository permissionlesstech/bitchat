//
// ConversationNotificationMuteStoreTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
@testable import bitchat

struct ConversationNotificationMuteStoreTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "ConversationNotificationMuteStoreTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func directMuteUsesFingerprintWhenPresent() {
        let defaults = isolatedDefaults()
        let scope = ConversationNotificationMuteStore.Scope.direct(
            fingerprint: "ABCD1234",
            peerID: "deadbeef"
        )
        ConversationNotificationMuteStore.setMuted(true, for: scope, in: defaults)
        #expect(ConversationNotificationMuteStore.isMuted(scope, in: defaults))
        #expect(ConversationNotificationMuteStore.mutedKeys(in: defaults) == ["dm:abcd1234"])
    }

    @Test func directMuteFallsBackToPeerIDWithoutFingerprint() {
        let defaults = isolatedDefaults()
        let scope = ConversationNotificationMuteStore.Scope.direct(fingerprint: nil, peerID: "Peer99")
        ConversationNotificationMuteStore.setMuted(true, for: scope, in: defaults)
        #expect(ConversationNotificationMuteStore.mutedKeys(in: defaults) == ["dm:peer99"])
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

    @Test func unmuteRemovesKeyAndResetClearsAll() {
        let defaults = isolatedDefaults()
        let dm = ConversationNotificationMuteStore.Scope.direct(fingerprint: "fp", peerID: "x")
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
