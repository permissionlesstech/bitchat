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
    static func context(
        for packet: BitchatPacket,
        localPeerID: PeerID,
        precomputedMessageID: String? = nil
    ) -> BLEReceivedPacketContext {
        let senderID = PeerID(hexData: packet.senderID)
        // Include a payload digest so that distinct packets sharing the same
        // sender/timestamp(ms)/type are not collapsed as duplicates. The
        // post-handshake flush sends queued messages, delivery and read receipts
        // back-to-back within a single millisecond; without the digest every
        // packet after the first would be silently dropped.
        let messageID = precomputedMessageID ?? BLEIngressLinkRegistry.messageID(for: packet)
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
            // Courier envelopes are directed opaque ciphertext like DMs; a
            // remote handover toward a relayed announce rides this same
            // deterministic relay treatment instead of the broadcast clamp.
            // Ping/pong diagnostics ride it too: probes need the same
            // deterministic multi-hop relay as DMs (always relay, jitter,
            // no TTL cap) so RTT and hop counts reflect the real path.
            // Directed nostrCarrier uplinks (mesh-only peer -> gateway) need
            // the same multi-hop treatment to reach a non-adjacent gateway.
            isDirectedEncrypted: (packet.type == MessageType.noiseEncrypted.rawValue
                || packet.type == MessageType.courierEnvelope.rawValue
                || packet.type == MessageType.ping.rawValue
                || packet.type == MessageType.pong.rawValue
                || packet.type == MessageType.nostrCarrier.rawValue) && packet.recipientID != nil,
            isFragment: packet.type == MessageType.fragment.rawValue,
            isDirectedFragment: packet.type == MessageType.fragment.rawValue && packet.recipientID != nil,
            isHandshake: packet.type == MessageType.noiseHandshake.rawValue,
            isAnnounce: packet.type == MessageType.announce.rawValue,
            isRequestSync: packet.type == MessageType.requestSync.rawValue,
            // Board posts relay like broadcast messages; urgent ones get the
            // announce-class TTL headroom so alerts travel the extra hop.
            isUrgentBoardPost: packet.type == MessageType.boardPost.rawValue
                && BoardWire.urgentFlag(in: packet.payload),
            isVoiceFrame: packet.type == MessageType.voiceFrame.rawValue,
            degree: degree,
            highDegreeThreshold: highDegreeThreshold
        )
    }
}

/// Lock-backed traffic-level signal: the receive pipeline records packets,
/// and the radio layer (maintenance and scan-duty adaptation on bleQueue)
/// reads the level without crossing onto a transport queue.
final class BLERecentTrafficMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = BLERecentTrafficTracker()

    func recordPacket(at now: Date) {
        lock.withLock { tracker.recordPacket(at: now) }
    }

    func hasTraffic(within seconds: TimeInterval, now: Date) -> Bool {
        lock.withLock { tracker.hasTraffic(within: seconds, now: now) }
    }

    func removeAll() {
        lock.withLock { tracker.removeAll() }
    }
}

struct BLERecentTrafficTracker: Equatable {
    private var packetTimestamps: [Date] = []
    private var head: Int = 0

    var count: Int {
        packetTimestamps.count - head
    }

    mutating func removeAll() {
        packetTimestamps.removeAll()
        head = 0
    }

    mutating func recordPacket(at now: Date) {
        packetTimestamps.append(now)
        prune(at: now)
    }

    func hasTraffic(within seconds: TimeInterval, now: Date) -> Bool {
        let activeCount = packetTimestamps.count - head
        guard activeCount > 0 else { return false }
        let cutoff = now.addingTimeInterval(-seconds)
        // Fast path: timestamps are appended chronologically, so the newest entry
        // answers in O(1) without scanning the window.
        if let newest = packetTimestamps.last, newest >= cutoff {
            return true
        }
        // Fallback if timestamps were recorded out of order (e.g. tests).
        for idx in stride(from: packetTimestamps.count - 2, through: head, by: -1) {
            if packetTimestamps[idx] >= cutoff {
                return true
            }
        }
        return false
    }

    private mutating func prune(at now: Date) {
        let cutoff = now.addingTimeInterval(-TransportConfig.bleRecentPacketWindowSeconds)
        let maxCount = TransportConfig.bleRecentPacketWindowMaxCount
        if packetTimestamps.count - head > maxCount {
            head = packetTimestamps.count - maxCount
        }
        while head < packetTimestamps.count && packetTimestamps[head] < cutoff {
            head += 1
        }
        if head > 0 && (head >= packetTimestamps.count || head >= maxCount) {
            packetTimestamps.removeFirst(head)
            head = 0
        }
    }

    static func == (lhs: BLERecentTrafficTracker, rhs: BLERecentTrafficTracker) -> Bool {
        lhs.packetTimestamps[lhs.head...].elementsEqual(rhs.packetTimestamps[rhs.head...])
    }
}


// MARK: - Packet Freshness Policy

enum BLEPacketFreshnessPolicy {
    static let defaultMaxAgeSeconds: TimeInterval = 900

    static func isBroadcastRecipient(_ recipientID: Data?) -> Bool {
        guard let recipientID else { return true }
        return recipientID.count == 8 && recipientID.allSatisfy { $0 == 0xFF }
    }

    static func isStale(
        timestampMilliseconds: UInt64,
        now: Date,
        maxAgeSeconds: TimeInterval = defaultMaxAgeSeconds
    ) -> Bool {
        let nowMilliseconds = UInt64(now.timeIntervalSince1970 * 1000)
        let maxAgeMilliseconds = UInt64(maxAgeSeconds * 1000)
        guard nowMilliseconds >= maxAgeMilliseconds else { return false }
        return timestampMilliseconds < nowMilliseconds - maxAgeMilliseconds
    }

    static func ageSeconds(timestampMilliseconds: UInt64, now: Date) -> Double {
        let nowMilliseconds = UInt64(now.timeIntervalSince1970 * 1000)
        guard nowMilliseconds >= timestampMilliseconds else { return 0 }
        return Double(nowMilliseconds - timestampMilliseconds) / 1000.0
    }
}
