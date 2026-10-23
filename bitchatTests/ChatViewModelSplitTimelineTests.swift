//
// ChatViewModelSplitTimelineTests.swift
// bitchatTests
//
// Two public timelines can be on screen at once: the split layout pins
// #mesh beside the selected geohash. Arrivals for both are batched, the
// content window is per conversation, and live voice follows what is on
// screen. End to end through `ChatViewModel`, the store, and the pipeline.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@MainActor
private func makeSplitTimelineViewModel() -> ChatViewModel {
    let keychain = MockKeychain()
    // A private location manager: the shared one is switched by other suites
    // running in parallel, and a switch resets the channel under the test.
    let locationSuite = "ChatViewModelSplitTimelineTests.\(UUID().uuidString)"
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

private let selectedGeohash = GeohashChannel(level: .city, geohash: "u4pru")

@MainActor
private func makeGeohashArrival(id: String, content: String) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "carol#cdcd",
        content: content,
        timestamp: Date(),
        isRelay: false,
        senderPeerID: PeerID(nostr: String(repeating: "cd", count: 32))
    )
}

#if os(iOS)
@MainActor
private func makeMeshArrival(id: String, content: String) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "dave",
        content: content,
        timestamp: Date(),
        isRelay: false,
        senderPeerID: PeerID(str: "1122334455667788")
    )
}
#endif

@Suite("ChatViewModel split timelines")
@MainActor
struct ChatViewModelSplitTimelineTests {
    /// Our own #mesh wave must not swallow the same wave arriving in the
    /// selected geohash a moment later: the echo's content-window marker
    /// belongs to #mesh only.
    @Test("a #mesh echo does not drop the same text arriving in the selected geohash")
    func meshEcho_doesNotDropSameTextInSelectedGeohash() {
        let viewModel = makeSplitTimelineViewModel()
        viewModel.activeChannel = .location(selectedGeohash)
        viewModel.currentGeohash = selectedGeohash.geohash

        viewModel.sendMeshWave()
        #expect(viewModel.publicMessages(for: .mesh).map(\.content) == ["👋"])

        viewModel.handlePublicMessage(makeGeohashArrival(id: "geo-wave", content: "👋"), powBits: 0)
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(viewModel.publicConversationContainsMessage(withID: "geo-wave", in: .geohash(selectedGeohash.geohash)))
    }

    #if os(iOS)
    @Test("pinned #mesh beside a geohash: both timelines batch and keep the same text")
    func pinnedMesh_batchesBothTimelinesAndKeepsSameText() {
        let viewModel = makeSplitTimelineViewModel()
        viewModel.activeChannel = .location(selectedGeohash)
        viewModel.currentGeohash = selectedGeohash.geohash
        viewModel.conversations.setMeshPinnedOnScreen(true)

        viewModel.handlePublicMessage(makeMeshArrival(id: "mesh-gm", content: "gm"))
        viewModel.handlePublicMessage(makeGeohashArrival(id: "geo-gm", content: "gm"), powBits: 0)

        // Batched: nothing lands before the pipeline flush.
        #expect(!viewModel.publicConversationContainsMessage(withID: "mesh-gm", in: .mesh))
        #expect(!viewModel.publicConversationContainsMessage(withID: "geo-gm", in: .geohash(selectedGeohash.geohash)))

        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(viewModel.publicConversationContainsMessage(withID: "mesh-gm", in: .mesh))
        #expect(viewModel.publicConversationContainsMessage(withID: "geo-gm", in: .geohash(selectedGeohash.geohash)))
    }

    @Test("live mesh bursts autoplay while #mesh is pinned on screen, not under a private chat")
    func liveVoiceAutoplay_followsPinnedMesh() {
        let viewModel = makeSplitTimelineViewModel()
        viewModel.activeChannel = .location(selectedGeohash)
        #expect(!viewModel.isViewingPublicMeshTimeline)

        viewModel.conversations.setMeshPinnedOnScreen(true)
        #expect(viewModel.isViewingPublicMeshTimeline)

        viewModel.selectedPrivateChatPeer = PeerID(str: "0102030405060708")
        #expect(!viewModel.isViewingPublicMeshTimeline)

        viewModel.selectedPrivateChatPeer = nil
        viewModel.conversations.setMeshPinnedOnScreen(false)
        viewModel.activeChannel = .mesh
        #expect(viewModel.isViewingPublicMeshTimeline)
    }
    #endif
}
