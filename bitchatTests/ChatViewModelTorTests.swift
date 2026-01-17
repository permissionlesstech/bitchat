//
// ChatViewModelTorTests.swift
// bitchatTests
//
// Tests for ChatViewModel+Tor.swift Tor lifecycle notification handlers.
//

import Testing
import Foundation
@testable import bitchat

// MARK: - Test Helpers

@MainActor
private func makeTestableViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport
    )

    return (viewModel, transport)
}

// MARK: - Tor Notification Handler Tests

struct ChatViewModelTorTests {

    // MARK: - handleTorWillStart Tests

    @Test @MainActor
    func handleTorWillStart_whenEnforced_setsAnnouncedFlag() async {
        let (viewModel, _) = makeTestableViewModel()

        // Precondition: flag should start false
        #expect(!viewModel.torStatusAnnounced)

        // Action: simulate Tor starting notification
        viewModel.handleTorWillStart()

        // Wait for Task to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: flag should be set (torEnforced is true in tests)
        #expect(viewModel.torStatusAnnounced)
    }

    @Test @MainActor
    func handleTorWillStart_whenAlreadyAnnounced_doesNotDuplicate() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: pre-set the flag
        viewModel.torStatusAnnounced = true

        // Switch to a geohash channel so messages would be visible
        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: "u4pruydq")))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let initialMessageCount = viewModel.messages.count

        // Action: call handler again
        viewModel.handleTorWillStart()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: no new message added (flag was already true)
        #expect(viewModel.messages.count == initialMessageCount)
    }

    // MARK: - handleTorWillRestart Tests

    @Test @MainActor
    func handleTorWillRestart_setsPendingFlag() async {
        let (viewModel, _) = makeTestableViewModel()

        // Precondition
        #expect(!viewModel.torRestartPending)

        // Action
        viewModel.handleTorWillRestart()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert
        #expect(viewModel.torRestartPending)
    }

    @Test @MainActor
    func handleTorWillRestart_setsFlag_regardlessOfChannel() async {
        let (viewModel, _) = makeTestableViewModel()

        // Action: call handler (works regardless of channel)
        viewModel.handleTorWillRestart()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: flag should be set
        #expect(viewModel.torRestartPending)
    }

    // MARK: - handleTorDidBecomeReady Tests

    @Test @MainActor
    func handleTorDidBecomeReady_afterRestart_clearsPendingFlag() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: simulate restart pending state
        viewModel.torRestartPending = true

        // Action
        viewModel.handleTorDidBecomeReady()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: should clear pending flag
        #expect(!viewModel.torRestartPending)
    }

    @Test @MainActor
    func handleTorDidBecomeReady_initialStart_setsAnnouncedFlag() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: not restarting, but initial ready not announced yet
        viewModel.torRestartPending = false
        viewModel.torInitialReadyAnnounced = false

        // Action
        viewModel.handleTorDidBecomeReady()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: should set flag (torEnforced is true in tests)
        #expect(viewModel.torInitialReadyAnnounced)
    }

    @Test @MainActor
    func handleTorDidBecomeReady_alreadyAnnounced_noDuplicate() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: already announced initial ready
        viewModel.torRestartPending = false
        viewModel.torInitialReadyAnnounced = true
        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: "u4pruydq")))
        try? await Task.sleep(nanoseconds: 100_000_000)

        let initialMessageCount = viewModel.messages.count

        // Action
        viewModel.handleTorDidBecomeReady()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: no new message
        #expect(viewModel.messages.count == initialMessageCount)
    }

    // MARK: - handleTorPreferenceChanged Tests

    @Test @MainActor
    func handleTorPreferenceChanged_resetsAllFlags() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: set all flags
        viewModel.torStatusAnnounced = true
        viewModel.torInitialReadyAnnounced = true
        viewModel.torRestartPending = true

        // Action
        viewModel.handleTorPreferenceChanged(Notification(name: .init("test")))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert: all flags reset
        #expect(!viewModel.torStatusAnnounced)
        #expect(!viewModel.torInitialReadyAnnounced)
        #expect(!viewModel.torRestartPending)
    }
}
