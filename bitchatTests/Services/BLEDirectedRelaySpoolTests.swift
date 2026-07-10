import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEDirectedRelaySpoolTests {
    @Test
    func enqueueDeduplicatesByRecipientAndMessageID() {
        let recipient = PeerID(str: "1122334455667788")
        let now = Date()
        var spool = BLEDirectedRelaySpool()

        let inserted = spool.enqueue(
            packet: makePacket(payload: [0x01]),
            recipient: recipient,
            messageID: "message-1",
            enqueuedAt: now
        )
        let duplicate = spool.enqueue(
            packet: makePacket(payload: [0x02]),
            recipient: recipient,
            messageID: "message-1",
            enqueuedAt: now
        )

        #expect(inserted)
        #expect(!duplicate)
        #expect(spool.count == 1)
    }

    @Test
    func drainUnexpiredReturnsFreshPacketsAndClearsSpool() {
        let recipient = PeerID(str: "1122334455667788")
        let now = Date()
        var spool = BLEDirectedRelaySpool()
        let freshPacket = makePacket(payload: [0x01])
        let expiredPacket = makePacket(payload: [0x02])

        spool.enqueue(packet: freshPacket, recipient: recipient, messageID: "fresh", enqueuedAt: now.addingTimeInterval(-1))
        spool.enqueue(packet: expiredPacket, recipient: recipient, messageID: "old", enqueuedAt: now.addingTimeInterval(-20))

        let drained = spool.drainUnexpired(now: now, window: 5)

        #expect(drained.count == 1)
        #expect(drained.first?.recipient == recipient)
        #expect(drained.first?.packet.payload == freshPacket.payload)
        #expect(spool.isEmpty)
    }

    @Test
    func pruneExpiredKeepsFreshPacketsAcrossRecipients() {
        let firstRecipient = PeerID(str: "1122334455667788")
        let secondRecipient = PeerID(str: "8877665544332211")
        let now = Date()
        var spool = BLEDirectedRelaySpool()

        spool.enqueue(packet: makePacket(payload: [0x01]), recipient: firstRecipient, messageID: "fresh-1", enqueuedAt: now)
        spool.enqueue(packet: makePacket(payload: [0x02]), recipient: secondRecipient, messageID: "fresh-2", enqueuedAt: now.addingTimeInterval(-2))
        spool.enqueue(packet: makePacket(payload: [0x03]), recipient: secondRecipient, messageID: "old", enqueuedAt: now.addingTimeInterval(-10))

        spool.pruneExpired(now: now, window: 5)

        #expect(spool.count == 2)
        let drained = spool.drainUnexpired(now: now, window: 5)
        #expect(Set(drained.map(\.recipient)) == Set([firstRecipient, secondRecipient]))
    }

    @Test
    func removeAllClearsStoredPackets() {
        var spool = BLEDirectedRelaySpool()

        spool.enqueue(
            packet: makePacket(payload: [0x01]),
            recipient: PeerID(str: "1122334455667788"),
            messageID: "message-1",
            enqueuedAt: Date()
        )
        spool.removeAll()

        #expect(spool.isEmpty)
    }

    private func makePacket(payload: [UInt8]) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: "8877665544332211") ?? Data(),
            recipientID: Data(hexString: "1122334455667788"),
            timestamp: 1234,
            payload: Data(payload),
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
    }
}
