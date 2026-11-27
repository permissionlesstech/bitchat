import BitFoundation
import Foundation

enum BLEIngressLinkID: Hashable, Equatable {
    case peripheral(String)
    case central(String)
}

struct BLEIngressPacketContext: Equatable {
    let receivedFromPeerID: PeerID
    let validationPeerID: PeerID
}

struct BLEIngressLinkRecord: Equatable {
    let link: BLEIngressLinkID
    let peerID: PeerID
    let timestamp: Date
}

enum BLEIngressRejection: Error, Equatable {
    case selfLoopback(packetType: UInt8)
    case directSenderMismatch(boundPeerID: PeerID, claimedSenderID: PeerID)
    case foreignRequestSync(recipientID: PeerID)
}

struct BLEIngressLinkRegistry {
    private var ingressByMessageID: [String: BLEIngressLinkRecord] = [:]

    var isEmpty: Bool {
        ingressByMessageID.isEmpty
    }

    mutating func removeAll() {
        ingressByMessageID.removeAll()
    }

    func record(for packet: BitchatPacket) -> BLEIngressLinkRecord? {
        ingressByMessageID[Self.messageID(for: packet)]
    }

    func record(forMessageID messageID: String) -> BLEIngressLinkRecord? {
        ingressByMessageID[messageID]
    }

    func link(for packet: BitchatPacket) -> BLEIngressLinkID? {
        record(for: packet)?.link
    }

    func peerID(for packet: BitchatPacket) -> PeerID? {
        record(for: packet)?.peerID
    }

    mutating func recordIfNew(
        _ packet: BitchatPacket,
        link: BLEIngressLinkID,
        peerID: PeerID,
        now: Date = Date(),
        lifetime: TimeInterval
    ) -> Bool {
        recordIfNew(
            messageID: Self.messageID(for: packet),
            link: link,
            peerID: peerID,
            now: now,
            lifetime: lifetime
        )
    }

    mutating func recordIfNew(
        messageID: String,
        link: BLEIngressLinkID,
        peerID: PeerID,
        now: Date = Date(),
        lifetime: TimeInterval
    ) -> Bool {
        if let existing = ingressByMessageID[messageID],
           now.timeIntervalSince(existing.timestamp) <= lifetime {
            return false
        }

        ingressByMessageID[messageID] = BLEIngressLinkRecord(link: link, peerID: peerID, timestamp: now)
        return true
    }

    mutating func prune(before cutoff: Date) {
        ingressByMessageID = ingressByMessageID.filter { $0.value.timestamp >= cutoff }
    }

    static func packetContext(
        for packet: BitchatPacket,
        claimedSenderID: PeerID,
        boundPeerID: PeerID?,
        localPeerID: PeerID,
        directAnnounceTTL: UInt8
    ) -> Result<BLEIngressPacketContext, BLEIngressRejection> {
        if claimedSenderID == localPeerID,
           !isSelfAuthoredSyncResponse(packet) {
            return .failure(.selfLoopback(packetType: packet.type))
        }

        // A directed REQUEST_SYNC is link-local to its intended recipient.
        // Drop requests addressed to another peer at ingress before dedup or
        // sync processing.
        if packet.type == MessageType.requestSync.rawValue,
           let recipientID = packet.recipientID,
           !BLEPacketFreshnessPolicy.isBroadcastRecipient(recipientID) {
            let targetPeer = PeerID(hexData: recipientID)
            if targetPeer != localPeerID {
                return .failure(.foreignRequestSync(recipientID: targetPeer))
            }
        }

        if let boundPeerID, boundPeerID != claimedSenderID {
            if requiresDirectSenderBinding(packet) {
                return .failure(.directSenderMismatch(boundPeerID: boundPeerID, claimedSenderID: claimedSenderID))
            }
            // A direct announce claiming a new sender on a bound link is either
            // a spoof or a legitimate peer-ID rotation on a connection that
            // outlived the old ID. Attribute it to the claimed sender and let
            // it through: announces are self-authenticating, and only a
            // signature-verified announce may rebind the link (BLEService).
            if isDirectAnnounce(packet, directAnnounceTTL: directAnnounceTTL) {
                return .success(BLEIngressPacketContext(
                    receivedFromPeerID: claimedSenderID,
                    validationPeerID: claimedSenderID
                ))
            }
        }

        let receivedFromPeerID = boundPeerID ?? claimedSenderID
        let validationPeerID = packet.isRSR ? receivedFromPeerID : claimedSenderID
        return .success(BLEIngressPacketContext(
            receivedFromPeerID: receivedFromPeerID,
            validationPeerID: validationPeerID
        ))
    }

    static func messageID(for packet: BitchatPacket) -> String {
        let senderID = packet.senderID.hexEncodedString()
        let digestPrefix = packet.payload.sha256PrefixHex(bytes: 4)
        return "\(senderID)-\(packet.timestamp)-\(packet.type)-\(digestPrefix)"
    }

    private static func requiresDirectSenderBinding(_ packet: BitchatPacket) -> Bool {
        // REQUEST_SYNC is never relayed, so on a bound link the claimed sender
        // must be the link peer — it elicits a full store replay, and the
        // response is addressed to whoever the sender claims to be.
        packet.type == MessageType.requestSync.rawValue
    }

    static func isDirectAnnounce(_ packet: BitchatPacket, directAnnounceTTL: UInt8) -> Bool {
        packet.type == MessageType.announce.rawValue && packet.ttl == directAnnounceTTL
    }

    private static func isSelfAuthoredSyncResponse(_ packet: BitchatPacket) -> Bool {
        packet.isRSR && packet.ttl == 0
    }
}


// MARK: - Ingress Packet Guard

enum BLEIngressPacketGuard {
    enum Rejection: Error, Equatable {
        case selfLoopback(packetType: UInt8)
        case directSenderMismatch(boundPeerID: PeerID, claimedSenderID: PeerID)
        case foreignRequestSync(recipientID: PeerID)
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
        case .failure(.foreignRequestSync(let recipientID)):
            return .failure(.foreignRequestSync(recipientID: recipientID))
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
        maxTimestampSkewMs: UInt64 = TransportConfig.bleMaxTimestampSkewMs,
        isValidSyncResponse: (PeerID) -> Bool
    ) -> Result<Void, Rejection> {
        let packetTime = packet.timestamp
        if packet.isRSR {
            guard isValidSyncResponse(peerID) else {
                return .failure(.invalidRSR(peerID: peerID))
            }
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
