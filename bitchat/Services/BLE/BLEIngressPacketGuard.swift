import BitFoundation
import Foundation

enum BLEIngressPacketGuard {
    enum Rejection: Error, Equatable {
        case selfLoopback(packetType: UInt8)
        case directSenderMismatch(boundPeerID: PeerID, claimedSenderID: PeerID)
        case invalidRSR(peerID: PeerID)
        case timestampSkew(peerID: PeerID, skewMs: UInt64, maxSkewMs: UInt64)
    }

    static func evaluate(
        packet: BitchatPacket,
        claimedSenderID: PeerID,
        boundPeerID: PeerID?,
        localPeerID: PeerID,
        directAnnounceTTL: UInt8,
        nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        maxTimestampSkewMs: UInt64 = 120_000,
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
        nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        maxTimestampSkewMs: UInt64 = 120_000,
        isValidSyncResponse: (PeerID) -> Bool
    ) -> Result<Void, Rejection> {
        if packet.isRSR {
            guard isValidSyncResponse(peerID) else {
                return .failure(.invalidRSR(peerID: peerID))
            }
            return .success(())
        }

        let packetTime = packet.timestamp
        let skew = packetTime > nowMs ? packetTime - nowMs : nowMs - packetTime
        guard skew <= maxTimestampSkewMs else {
            return .failure(.timestampSkew(peerID: peerID, skewMs: skew, maxSkewMs: maxTimestampSkewMs))
        }

        return .success(())
    }
}
