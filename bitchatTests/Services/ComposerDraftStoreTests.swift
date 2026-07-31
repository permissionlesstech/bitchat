import Foundation
import Testing
@testable import bitchat
import BitFoundation

struct ComposerDraftStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "bitchat.tests.drafts.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func emptyDraftIsNotStored() {
        let defaults = makeDefaults()
        ComposerDraftStore.save("hello", for: .mesh, in: defaults)
        ComposerDraftStore.save("   ", for: .mesh, in: defaults)
        // Whitespace-only is still a draft the user typed; empty string clears.
        ComposerDraftStore.save("", for: .mesh, in: defaults)
        #expect(ComposerDraftStore.load(.mesh, in: defaults).isEmpty)
        #expect(defaults.object(forKey: ComposerDraftStore.storageKey) == nil)
    }

    @Test func draftsAreIsolatedPerConversation() {
        let defaults = makeDefaults()
        let peer = PeerID(str: "aabbccddeeff0011")
        ComposerDraftStore.save("mesh draft", for: .mesh, in: defaults)
        ComposerDraftStore.save("geo draft", for: .location(geohash: "u4pruy"), in: defaults)
        ComposerDraftStore.save("dm draft", for: .privatePeer(peer), in: defaults)

        #expect(ComposerDraftStore.load(.mesh, in: defaults) == "mesh draft")
        #expect(ComposerDraftStore.load(.location(geohash: "u4pruy"), in: defaults) == "geo draft")
        #expect(ComposerDraftStore.load(.privatePeer(peer), in: defaults) == "dm draft")
        #expect(ComposerDraftStore.load(.location(geohash: "other"), in: defaults).isEmpty)
    }

    @Test func geohashKeysAreCaseInsensitive() {
        let defaults = makeDefaults()
        ComposerDraftStore.save("city chat", for: .location(geohash: "U4PRUY"), in: defaults)
        #expect(ComposerDraftStore.load(.location(geohash: "u4pruy"), in: defaults) == "city chat")
    }

    @Test func keyFromPeerAndChannelPrefersPrivate() {
        let peer = PeerID(str: "aabbccddeeff0011")
        let key = ComposerDraftStore.Key.from(
            peerID: peer,
            channel: .location(GeohashChannel(level: .city, geohash: "u4pruy"))
        )
        #expect(key == .privatePeer(peer))
    }

    @Test func longDraftsAreTruncated() {
        let defaults = makeDefaults()
        let long = String(repeating: "a", count: ComposerDraftStore.maxDraftLength + 50)
        ComposerDraftStore.save(long, for: .mesh, in: defaults)
        #expect(ComposerDraftStore.load(.mesh, in: defaults).count == ComposerDraftStore.maxDraftLength)
    }

    @Test func resetClearsAllDrafts() {
        let defaults = makeDefaults()
        ComposerDraftStore.save("keep quiet", for: .mesh, in: defaults)
        ComposerDraftStore.reset(in: defaults)
        #expect(ComposerDraftStore.load(.mesh, in: defaults).isEmpty)
        #expect(defaults.object(forKey: ComposerDraftStore.storageKey) == nil)
    }
}
