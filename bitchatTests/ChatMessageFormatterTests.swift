//
// ChatMessageFormatterTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import SwiftUI
import Testing
@testable import bitchat

/// Counts full roster scans: `GeohashParticipantTracker.getVisiblePeople()`
/// asks its context whether each participant is blocked exactly once.
@MainActor
private final class RosterScanCountingContext: GeohashParticipantContext {
    private weak var base: ChatViewModel?
    private(set) var isBlockedCalls = 0

    init(base: ChatViewModel) {
        self.base = base
    }

    func displayNameForPubkey(_ pubkeyHex: String) -> String {
        base?.displayNameForPubkey(pubkeyHex) ?? "anon#\(pubkeyHex.suffix(4))"
    }

    func isBlocked(_ pubkeyHexLowercased: String) -> Bool {
        isBlockedCalls += 1
        return base?.isBlocked(pubkeyHexLowercased) ?? false
    }
}

@MainActor
struct ChatMessageFormatterTests {
    private let geohash = "u4pruyd"

    /// One people-sheet render asks for a color per row. Each lookup used to
    /// rebuild the palette from a fresh roster scan, making the sheet O(N²):
    /// 60 rows cost 3,600 block checks before a single row was laid out.
    @Test func geohashColorLookupsDoNotRescanTheRoster() {
        let viewModel = makeViewModel()
        let pubkeys = seedParticipants(60, in: viewModel)
        let counter = RosterScanCountingContext(base: viewModel)
        viewModel.participantTracker.configure(context: counter)
        defer { viewModel.participantTracker.configure(context: viewModel) }

        let first = pubkeys.map { viewModel.colorForNostrPubkey($0, isDark: true) }
        let second = pubkeys.map { viewModel.colorForNostrPubkey($0, isDark: true) }

        #expect(counter.isBlockedCalls == 0)
        #expect(first == second)
    }

    /// The palette follows roster membership: a newcomer gets a palette slot
    /// (not the hash fallback) and people already on screen keep theirs.
    @Test func paletteTracksMembershipChangesWithoutRecoloringExistingRows() {
        let viewModel = makeViewModel()
        let pubkeys = seedParticipants(10, in: viewModel)
        let before = pubkeys.map { viewModel.colorForNostrPubkey($0, isDark: true) }

        let newcomer = String(format: "%064x", 0xfeed)
        viewModel.participantTracker.recordParticipant(pubkeyHex: newcomer, geohash: geohash)

        // Palette colors use the configured saturation, which the hash
        // fallback can never produce exactly, so inequality proves a slot.
        #expect(viewModel.colorForNostrPubkey(newcomer, isDark: true) != Color(peerSeed: "nostr:" + newcomer, isDark: true))
        #expect(pubkeys.map { viewModel.colorForNostrPubkey($0, isDark: true) } == before)
    }

    /// Mesh rows follow the same rule: a newcomer gets a palette slot, not
    /// the hash fallback, and people already on screen keep their colors.
    @Test func meshPaletteTracksMembershipChangesWithoutRecoloringExistingRows() {
        let viewModel = makeViewModel()
        let peerIDs = (1...10).map { PeerID(str: String(format: "%016llx", UInt64($0))) }
        viewModel.allPeers = peerIDs.map { BitchatPeer(peerID: $0, noisePublicKey: Data(), nickname: $0.id) }
        let before = peerIDs.map { viewModel.colorForMeshPeer(id: $0, isDark: true) }

        let newcomer = PeerID(str: String(format: "%016llx", UInt64(0xfeed)))
        viewModel.allPeers.append(BitchatPeer(peerID: newcomer, noisePublicKey: Data(), nickname: "newcomer"))

        #expect(viewModel.colorForMeshPeer(id: newcomer, isDark: true) != Color(peerSeed: newcomer.id, isDark: true))
        #expect(peerIDs.map { viewModel.colorForMeshPeer(id: $0, isDark: true) } == before)
    }

    /// The palette is rebuilt from `allPeers` only when its ID set changes;
    /// reorders and attribute changes (a rename, a connection flip) don't.
    @Test func allPeersMembershipRevisionMovesOnlyWithMembership() {
        let viewModel = makeViewModel()
        let alice = BitchatPeer(peerID: PeerID(str: "1111111111111111"), noisePublicKey: Data(), nickname: "alice")
        let bob = BitchatPeer(peerID: PeerID(str: "2222222222222222"), noisePublicKey: Data(), nickname: "bob")
        viewModel.allPeers = [alice, bob]
        let initial = viewModel.allPeersMembershipRevision

        viewModel.allPeers = [bob, alice]
        let renamed = BitchatPeer(peerID: alice.peerID, noisePublicKey: Data(), nickname: "alice2", isConnected: true)
        viewModel.allPeers = [renamed, bob]
        #expect(viewModel.allPeersMembershipRevision == initial)

        viewModel.allPeers = [renamed]
        #expect(viewModel.allPeersMembershipRevision != initial)
        let afterRemoval = viewModel.allPeersMembershipRevision
        viewModel.allPeers = [renamed, bob]
        #expect(viewModel.allPeersMembershipRevision != afterRemoval)
    }

    // MARK: - Helpers

    private func makeViewModel() -> ChatViewModel {
        let keychain = MockKeychain()
        // A private location manager: the shared one is switched by other
        // suites running in parallel, and a switch resets the roster.
        let locationSuite = "ChatMessageFormatterTests.\(UUID().uuidString)"
        let locationStorage = UserDefaults(suiteName: locationSuite) ?? .standard
        locationStorage.removePersistentDomain(forName: locationSuite)
        return ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            transport: MockTransport(),
            locationManager: LocationChannelManager(storage: locationStorage)
        )
    }

    private func seedParticipants(_ count: Int, in viewModel: ChatViewModel) -> [String] {
        let tracker = viewModel.participantTracker
        tracker.setActiveGeohash(geohash)
        let pubkeys = (1...count).map { String(format: "%064x", $0) }
        for pubkey in pubkeys {
            tracker.recordParticipant(pubkeyHex: pubkey, geohash: geohash)
        }
        return pubkeys
    }
}
