import Foundation
import Testing
@testable import bitchat

@MainActor
@Suite("PublicTimelineStore Tests")
struct PublicTimelineStoreTests {

    @Test("Mesh timeline deduplicates and trims to cap")
    func meshTimelineDeduplicatesAndTrims() {
        let store = PublicTimelineStore(meshCap: 2, geohashCap: 2)
        let first = TestHelpers.createTestMessage(content: "one")
        let second = TestHelpers.createTestMessage(content: "two")
        let third = TestHelpers.createTestMessage(content: "three")

        store.append(first, to: .mesh)
        store.append(second, to: .mesh)
        store.append(first, to: .mesh)
        store.append(third, to: .mesh)

        let messages = store.messages(for: .mesh)
        #expect(messages.map(\.content) == ["two", "three"])
    }

    @Test("Geohash appendIfAbsent remove and clear work together")
    func geohashStoreSupportsAppendRemoveAndClear() {
        let store = PublicTimelineStore(meshCap: 2, geohashCap: 3)
        let geohash = "u4pruydq"
        let channel = ChannelID.location(GeohashChannel(level: .city, geohash: geohash))
        let first = TestHelpers.createTestMessage(content: "geo one")
        let second = TestHelpers.createTestMessage(content: "geo two")

        let didAppendFirst = store.appendIfAbsent(first, toGeohash: geohash)
        let didAppendDuplicate = store.appendIfAbsent(first, toGeohash: geohash)

        #expect(didAppendFirst)
        #expect(!didAppendDuplicate)
        store.append(second, toGeohash: geohash)
        let removed = store.removeMessage(withID: first.id)

        #expect(removed?.id == first.id)
        #expect(store.messages(for: channel).map(\.content) == ["geo two"])

        store.clear(channel: channel)
        #expect(store.messages(for: channel).isEmpty)
    }

    @Test("Clearing the active channel also clears visible messages")
    func clearActiveChannelClearsVisibleMessages() {
        let store = PublicTimelineStore(meshCap: 3, geohashCap: 3)
        let message = TestHelpers.createTestMessage(content: "mesh")

        store.append(message, to: .mesh)
        store.activate(channel: .mesh)
        #expect(store.visibleMessages.map(\.content) == ["mesh"])

        store.clear(channel: .mesh)
        #expect(store.messages(for: .mesh).isEmpty)
        #expect(store.visibleMessages.isEmpty)
    }

    @Test("Mutate geohash updates stored messages in place")
    func mutateGeohashAppliesTransformation() {
        let store = PublicTimelineStore(meshCap: 2, geohashCap: 3)
        let geohash = "u4pruydq"
        let channel = ChannelID.location(GeohashChannel(level: .city, geohash: geohash))
        let first = TestHelpers.createTestMessage(content: "geo one")

        store.append(first, toGeohash: geohash)
        store.mutateGeohash(geohash) { timeline in
            timeline.append(TestHelpers.createTestMessage(content: "geo two"))
        }

        #expect(store.messages(for: channel).map(\.content) == ["geo one", "geo two"])
    }

    @Test("Queued geohash system messages drain once")
    func pendingGeohashSystemMessagesDrainOnce() {
        let store = PublicTimelineStore(meshCap: 1, geohashCap: 1)

        store.queueGeohashSystemMessage("first")
        store.queueGeohashSystemMessage("second")

        #expect(store.drainPendingGeohashSystemMessages() == ["first", "second"])
        #expect(store.drainPendingGeohashSystemMessages().isEmpty)
    }

    @Test("Activating a channel refreshes visible messages from that timeline")
    func activateChannelRefreshesVisibleMessages() {
        let store = PublicTimelineStore(meshCap: 3, geohashCap: 3)
        let geohash = "u4pruydq"
        let channel = ChannelID.location(GeohashChannel(level: .city, geohash: geohash))

        store.append(TestHelpers.createTestMessage(content: "mesh"), to: .mesh)
        store.append(TestHelpers.createTestMessage(content: "geo"), toGeohash: geohash)

        store.activate(channel: .mesh)
        #expect(store.visibleMessages.map(\.content) == ["mesh"])

        store.activate(channel: channel)
        #expect(store.visibleMessages.map(\.content) == ["geo"])
    }

    @Test("Updating a stored message also updates the visible timeline")
    func updateMessageSynchronizesStoredAndVisibleTimelines() {
        let store = PublicTimelineStore(meshCap: 3, geohashCap: 3)
        let deliveredAt = Date()
        let message = BitchatMessage(
            sender: "alice",
            content: "pending",
            timestamp: Date(),
            isRelay: false,
            deliveryStatus: .sending
        )

        store.append(message, to: .mesh)
        store.activate(channel: .mesh)

        let didUpdate = store.updateMessage(id: message.id) {
            $0.withDeliveryStatus(.delivered(to: "bob", at: deliveredAt))
        }

        #expect(didUpdate)
        #expect(store.messages(for: .mesh).first?.deliveryStatus == .delivered(to: "bob", at: deliveredAt))
        #expect(store.visibleMessages.first?.deliveryStatus == .delivered(to: "bob", at: deliveredAt))
    }

    @Test("Clearing all timelines resets visible and pending state")
    func clearAllResetsAllBackings() {
        let store = PublicTimelineStore(meshCap: 3, geohashCap: 3)
        let geohash = "u4pruydq"
        let channel = ChannelID.location(GeohashChannel(level: .city, geohash: geohash))

        store.append(TestHelpers.createTestMessage(content: "mesh"), to: .mesh)
        store.append(TestHelpers.createTestMessage(content: "geo"), toGeohash: geohash)
        store.queueGeohashSystemMessage("queued")
        store.activate(channel: channel)

        store.clearAll()

        #expect(store.messages(for: .mesh).isEmpty)
        #expect(store.messages(for: channel).isEmpty)
        #expect(store.visibleMessages.isEmpty)
        #expect(store.drainPendingGeohashSystemMessages().isEmpty)
    }
}
