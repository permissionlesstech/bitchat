//
// PeerListModelTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

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
        for _ in 0..<5 {
            NotificationCenter.default.post(name: Notification.Name("peerStatusUpdated"), object: nil)
        }
        await drainMainQueue()

        #expect(changes == 0)
        _ = cancellable
    }

    // MARK: - Helpers

    private func makeViewModel() -> ChatViewModel {
        let keychain = MockKeychain()
        return ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            transport: MockTransport(),
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
