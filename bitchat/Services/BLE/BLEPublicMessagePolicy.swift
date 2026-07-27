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
        // Acceptance window matches the gossip-sync serving window: a peer
        // walking between partitions carries hours of public history, so the
        // receive side must not drop what sync legitimately serves.
        if isBroadcast,
           BLEPacketFreshnessPolicy.isStale(
               timestampMilliseconds: packet.timestamp,
               now: now,
               maxAgeSeconds: TransportConfig.syncPublicMessageMaxAgeSeconds
           ) {
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
