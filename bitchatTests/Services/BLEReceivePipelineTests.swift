import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("BLE receive pipeline tests")
struct BLEReceivePipelineTests {
    @Test("context includes sender, type-scoped message ID, and logging policy")
    func contextBuildsTypeScopedMessageID() {
        let sender = PeerID(str: "1122334455667788")
        let local = PeerID(str: "8877665544332211")
        let packet = makePacket(type: .message, sender: sender, timestamp: 1234)

        let context = BLEReceivePipeline.context(for: packet, localPeerID: local)

        #expect(context.senderID == sender)
        // The message ID includes a payload digest so distinct packets sharing a
        // sender/timestamp(ms)/type are not collapsed as duplicates.
        let digest = packet.payload.sha256Hash().prefix(4).hexEncodedString()
        #expect(context.messageID == "\(sender)-1234-\(MessageType.message.rawValue)-\(digest)")
        #expect(context.messageType == .message)
        #expect(context.shouldDeduplicate)
        #expect(context.logsHandlingDetails)
    }

    @Test("fragments and self sync replays bypass global deduplication")
    func contextBypassesDeduplicationForFragmentsAndSelfSyncReplay() {
        let local = PeerID(str: "1122334455667788")
        let remote = PeerID(str: "8877665544332211")

        let fragment = BLEReceivePipeline.context(
            for: makePacket(type: .fragment, sender: remote),
            localPeerID: local
        )
        let selfReplay = BLEReceivePipeline.context(
            for: makePacket(type: .message, sender: local, ttl: 0),
            localPeerID: local
        )

        #expect(!fragment.shouldDeduplicate)
        #expect(!selfReplay.shouldDeduplicate)
    }

    @Test("dense duplicate traffic cancels pending relays but sparse traffic does not")
    func duplicateRelayCancellationUsesGraphDensity() {
        #expect(!BLEReceivePipeline.shouldCancelScheduledRelayForDuplicate(connectedPeerCount: 2))
        #expect(BLEReceivePipeline.shouldCancelScheduledRelayForDuplicate(connectedPeerCount: 3))
    }

    @Test("relay decision maps packet context and suppresses local recipient traffic")
    func relayDecisionSuppressesLocalRecipientTraffic() {
        let sender = PeerID(str: "1122334455667788")
        let local = PeerID(str: "8877665544332211")
        let packet = makePacket(
            type: .noiseEncrypted,
            sender: sender,
            recipient: local,
            ttl: 7
        )

        let decision = BLEReceivePipeline.relayDecision(
            for: packet,
            senderID: sender,
            localPeerID: local,
            degree: 3,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        #expect(!decision.shouldRelay)
    }

    @Test("recent traffic tracker prunes by count and time window")
    func recentTrafficTrackerPrunesByCountAndWindow() {
        var tracker = BLERecentTrafficTracker()
        let now = Date(timeIntervalSince1970: 1_000)

        tracker.recordPacket(at: now.addingTimeInterval(-TransportConfig.bleRecentPacketWindowSeconds - 1))
        #expect(!tracker.hasTraffic(within: TransportConfig.bleRecentPacketWindowSeconds, now: now))

        for index in 0...TransportConfig.bleRecentPacketWindowMaxCount {
            tracker.recordPacket(at: now.addingTimeInterval(Double(index) * 0.001))
        }

        #expect(tracker.count == TransportConfig.bleRecentPacketWindowMaxCount)
        #expect(tracker.hasTraffic(within: 1.0, now: now.addingTimeInterval(0.1)))

        tracker.removeAll()
        #expect(tracker.count == 0)
    }

    private func makePacket(
        type: MessageType,
        sender: PeerID,
        recipient: PeerID? = nil,
        timestamp: UInt64 = 1,
        ttl: UInt8 = 7
    ) -> BitchatPacket {
        BitchatPacket(
            type: type.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: recipient.flatMap { Data(hexString: $0.id) },
            timestamp: timestamp,
            payload: Data([0x01, 0x02]),
            signature: nil,
            ttl: ttl
        )
    }
}
