import Foundation
import CryptoKit

// Gossip-based sync manager using on-demand GCS filters
final class GossipSyncManager {
    protocol Delegate: AnyObject {
        func sendPacket(_ packet: BitchatPacket)
        func sendPacket(to peerID: String, packet: BitchatPacket)
        func signPacketForBroadcast(_ packet: BitchatPacket) -> BitchatPacket
    }

    struct Config {
        var seenCapacity: Int = 1000          // max packets per sync (cap across types)
        var gcsMaxBytes: Int = 400           // filter size budget (128..1024)
        var gcsTargetFpr: Double = 0.01      // 1%
    }

    private let myPeerID: String
    private let config: Config
    weak var delegate: Delegate?

    // Storage: broadcast messages (ordered by insert), and latest announce per sender
    private var messages: [String: BitchatPacket] = [:] // idHex -> packet
    private var messageOrder: [String] = []
    private var latestAnnouncementByPeer: [String: (id: String, packet: BitchatPacket)] = [:]

    // Timer
    private var periodicTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mesh.sync", qos: .utility)

    init(myPeerID: String, config: Config = Config()) {
        self.myPeerID = myPeerID
        self.config = config
    }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30.0, repeating: 30.0, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.sendRequestSync() }
        timer.resume()
        periodicTimer = timer
    }

    func stop() {
        periodicTimer?.cancel(); periodicTimer = nil
    }

    func scheduleInitialSyncToPeer(_ peerID: String, delaySeconds: TimeInterval = 5.0) {
        queue.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            self?.sendRequestSync(to: peerID)
        }
    }

    func onPublicPacketSeen(_ packet: BitchatPacket) {
        let mt = MessageType(rawValue: packet.type)
        let isBroadcastRecipient: Bool = {
            guard let r = packet.recipientID else { return true }
            return r.count == 8 && r.allSatisfy { $0 == 0xFF }
        }()
        let isBroadcastMessage = (mt == .message && isBroadcastRecipient)
        let isAnnounce = (mt == .announce)
        guard isBroadcastMessage || isAnnounce else { return }

        let idHex = PacketIdUtil.computeId(packet).hexEncodedString()

        if isBroadcastMessage {
            if messages[idHex] == nil {
                messages[idHex] = packet
                messageOrder.append(idHex)
                // Enforce capacity
                let cap = max(1, config.seenCapacity)
                while messageOrder.count > cap {
                    let victim = messageOrder.removeFirst()
                    messages.removeValue(forKey: victim)
                }
            }
        } else if isAnnounce {
            let sender = packet.senderID.hexEncodedString()
            latestAnnouncementByPeer[sender] = (id: idHex, packet: packet)
        }
    }

    private func sendRequestSync() {
        let payload = buildGcsPayload()
        let pkt = BitchatPacket(
            type: MessageType.requestSync.rawValue,
            senderID: Data(hexString: myPeerID) ?? Data(),
            recipientID: nil, // broadcast
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 0 // local-only
        )
        let signed = delegate?.signPacketForBroadcast(pkt) ?? pkt
        delegate?.sendPacket(signed)
    }

    private func sendRequestSync(to peerID: String) {
        let payload = buildGcsPayload()
        var recipient = Data()
        var temp = peerID
        while temp.count >= 2 && recipient.count < 8 {
            let hexByte = String(temp.prefix(2))
            if let b = UInt8(hexByte, radix: 16) { recipient.append(b) }
            temp = String(temp.dropFirst(2))
        }
        let pkt = BitchatPacket(
            type: MessageType.requestSync.rawValue,
            senderID: Data(hexString: myPeerID) ?? Data(),
            recipientID: recipient,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 0 // local-only
        )
        let signed = delegate?.signPacketForBroadcast(pkt) ?? pkt
        delegate?.sendPacket(to: peerID, packet: signed)
    }

    func handleRequestSync(fromPeerID: String, request: RequestSyncPacket) {
        // Decode GCS into sorted set and prepare membership checker
        let sorted = GCSFilter.decodeToSortedSet(p: request.p, m: request.m, data: request.data)
        func mightContain(_ id: Data) -> Bool {
            var hasher = SHA256()
            hasher.update(data: id) // 16-byte PacketId
            let digest = hasher.finalize()
            let db = Data(digest)
            var x: UInt64 = 0
            let take = min(8, db.count)
            for i in 0..<take { x = (x << 8) | UInt64(db[i]) }
            let v = (x & 0x7fff_ffff_ffff_ffff) % UInt64(request.m)
            return GCSFilter.contains(sortedValues: sorted, candidate: v)
        }

        // 1) Announcements: send latest per peer if requester lacks them
        for (_, pair) in latestAnnouncementByPeer {
            let (idHex, pkt) = pair
            let idBytes = Data(hexString: idHex) ?? Data()
            if !mightContain(idBytes) {
                var toSend = pkt
                toSend.ttl = 0
                delegate?.sendPacket(to: fromPeerID, packet: toSend)
            }
        }

        // 2) Broadcast messages: send all missing
        let toSendMsgs = messageOrder.compactMap { messages[$0] }
        for pkt in toSendMsgs {
            let idBytes = PacketIdUtil.computeId(pkt)
            if !mightContain(idBytes) {
                var toSend = pkt
                toSend.ttl = 0
                delegate?.sendPacket(to: fromPeerID, packet: toSend)
            }
        }
    }

    // Build REQUEST_SYNC payload using current candidates and GCS params
    private func buildGcsPayload() -> Data {
        // Collect candidates: latest announce per peer + broadcast messages
        var candidates: [BitchatPacket] = []
        candidates.reserveCapacity(latestAnnouncementByPeer.count + messageOrder.count)
        for (_, pair) in latestAnnouncementByPeer { candidates.append(pair.packet) }
        for id in messageOrder { if let p = messages[id] { candidates.append(p) } }
        // Sort by timestamp desc
        candidates.sort { $0.timestamp > $1.timestamp }

        let p = GCSFilter.deriveP(targetFpr: config.gcsTargetFpr)
        let nMax = GCSFilter.estimateMaxElements(sizeBytes: config.gcsMaxBytes, p: p)
        let cap = max(1, config.seenCapacity)
        let takeN = min(candidates.count, min(nMax, cap))
        if takeN <= 0 {
            let req = RequestSyncPacket(p: p, m: 1, data: Data())
            return req.encode()
        }
        let ids: [Data] = candidates.prefix(takeN).map { PacketIdUtil.computeId($0) }
        let params = GCSFilter.buildFilter(ids: ids, maxBytes: config.gcsMaxBytes, targetFpr: config.gcsTargetFpr)
        let req = RequestSyncPacket(p: params.p, m: params.m, data: params.data)
        return req.encode()
    }

    // Explicit removal hook for LEAVE/stale peer
    func removeAnnouncementForPeer(_ peerID: String) {
        let normalizedPeerID = peerID.lowercased()
        _ = latestAnnouncementByPeer.removeValue(forKey: normalizedPeerID)
        
        // Remove messages from this peer
        // Collect IDs to remove first to avoid concurrent modification
        let messageIdsToRemove = messages.compactMap { (id, message) -> String? in
            message.senderID.hexEncodedString().lowercased() == normalizedPeerID ? id : nil
        }
        
        // Remove messages and update messageOrder
        for id in messageIdsToRemove {
            messages.removeValue(forKey: id)
            messageOrder.removeAll { $0 == id }
        }
    }
}
