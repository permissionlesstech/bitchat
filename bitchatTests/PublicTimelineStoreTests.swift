import Foundation
import Testing
@testable import bitchat

@Suite("PublicTimelineStore Tests")
struct PublicTimelineStoreTests {

    @Test("Mesh timeline deduplicates and trims to cap")
    func meshTimelineDeduplicatesAndTrims() {
        var store = PublicTimelineStore(meshCap: 2, geohashCap: 2)
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
        var store = PublicTimelineStore(meshCap: 2, geohashCap: 3)
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

    @Test("Mutate geohash updates stored messages in place")
    func mutateGeohashAppliesTransformation() {
        var store = PublicTimelineStore(meshCap: 2, geohashCap: 3)
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
        var store = PublicTimelineStore(meshCap: 1, geohashCap: 1)

        store.queueGeohashSystemMessage("first")
        store.queueGeohashSystemMessage("second")

        #expect(store.drainPendingGeohashSystemMessages() == ["first", "second"])
        #expect(store.drainPendingGeohashSystemMessages().isEmpty)
    }
}
