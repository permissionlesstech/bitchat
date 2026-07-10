import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEPublicMessagePolicyTests {
    @Test
    func selfAuthoredNonSyncReplayIsRejected() {
        let localPeerID = PeerID(str: "1122334455667788")
        let packet = makePacket(sender: localPeerID, ttl: 3)

        let decision = BLEPublicMessagePolicy.evaluate(
            packet: packet,
            from: localPeerID,
            localPeerID: localPeerID,
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(decision == .reject(.selfEcho))
    }

    @Test
    func selfAuthoredSyncReplayIsAccepted() {
        let localPeerID = PeerID(str: "1122334455667788")
        let packet = makePacket(sender: localPeerID, ttl: 0)

        let decision = BLEPublicMessagePolicy.evaluate(
            packet: packet,
            from: localPeerID,
            localPeerID: localPeerID,
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(decision == .accept(BLEPublicMessageAcceptance(shouldTrackForSync: true)))
    }

    @Test
    func staleBroadcastIsRejectedWithAge() {
        // The acceptance window matches the gossip public-history window.
        let staleAge = TransportConfig.syncPublicMessageMaxAgeSeconds + 1
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sender = PeerID(str: "8877665544332211")
        let packet = makePacket(
            sender: sender,
            timestamp: UInt64((now.timeIntervalSince1970 - staleAge) * 1000),
            recipientID: nil
        )

        let decision = BLEPublicMessagePolicy.evaluate(
            packet: packet,
            from: sender,
            localPeerID: PeerID(str: "1122334455667788"),
            now: now
        )

        #expect(decision == .reject(.staleBroadcast(ageSeconds: staleAge)))
    }

    @Test
    func staleDirectedMessageIsAcceptedAndNotTrackedForSync() {
        let now = Date(timeIntervalSince1970: 1_000)
        let sender = PeerID(str: "8877665544332211")
        let recipient = PeerID(str: "1122334455667788")
        let packet = makePacket(
            sender: sender,
            timestamp: UInt64((now.timeIntervalSince1970 - 901) * 1000),
            recipientID: Data(hexString: recipient.id)
        )

        let decision = BLEPublicMessagePolicy.evaluate(
            packet: packet,
            from: sender,
            localPeerID: recipient,
            now: now
        )

        #expect(decision == .accept(BLEPublicMessageAcceptance(shouldTrackForSync: false)))
    }

    @Test
    func freshBroadcastMessageIsTrackedForSync() {
        let sender = PeerID(str: "8877665544332211")
        let packet = makePacket(sender: sender)

        let decision = BLEPublicMessagePolicy.evaluate(
            packet: packet,
            from: sender,
            localPeerID: PeerID(str: "1122334455667788"),
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(decision == .accept(BLEPublicMessageAcceptance(shouldTrackForSync: true)))
    }

    @Test
    func broadcastNonMessageIsNotTrackedForSync() {
        let sender = PeerID(str: "8877665544332211")
        let packet = makePacket(sender: sender, type: .leave)

        let decision = BLEPublicMessagePolicy.evaluate(
            packet: packet,
            from: sender,
            localPeerID: PeerID(str: "1122334455667788"),
            now: Date(timeIntervalSince1970: 1_000)
        )

        #expect(decision == .accept(BLEPublicMessageAcceptance(shouldTrackForSync: false)))
    }

    private func makePacket(
        sender: PeerID,
        type: MessageType = .message,
        timestamp: UInt64 = 900_000,
        ttl: UInt8 = 3,
        recipientID: Data? = nil
    ) -> BitchatPacket {
        BitchatPacket(
            type: type.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: recipientID,
            timestamp: timestamp,
            payload: Data("Hello".utf8),
            signature: nil,
            ttl: ttl
        )
    }
}
