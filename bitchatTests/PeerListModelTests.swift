//
// PeerListModelTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Combine
import Foundation
import Testing
@testable import bitchat

@MainActor
struct PeerListModelTests {

    /// Every @Published write re-renders every view observing the model
    /// (root view, header, open people sheet), so a refresh trigger that
    /// leaves the rows as they were must not write anything.
    @Test func refreshThatChangesNothingDoesNotRepublish() async {
        let viewModel = makeViewModel()
        let model = PeerListModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(manager: makeLocationManager())
        )
        await drainMainQueue()

        var changes = 0
        let cancellable = model.objectWillChange.sink { _ in changes += 1 }
        let roster = viewModel.allPeers
        for _ in 0..<5 {
            NotificationCenter.default.post(name: Notification.Name("peerStatusUpdated"), object: nil)
            // Every mesh snapshot republishes the roster, usually unchanged.
            viewModel.allPeers = roster
        }
        await drainMainQueue()

        #expect(changes == 0)
        _ = cancellable
    }

    /// `BitchatPeer.==` compares only peer IDs, so a roster in which someone
    /// changed name, connection or favorite compares equal to the previous
    /// one. Their row must still be rebuilt from it.
    @Test func rosterChangeWithTheSameIDsUpdatesTheRow() async throws {
        let transport = MockTransport()
        let viewModel = makeViewModel(transport: transport)
        let model = PeerListModel(
            chatViewModel: viewModel,
            conversations: viewModel.conversations,
            locationChannelsModel: LocationChannelsModel(manager: makeLocationManager())
        )
        let peerID = PeerID(str: "00000000000000c7")
        let noiseKey = Data(repeating: 0xC7, count: 32)
        func snapshots(nickname: String) -> [TransportPeerSnapshot] {
            [TransportPeerSnapshot(
                peerID: peerID,
                nickname: nickname,
                isConnected: true,
                noisePublicKey: noiseKey,
                lastSeen: Date()
            )]
        }

        // Through the transport rather than assigning `viewModel.allPeers`:
        // anything else that rebuilds the roster (a favorites change from a
        // parallel test) then yields these same peers.
        transport.updatePeerSnapshots(snapshots(nickname: "alice"))
        let listed = await TestHelpers.waitUntil({
            model.meshRows.contains { $0.peerID == peerID && $0.displayName == "alice" }
        }, timeout: TestConstants.settleTimeout)
        try #require(listed)

        // Same peer, same place in the roster, new name.
        transport.updatePeerSnapshots(snapshots(nickname: "alicia"))
        let renamed = await TestHelpers.waitUntil({
            model.meshRows.contains { $0.peerID == peerID && $0.displayName == "alicia" }
        }, timeout: TestConstants.settleTimeout)
        #expect(renamed)
    }

    // MARK: - Helpers

    private func makeViewModel(transport: MockTransport = MockTransport()) -> ChatViewModel {
        let keychain = MockKeychain()
        return ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            transport: transport,
            locationManager: makeLocationManager()
        )
    }

    private func makeLocationManager() -> LocationChannelManager {
        let suiteName = "PeerListModelTests.\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName) ?? .standard
        storage.removePersistentDomain(forName: suiteName)
        return LocationChannelManager(storage: storage)
    }

    /// The model's triggers hop to the main queue and then coalesce onto one
    /// more hop, so let a few main-queue turns run.
    private func drainMainQueue() async {
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
