import BitFoundation
import Foundation

struct BLEPublicMessageAcceptance: Equatable {
    let shouldTrackForSync: Bool
}

enum BLEPublicMessageRejection: Equatable {
    case selfEcho
    case staleBroadcast(ageSeconds: Double)
}

enum BLEPublicMessageDecision: Equatable {
    case accept(BLEPublicMessageAcceptance)
    case reject(BLEPublicMessageRejection)
}

enum BLEPublicMessagePolicy {
    static func evaluate(
        packet: BitchatPacket,
        from peerID: PeerID,
        localPeerID: PeerID,
        now: Date
    ) -> BLEPublicMessageDecision {
        if peerID == localPeerID && packet.ttl != 0 {
            return .reject(.selfEcho)
        }

        let isBroadcast = BLEPacketFreshnessPolicy.isBroadcastRecipient(packet.recipientID)
        if isBroadcast,
           BLEPacketFreshnessPolicy.isStale(timestampMilliseconds: packet.timestamp, now: now) {
            return .reject(.staleBroadcast(ageSeconds: BLEPacketFreshnessPolicy.ageSeconds(
                timestampMilliseconds: packet.timestamp,
                now: now
            )))
        }

        return .accept(BLEPublicMessageAcceptance(
            shouldTrackForSync: isBroadcast && packet.type == MessageType.message.rawValue
        ))
    }
}
