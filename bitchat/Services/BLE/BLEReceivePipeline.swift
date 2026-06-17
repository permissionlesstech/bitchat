import BitFoundation
import Foundation

struct BLEReceivedPacketContext: Equatable {
    let senderID: PeerID
    let messageID: String
    let messageType: MessageType?
    let shouldDeduplicate: Bool
    let logsHandlingDetails: Bool
}

struct BLEReceivePipeline {
    static func context(for packet: BitchatPacket, localPeerID: PeerID) -> BLEReceivedPacketContext {
        let senderID = PeerID(hexData: packet.senderID)
        // Include a payload digest so that distinct packets sharing the same
        // sender/timestamp(ms)/type are not collapsed as duplicates. The
        // post-handshake flush sends queued messages, delivery and read receipts
        // back-to-back within a single millisecond; without the digest every
        // packet after the first would be silently dropped.
        let digestPrefix = packet.payload.sha256Hash().prefix(4).hexEncodedString()
        let messageID = "\(senderID)-\(packet.timestamp)-\(packet.type)-\(digestPrefix)"
        let messageType = MessageType(rawValue: packet.type)
        let allowSelfSyncReplay = packet.ttl == 0 && senderID == localPeerID
        let shouldDeduplicate = messageType != .fragment && !allowSelfSyncReplay

        return BLEReceivedPacketContext(
            senderID: senderID,
            messageID: messageID,
            messageType: messageType,
            shouldDeduplicate: shouldDeduplicate,
            logsHandlingDetails: messageType != .announce
        )
    }

    static func shouldCancelScheduledRelayForDuplicate(connectedPeerCount: Int) -> Bool {
        connectedPeerCount > 2
    }

    static func relayDecision(
        for packet: BitchatPacket,
        senderID: PeerID,
        localPeerID: PeerID,
        degree: Int,
        highDegreeThreshold: Int
    ) -> RelayDecision {
        RelayController.decide(
            ttl: packet.ttl,
            senderIsSelf: senderID == localPeerID,
            recipientIsSelf: PeerID(hexData: packet.recipientID) == localPeerID,
            isEncrypted: packet.type == MessageType.noiseEncrypted.rawValue,
            isDirectedEncrypted: packet.type == MessageType.noiseEncrypted.rawValue && packet.recipientID != nil,
            isFragment: packet.type == MessageType.fragment.rawValue,
            isDirectedFragment: packet.type == MessageType.fragment.rawValue && packet.recipientID != nil,
            isHandshake: packet.type == MessageType.noiseHandshake.rawValue,
            isAnnounce: packet.type == MessageType.announce.rawValue,
            degree: degree,
            highDegreeThreshold: highDegreeThreshold
        )
    }
}

struct BLERecentTrafficTracker: Equatable {
    private var packetTimestamps: [Date] = []

    var count: Int {
        packetTimestamps.count
    }

    mutating func removeAll() {
        packetTimestamps.removeAll()
    }

    mutating func recordPacket(at now: Date) {
        packetTimestamps.append(now)
        prune(at: now)
    }

    func hasTraffic(within seconds: TimeInterval, now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-seconds)
        return packetTimestamps.contains { $0 >= cutoff }
    }

    private mutating func prune(at now: Date) {
        let cutoff = now.addingTimeInterval(-TransportConfig.bleRecentPacketWindowSeconds)
        if packetTimestamps.count > TransportConfig.bleRecentPacketWindowMaxCount {
            packetTimestamps.removeFirst(packetTimestamps.count - TransportConfig.bleRecentPacketWindowMaxCount)
        }
        packetTimestamps.removeAll { $0 < cutoff }
    }
}
