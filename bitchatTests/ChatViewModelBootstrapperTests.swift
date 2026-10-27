//
// ChatViewModelBootstrapperTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

@MainActor
struct ChatViewModelBootstrapperTests {

    /// Nicknames name the authors of messages on screen, including replayed
    /// history from people no longer present. Roster publishes prune presence
    /// state (teleport markers) but must keep those names resolvable for
    /// /msg, /block, autocomplete and DM headers.
    @Test func rosterPublishesKeepNicknamesOfAuthorsWhoAreNotPresent() async {
        let viewModel = makeViewModel()
        // The initial (mesh) channel arrives asynchronously and resets the
        // tracker; let startup settle first.
        await drainMainQueue()

        let geohash = "u4pruyd"
        viewModel.currentGeohash = geohash
        viewModel.participantTracker.setActiveGeohash(geohash)
        let author = String(repeating: "a", count: 64)
        // A replayed message from ten minutes ago: named, but not present.
        viewModel.setGeoNickname("troll", forPubkey: author)
        viewModel.participantTracker.recordParticipant(pubkeyHex: author, seenAt: Date().addingTimeInterval(-600))

        // Someone else arrives, so the roster publishes and the prune runs.
        viewModel.participantTracker.recordParticipant(pubkeyHex: String(repeating: "b", count: 64))
        await drainMainQueue()

        #expect(viewModel.geoNicknames[author] == "troll")
    }

    /// Teleport markers follow the roster, which prunes them only as it
    /// changes. A teleport tag replayed from before the activity window must
    /// not mark its absent author: the marker would wait for them, and when
    /// they came back, no longer teleported, they'd still be badged.
    @Test func expiredReplayedTeleportTagDoesNotFollowItsAuthorBackIn() async throws {
        let viewModel = makeViewModel()
        await drainMainQueue()

        let geohash = "u4pruyd"
        viewModel.currentGeohash = geohash
        viewModel.participantTracker.setActiveGeohash(geohash)
        let sender = try NostrIdentity.generate()
        // Replayed on join: a message they sent teleported, ten minutes ago.
        let replayed = try NostrEvent(
            pubkey: sender.publicKeyHex,
            createdAt: Date().addingTimeInterval(-600),
            kind: .ephemeralEvent,
            tags: [["g", geohash], ["t", "teleport"]],
            content: "from earlier"
        ).sign(with: sender.schnorrSigningKey())
        viewModel.nostrCoordinator.inbound.handleNostrEvent(replayed, isHistoryReplay: true)
        await drainMainQueue()

        // They come back, live and local.
        let live = try NostrProtocol.createEphemeralGeohashEvent(
            content: "back",
            geohash: geohash,
            senderIdentity: sender
        )
        viewModel.nostrCoordinator.inbound.handleNostrEvent(live)
        await drainMainQueue()

        let key = sender.publicKeyHex.lowercased()
        #expect(viewModel.participantTracker.visiblePeople.map(\.id) == [key])
        #expect(!viewModel.teleportedGeo.contains(key))
    }

    /// A teleported writer stays in the roster for the hour, but their badge
    /// follows the presence window: once they go quiet past it, they're no
    /// longer shown as teleported.
    @Test func teleportBadgeLapsesWithPresenceNotTheChatHour() async throws {
        let viewModel = makeViewModel()
        await drainMainQueue()

        let geohash = "9q8yy"
        viewModel.currentGeohash = geohash
        viewModel.participantTracker.setActiveGeohash(geohash)
        let key = String(repeating: "c", count: 64)
        // They wrote, teleported, just inside the presence window.
        viewModel.participantTracker.recordParticipant(
            pubkeyHex: key,
            seenAt: Date().addingTimeInterval(-TransportConfig.uiRecentCutoffFiveMinutesSeconds + 0.5),
            chatEventID: "m1"
        )
        viewModel.locationPresenceStore.markTeleported(key)
        await drainMainQueue()
        #expect(viewModel.teleportedGeo.contains(key))

        try await Task.sleep(nanoseconds: 700_000_000)
        viewModel.participantTracker.refresh()
        await drainMainQueue()

        #expect(viewModel.participantTracker.visiblePeople.map(\.id) == [key])
        #expect(!viewModel.teleportedGeo.contains(key))
    }

    /// A private location manager: the shared one is switched by other
    /// suites running in parallel, and a switch clears nicknames and
    /// teleport markers.
    private func makeViewModel() -> ChatViewModel {
        let keychain = MockKeychain()
        let locationSuite = "ChatViewModelBootstrapperTests.\(UUID().uuidString)"
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

    private func drainMainQueue() async {
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
