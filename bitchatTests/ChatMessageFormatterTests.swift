//
// ChatMessageFormatterTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

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
