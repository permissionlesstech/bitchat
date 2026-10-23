import Foundation
import Testing
@testable import bitchat
import BitFoundation

@Suite(.serialized)
struct ComposerDraftStoreTests {
    /// Isolate each test from leftover in-memory drafts.
    private func withCleanStore(_ body: () throws -> Void) rethrows {
        ComposerDraftStore.replaceAllForTesting([:])
        defer { ComposerDraftStore.replaceAllForTesting([:]) }
        try body()
    }

    @Test func emptyDraftIsNotStored() throws {
        try withCleanStore {
            ComposerDraftStore.save("hello", for: .mesh)
            ComposerDraftStore.save("   ", for: .mesh)
            // Whitespace-only is still a draft the user typed; empty string clears.
            ComposerDraftStore.save("", for: .mesh)
            #expect(ComposerDraftStore.load(.mesh).isEmpty)
            #expect(ComposerDraftStore.countForTesting() == 0)
        }
    }

    @Test func draftsAreIsolatedPerConversation() throws {
        try withCleanStore {
            let peer = PeerID(str: "aabbccddeeff0011")
            ComposerDraftStore.save("mesh draft", for: .mesh)
            ComposerDraftStore.save("geo draft", for: .location(geohash: "u4pruy"))
            ComposerDraftStore.save("dm draft", for: .privateChat(stableID: peer.id))

            #expect(ComposerDraftStore.load(.mesh) == "mesh draft")
            #expect(ComposerDraftStore.load(.location(geohash: "u4pruy")) == "geo draft")
            #expect(ComposerDraftStore.load(.privateChat(stableID: peer.id)) == "dm draft")
            #expect(ComposerDraftStore.load(.location(geohash: "other")).isEmpty)
        }
    }

    @Test func geohashKeysAreCaseInsensitive() throws {
        try withCleanStore {
            ComposerDraftStore.save("city chat", for: .location(geohash: "U4PRUY"))
            #expect(ComposerDraftStore.load(.location(geohash: "u4pruy")) == "city chat")
        }
    }

    @Test func keyFromPeerPrefersFingerprintWhenPresent() {
        let peer = PeerID(str: "aabbccddeeff0011")
        let withFP = ComposerDraftStore.Key.from(
            peerID: peer,
            fingerprint: "deadbeefcafebabe",
            channel: .location(GeohashChannel(level: .city, geohash: "u4pruy"))
        )
        #expect(withFP == .privateChat(stableID: "deadbeefcafebabe"))

        let withoutFP = ComposerDraftStore.Key.from(
            peerID: peer,
            fingerprint: nil,
            channel: .mesh
        )
        #expect(withoutFP == .privateChat(stableID: peer.id))
    }

    /// A disconnect hands an open DM from the short ID to the 64-hex Noise
    /// key, which the fingerprint lookup only knows for favorites.
    @Test func keyFromNoiseKeyPeerMatchesItsShortIDsFingerprint() {
        let noiseKey = Data((0..<32).map { UInt8($0) })
        let fingerprint = noiseKey.sha256Fingerprint()
        let shortID = PeerID(publicKey: noiseKey)
        let stableID = PeerID(hexData: noiseKey)

        let shortKey = ComposerDraftStore.Key.from(
            peerID: shortID,
            fingerprint: fingerprint,
            channel: .mesh
        )
        let stableKey = ComposerDraftStore.Key.from(
            peerID: stableID,
            fingerprint: nil,
            channel: .mesh
        )
        #expect(stableKey == shortKey)
        #expect(stableKey == .privateChat(stableID: fingerprint))

        // A short ID before its fingerprint is known still keys by itself.
        let shortWithoutFP = ComposerDraftStore.Key.from(
            peerID: shortID,
            fingerprint: nil,
            channel: .mesh
        )
        #expect(shortWithoutFP == .privateChat(stableID: shortID.id))
    }

    @Test func longDraftsAreTruncated() throws {
        try withCleanStore {
            let long = String(repeating: "a", count: ComposerDraftStore.maxDraftLength + 50)
            ComposerDraftStore.save(long, for: .mesh)
            #expect(ComposerDraftStore.load(.mesh).count == ComposerDraftStore.maxDraftLength)
        }
    }

    @Test func resetClearsAllDrafts() throws {
        try withCleanStore {
            ComposerDraftStore.save("keep quiet", for: .mesh)
            ComposerDraftStore.reset()
            #expect(ComposerDraftStore.load(.mesh).isEmpty)
            #expect(ComposerDraftStore.countForTesting() == 0)
        }
    }

    @Test func maxDraftCountEvictsOldestKeys() throws {
        try withCleanStore {
            for index in 0..<ComposerDraftStore.maxDraftCount {
                ComposerDraftStore.save(
                    "d\(index)",
                    for: .location(geohash: String(format: "gh%04d", index))
                )
            }
            ComposerDraftStore.save("newest", for: .mesh)
            #expect(ComposerDraftStore.countForTesting() == ComposerDraftStore.maxDraftCount)
            #expect(ComposerDraftStore.load(.mesh) == "newest")
        }
    }

    @Test func clearingDraftRemovesKeySoItDoesNotResurrect() throws {
        try withCleanStore {
            ComposerDraftStore.save("old text", for: .mesh)
            ComposerDraftStore.save("", for: .mesh)
            #expect(ComposerDraftStore.load(.mesh).isEmpty)
        }
    }
}
