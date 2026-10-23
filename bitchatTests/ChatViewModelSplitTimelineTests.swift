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

/// The same hug twice, as a bridge alias and as the authenticated radio
/// packet: an emote-shaped text arrives as a system line that keeps its
/// sender.
@MainActor
private func makeHugPair(timestamp: Date) -> (alias: BitchatMessage, radio: BitchatMessage) {
    let content = "* 🫂 remote hugs alice *"
    let alias = BitchatMessage(
        id: "bridge-hug",
        sender: "remote#beef",
        content: content,
        timestamp: timestamp,
        isRelay: false,
        senderPeerID: PeerID(bridge: String(repeating: "be", count: 32)),
        isBridged: true
    )
    let radio = BitchatMessage(
        id: "radio-hug",
        sender: "remote",
        content: content,
        timestamp: timestamp,
        isRelay: false,
        senderPeerID: PeerID(str: "1122334455667788")
    )
    return (alias, radio)
}

@Suite("ChatViewModel split timelines")
@MainActor
struct ChatViewModelSplitTimelineTests {
    /// A bridged hug arrives as a system line and lands on the selected
    /// geohash (compact). Replacing it with the authenticated radio copy must
    /// forget the alias's content marker in that geohash, or the radio copy
    /// is dropped as its duplicate.
    @Test("a bridged action line's alias, replaced in the selected geohash, lets the radio copy through")
    func bridgedActionLineAlias_forgetsItsMarkerWhereItLanded() {
        let viewModel = makeSplitTimelineViewModel()
        let geohash = ConversationID.geohash(selectedGeohash.geohash)
        viewModel.activeChannel = .location(selectedGeohash)
        viewModel.currentGeohash = selectedGeohash.geohash
        let hug = makeHugPair(timestamp: Date())

        viewModel.handlePublicMessage(hug.alias)
        viewModel.publicMessagePipeline.flushIfNeeded()
        #expect(viewModel.publicConversationContainsMessage(withID: hug.alias.id, in: geohash))

        viewModel.removeBridgeInjectedPublicMessage(withID: hug.alias.id)
        viewModel.handlePublicMessage(hug.radio)
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(!viewModel.publicConversationContainsMessage(withID: hug.alias.id, in: geohash))
        #expect(viewModel.publicConversationContainsMessage(withID: hug.radio.id, in: geohash))
    }

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

    /// An arrival still waiting for the batched flush when panic runs is
    /// wiped with the store: the flush after the wipe must not commit it into
    /// the fresh timeline.
    @Test("panic drops arrivals still waiting for the batched flush")
    func panic_dropsArrivalsWaitingForTheFlush() {
        let viewModel = makeSplitTimelineViewModel()
        viewModel.handlePublicMessage(makeMeshArrival(id: "mesh-pre-panic", content: "before the wipe"))
        #expect(viewModel.publicMessagePipeline.containsMessage(withID: "mesh-pre-panic"))

        viewModel.panicClearAllData()
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(!viewModel.publicMessagePipeline.containsMessage(withID: "mesh-pre-panic"))
        #expect(!viewModel.publicConversationContainsMessage(withID: "mesh-pre-panic", in: .mesh))
    }

    #if os(iOS)
    /// The split layout batches both timelines, so panic must empty both,
    /// the pinned #mesh pane's model included.
    @Test("panic empties both on-screen timelines of arrivals waiting for the flush")
    func panic_emptiesBothPinnedTimelines() {
        let viewModel = makeSplitTimelineViewModel()
        let geohash = ConversationID.geohash(selectedGeohash.geohash)
        viewModel.activeChannel = .location(selectedGeohash)
        viewModel.currentGeohash = selectedGeohash.geohash
        viewModel.conversations.setMeshPinnedOnScreen(true)
        let meshPane = PublicChatModel(conversations: viewModel.conversations, pinnedTo: .mesh)

        viewModel.handlePublicMessage(makeMeshArrival(id: "mesh-pre-panic", content: "mesh before"))
        viewModel.handlePublicMessage(makeGeohashArrival(id: "geo-pre-panic", content: "geo before"), powBits: 0)
        #expect(viewModel.publicMessagePipeline.containsMessage(withID: "mesh-pre-panic"))
        #expect(viewModel.publicMessagePipeline.containsMessage(withID: "geo-pre-panic"))

        viewModel.panicClearAllData()
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(!viewModel.publicConversationContainsMessage(withID: "mesh-pre-panic", in: .mesh))
        #expect(!viewModel.publicConversationContainsMessage(withID: "geo-pre-panic", in: geohash))
        #expect(!meshPane.messages.contains { $0.id == "mesh-pre-panic" })
    }

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

    /// Beside the pinned #mesh, a mesh peer's hug (bridged or by radio)
    /// lands in #mesh, where it was said, not in the selected geohash; the
    /// alias's replacement still lets the radio copy through.
    @Test("pinned #mesh: a mesh peer's action line lands in #mesh, not the selected geohash")
    func pinnedMesh_meshPeerActionLineLandsInMesh() {
        let viewModel = makeSplitTimelineViewModel()
        let geohash = ConversationID.geohash(selectedGeohash.geohash)
        viewModel.activeChannel = .location(selectedGeohash)
        viewModel.currentGeohash = selectedGeohash.geohash
        viewModel.conversations.setMeshPinnedOnScreen(true)
        let hug = makeHugPair(timestamp: Date())

        viewModel.handlePublicMessage(hug.alias)
        viewModel.publicMessagePipeline.flushIfNeeded()
        #expect(viewModel.publicConversationContainsMessage(withID: hug.alias.id, in: .mesh))
        #expect(!viewModel.publicConversationContainsMessage(withID: hug.alias.id, in: geohash))

        viewModel.removeBridgeInjectedPublicMessage(withID: hug.alias.id)
        viewModel.handlePublicMessage(hug.radio)
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(viewModel.publicMessages(for: .mesh).map(\.id) == [hug.radio.id])
        #expect(viewModel.publicMessages(for: .location(selectedGeohash)).isEmpty)
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
