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

    // MARK: - Bounds

    @Test
    func enqueueEvictsOldestPastTheByteBudget() {
        let recipient = PeerID(str: "1122334455667788")
        let now = Date()
        var spool = BLEDirectedRelaySpool(capacity: 10, byteBudget: 250)

        for index in 0..<3 {
            spool.enqueue(
                packet: makePacket(payload: [UInt8](repeating: UInt8(index), count: 100)),
                recipient: recipient,
                messageID: "message-\(index)",
                enqueuedAt: now.addingTimeInterval(Double(index))
            )
        }

        // 300 bytes against a 250-byte budget: only the oldest goes, though
        // the count cap is nowhere near. Survivors drain oldest-first.
        #expect(spool.count == 2)
        let drained = spool.drainUnexpired(now: now, window: 60)
        #expect(drained.map { $0.packet.payload.first } == [1, 2])
    }

    @Test
    func enqueueEvictsOldestPastTheCountCap() {
        let now = Date()
        var spool = BLEDirectedRelaySpool(capacity: 2, byteBudget: 1024)

        for index in 0..<3 {
            spool.enqueue(
                packet: makePacket(payload: [UInt8(index)]),
                recipient: PeerID(str: "112233445566778\(index)"),
                messageID: "message-\(index)",
                enqueuedAt: now
            )
        }

        #expect(spool.count == 2)
        let drained = spool.drainUnexpired(now: now, window: 60)
        #expect(drained.map { $0.packet.payload.first } == [1, 2])
    }

    @Test
    func packetLargerThanTheWholeBudgetIsRefusedWithoutEvicting() {
        let recipient = PeerID(str: "1122334455667788")
        let now = Date()
        var spool = BLEDirectedRelaySpool(capacity: 10, byteBudget: 250)
        spool.enqueue(packet: makePacket(payload: [0x01]), recipient: recipient, messageID: "small", enqueuedAt: now)

        let oversized = spool.enqueue(
            packet: makePacket(payload: [UInt8](repeating: 0x02, count: 251)),
            recipient: recipient,
            messageID: "oversized",
            enqueuedAt: now
        )

        #expect(!oversized)
        #expect(spool.drainUnexpired(now: now, window: 60).map { $0.packet.payload } == [Data([0x01])])
    }

    /// A relay with no onward link used to hold every spooled packet for the
    /// whole window with no count or byte limit, and a noiseEncrypted frame
    /// may decode to the framed-file cap: each ~1 KB on air pinned ~1.1 MB.
    @Test
    func defaultBoundsHoldAFramedFilePacketButNotAFloodOfThem() {
        let recipient = PeerID(str: "1122334455667788")
        let now = Date()
        var spool = BLEDirectedRelaySpool()
        let inflated = Data(repeating: 0x41, count: FileTransferLimits.maxFramedFileBytes)

        for index in 0..<20 {
            let accepted = spool.enqueue(
                packet: makePacket(payload: inflated),
                recipient: recipient,
                messageID: "inflated-\(index)",
                enqueuedAt: now
            )
            #expect(accepted)
        }

        #expect(spool.count == TransportConfig.bleDirectedSpoolByteBudget / FileTransferLimits.maxFramedFileBytes)
        #expect(spool.count >= 1)
    }

    private func makePacket(payload: [UInt8]) -> BitchatPacket {
        makePacket(payload: Data(payload))
    }

    private func makePacket(payload: Data) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: "8877665544332211") ?? Data(),
            recipientID: Data(hexString: "1122334455667788"),
            timestamp: 1234,
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
    }
}
