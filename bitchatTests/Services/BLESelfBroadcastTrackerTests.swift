import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLESelfBroadcastTrackerTests {
    @Test
    func recordAndTakeMessageIDForMatchingPacket() {
        let packet = makePacket(timestamp: 1234)
        var tracker = BLESelfBroadcastTracker()

        tracker.record(messageID: "local-message", packet: packet, sentAt: Date())

        #expect(tracker.takeMessageID(for: packet) == "local-message")
        #expect(tracker.takeMessageID(for: packet) == nil)
        #expect(tracker.isEmpty)
    }

    @Test
    func differentPacketDoesNotResolveMessageID() {
        let packet = makePacket(timestamp: 1234)
        let otherPacket = makePacket(timestamp: 1235)
        var tracker = BLESelfBroadcastTracker()

        tracker.record(messageID: "local-message", packet: packet, sentAt: Date())

        #expect(tracker.takeMessageID(for: otherPacket) == nil)
        #expect(tracker.count == 1)
    }

    @Test
    func pruneRemovesEntriesBeforeCutoff() {
        let now = Date(timeIntervalSince1970: 100)
        let oldPacket = makePacket(timestamp: 1)
        let freshPacket = makePacket(timestamp: 2)
        var tracker = BLESelfBroadcastTracker()

        tracker.record(messageID: "old", packet: oldPacket, sentAt: now.addingTimeInterval(-10))
        tracker.record(messageID: "fresh", packet: freshPacket, sentAt: now)

        tracker.prune(before: now.addingTimeInterval(-5))

        #expect(tracker.takeMessageID(for: oldPacket) == nil)
        #expect(tracker.takeMessageID(for: freshPacket) == "fresh")
    }

    @Test
    func removeAllClearsTrackedMessages() {
        let packet = makePacket(timestamp: 1234)
        var tracker = BLESelfBroadcastTracker()

        tracker.record(messageID: "local-message", packet: packet, sentAt: Date())
        tracker.removeAll()

        #expect(tracker.isEmpty)
        #expect(tracker.takeMessageID(for: packet) == nil)
    }

    private func makePacket(timestamp: UInt64) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: "8877665544332211") ?? Data(),
            recipientID: nil,
            timestamp: timestamp,
            payload: Data("hello".utf8),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
    }
}
