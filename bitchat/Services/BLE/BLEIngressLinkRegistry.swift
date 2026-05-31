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
        let messageID = Self.messageID(for: packet)
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

        if let boundPeerID,
           boundPeerID != claimedSenderID,
           requiresDirectSenderBinding(packet, directAnnounceTTL: directAnnounceTTL) {
            return .failure(.directSenderMismatch(boundPeerID: boundPeerID, claimedSenderID: claimedSenderID))
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
        let digestPrefix = packet.payload.sha256Hash().prefix(4).hexEncodedString()
        return "\(senderID)-\(packet.timestamp)-\(packet.type)-\(digestPrefix)"
    }

    private static func requiresDirectSenderBinding(_ packet: BitchatPacket, directAnnounceTTL: UInt8) -> Bool {
        packet.type == MessageType.announce.rawValue && packet.ttl == directAnnounceTTL
    }

    private static func isSelfAuthoredSyncResponse(_ packet: BitchatPacket) -> Bool {
        packet.isRSR && packet.ttl == 0
    }
}
