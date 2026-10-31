import BitFoundation
import Foundation

enum BLEIngressPacketGuard {
    enum Rejection: Error, Equatable {
        case selfLoopback(packetType: UInt8)
        case directSenderMismatch(boundPeerID: PeerID, claimedSenderID: PeerID)
        case invalidRSR(peerID: PeerID)
        case timestampSkew(peerID: PeerID, skewMs: UInt64, maxSkewMs: UInt64)
        case requestSyncForAnotherPeer(peerID: PeerID)
    }

    static func evaluate(
        packet: BitchatPacket,
        claimedSenderID: PeerID,
        boundPeerID: PeerID?,
        localPeerID: PeerID,
        directAnnounceTTL: UInt8,
        nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        maxTimestampSkewMs: UInt64 = TransportConfig.bleMaxTimestampSkewMs,
        isValidSyncResponse: (PeerID) -> Bool
    ) -> Result<BLEIngressPacketContext, Rejection> {
        let contextResult = BLEIngressLinkRegistry.packetContext(
            for: packet,
            claimedSenderID: claimedSenderID,
            boundPeerID: boundPeerID,
            localPeerID: localPeerID,
            directAnnounceTTL: directAnnounceTTL
        )

        let context: BLEIngressPacketContext
        switch contextResult {
        case .success(let acceptedContext):
            context = acceptedContext
        case .failure(.selfLoopback(let packetType)):
            return .failure(.selfLoopback(packetType: packetType))
        case .failure(.directSenderMismatch(let boundPeerID, let claimedSenderID)):
            return .failure(.directSenderMismatch(boundPeerID: boundPeerID, claimedSenderID: claimedSenderID))
        }

        switch validatePayload(
            packet,
            from: context.validationPeerID,
            localPeerID: localPeerID,
            nowMs: nowMs,
            maxTimestampSkewMs: maxTimestampSkewMs,
            isValidSyncResponse: isValidSyncResponse
        ) {
        case .success:
            return .success(context)
        case .failure(let rejection):
            return .failure(rejection)
        }
    }

    static func validatePayload(
        _ packet: BitchatPacket,
        from peerID: PeerID,
        localPeerID: PeerID,
        nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        maxTimestampSkewMs: UInt64 = TransportConfig.bleMaxTimestampSkewMs,
        isValidSyncResponse: (PeerID) -> Bool
    ) -> Result<Void, Rejection> {
        // A directed REQUEST_SYNC is for its recipient only. A copy for
        // another peer reaches us when the requester has no link to that
        // peer: the send then falls back to every link. Reject it before
        // the ingress and duplicate records. Its packet ID has no recipient,
        // so it can hide the copy addressed to us from the same round.
        if packet.type == MessageType.requestSync.rawValue,
           !BLEPacketFreshnessPolicy.isBroadcastRecipient(packet.recipientID),
           packet.recipientID != localPeerID.routingData {
            return .failure(.requestSyncForAnotherPeer(peerID: peerID))
        }

        let packetTime = packet.timestamp
        if packet.isRSR {
            guard isValidSyncResponse(peerID) else {
                return .failure(.invalidRSR(peerID: peerID))
            }
            // Sync replies legitimately replay old packets, so only the past
            // bound is waived. A far-future packet is never legitimate: it
            // would outlive every gossip freshness window, drag requesters'
            // since-cursors past all real history, and pin itself below live
            // chat.
            guard packetTime <= nowMs || packetTime - nowMs <= maxTimestampSkewMs else {
                return .failure(.timestampSkew(peerID: peerID, skewMs: packetTime - nowMs, maxSkewMs: maxTimestampSkewMs))
            }
            return .success(())
        }

        let skew = packetTime > nowMs ? packetTime - nowMs : nowMs - packetTime
        guard skew <= maxTimestampSkewMs else {
            return .failure(.timestampSkew(peerID: peerID, skewMs: skew, maxSkewMs: maxTimestampSkewMs))
        }

        return .success(())
    }
}
