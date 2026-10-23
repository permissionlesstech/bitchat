//
// PublicChatModelTests.swift
// bitchatTests
//
// A public timeline model either follows the store's active channel (the
// compact timeline, the split layout's trailing pane) or is pinned to one
// channel (the split layout's leading #mesh pane). Each observes only its own
// conversation, and both retarget when panic drops the conversation objects.
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
private func makeTimelineMessage(id: String, timestamp: TimeInterval = 0) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "alice",
        content: "message \(id)",
        timestamp: Date(timeIntervalSince1970: timestamp),
        isRelay: false,
        senderPeerID: PeerID(str: "aabbccddeeff0011")
    )
}

private let geohashChannel = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pru"))
private let otherGeohashChannel = ChannelID.location(GeohashChannel(level: .neighborhood, geohash: "u4pruy"))

@Suite("PublicChatModel")
@MainActor
struct PublicChatModelTests {
    @Test("a pinned model ignores selection changes")
    func pinnedModel_ignoresSelectionChanges() {
        let store = ConversationStore()
        store.setActiveChannel(geohashChannel)
        store.append(makeTimelineMessage(id: "mesh-1"), to: .mesh)
        let model = PublicChatModel(conversations: store, pinnedTo: .mesh)
        #expect(model.channel == .mesh)
        #expect(model.messages.map(\.id) == ["mesh-1"])

        var emissions = 0
        let cancellable = model.objectWillChange.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        store.setActiveChannel(otherGeohashChannel)
        store.setActiveChannel(.mesh)
        store.setActiveChannel(geohashChannel)
        store.setSelectedPrivatePeer(PeerID(str: "0102030405060708"))

        #expect(emissions == 0)
        #expect(model.channel == .mesh)
        #expect(model.messages.map(\.id) == ["mesh-1"])
    }

    @Test("a pinned #mesh model shows mesh appends and ignores the selected geohash's")
    func pinnedModel_isolatesItsConversation() {
        let store = ConversationStore()
        store.setActiveChannel(geohashChannel)
        let meshPane = PublicChatModel(conversations: store, pinnedTo: .mesh)
        let selected = PublicChatModel(conversations: store)
        #expect(selected.channel == geohashChannel)

        var meshEmissions = 0
        var selectedEmissions = 0
        let meshCancellable = meshPane.objectWillChange.sink { _ in meshEmissions += 1 }
        let selectedCancellable = selected.objectWillChange.sink { _ in selectedEmissions += 1 }
        defer {
            meshCancellable.cancel()
            selectedCancellable.cancel()
        }

        store.append(makeTimelineMessage(id: "geo-1"), to: .geohash("u4pru"))
        #expect(meshEmissions == 0)
        #expect(selectedEmissions >= 1)
        #expect(meshPane.messages.isEmpty)
        #expect(selected.messages.map(\.id) == ["geo-1"])

        let selectedAfterGeohash = selectedEmissions
        store.append(makeTimelineMessage(id: "mesh-1"), to: .mesh)
        #expect(meshEmissions >= 1)
        #expect(selectedEmissions == selectedAfterGeohash)
        #expect(meshPane.messages.map(\.id) == ["mesh-1"])
        #expect(selected.messages.map(\.id) == ["geo-1"])
    }

    @Test("a following model switches its channel and that channel's messages together")
    func followingModel_switchesChannelAndMessagesTogether() {
        let store = ConversationStore()
        store.append(makeTimelineMessage(id: "mesh-1"), to: .mesh)
        store.append(makeTimelineMessage(id: "geo-1"), to: .geohash("u4pru"))
        let model = PublicChatModel(conversations: store)
        #expect(model.channel == .mesh)
        #expect(model.messages.map(\.id) == ["mesh-1"])

        store.setActiveChannel(geohashChannel)
        #expect(model.channel == geohashChannel)
        #expect(model.messages.map(\.id) == ["geo-1"])

        store.setActiveChannel(.mesh)
        #expect(model.channel == .mesh)
        #expect(model.messages.map(\.id) == ["mesh-1"])
    }

    @Test("panic: a pinned #mesh model drops the wiped timeline and shows what comes after")
    func pinnedModel_retargetsWhenPanicRemovesItsConversation() {
        let store = ConversationStore()
        store.setActiveChannel(geohashChannel)
        let model = PublicChatModel(conversations: store, pinnedTo: .mesh)
        store.append(makeTimelineMessage(id: "before-wipe"), to: .mesh)
        #expect(model.messages.map(\.id) == ["before-wipe"])

        store.clearAll()

        #expect(model.channel == .mesh)
        #expect(model.messages.isEmpty)
        store.append(makeTimelineMessage(id: "after-wipe", timestamp: 1), to: .mesh)
        #expect(model.messages.map(\.id) == ["after-wipe"])
    }

    @Test("panic: a following model drops the wiped timeline and shows what comes after")
    func followingModel_retargetsWhenPanicRemovesItsConversation() {
        let store = ConversationStore()
        store.setActiveChannel(geohashChannel)
        let model = PublicChatModel(conversations: store)
        store.append(makeTimelineMessage(id: "before-wipe"), to: .geohash("u4pru"))
        #expect(model.messages.map(\.id) == ["before-wipe"])

        store.clearAll()

        #expect(model.messages.isEmpty)
        store.append(makeTimelineMessage(id: "after-wipe", timestamp: 1), to: .geohash("u4pru"))
        #expect(model.messages.map(\.id) == ["after-wipe"])

        // Panic then returns the selection to #mesh.
        store.setActiveChannel(.mesh)
        #expect(model.channel == .mesh)
        #expect(model.messages.isEmpty)
    }
}
