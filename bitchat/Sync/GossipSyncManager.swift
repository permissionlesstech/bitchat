import Foundation

// Gossip-based sync manager using rotating Bloom filters
final class GossipSyncManager {
    protocol Delegate: AnyObject {
        func sendPacket(_ packet: BitchatPacket)
        func sendPacket(to peerID: String, packet: BitchatPacket)
        func signPacketForBroadcast(_ packet: BitchatPacket) -> BitchatPacket
    }

    struct Config {
        var seenCapacity: Int = 100          // recent broadcast messages kept
        var bloomMaxBytes: Int = 256         // up to 256 bytes
        var bloomTargetFpr: Double = 0.01    // 1%
    }

    private let myPeerID: String
    private let config: Config
    weak var delegate: Delegate?

    // Bloom filter
    private let bloom: SeenPacketsBloomFilter

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
        self.bloom = SeenPacketsBloomFilter(maxBytes: config.bloomMaxBytes, targetFpr: config.bloomTargetFpr)
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
        let isBroadcastMessage = (mt == .message && packet.recipientID == nil)
        let isAnnounce = (mt == .announce)
        guard isBroadcastMessage || isAnnounce else { return }

        let idBytes = PacketIdUtil.computeId(packet)
        bloom.add(idBytes)
        let idHex = idBytes.hexEncodedString()

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
        // Build a Bloom snapshot that excludes our own packets so peers will
        // consider our self-origin broadcasts as missing and send them back.
        let snap = buildSnapshotExcludingSelf()
        let payload = RequestSyncPacket(mBytes: snap.mBytes, k: snap.k, bits: snap.bits).encode()
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
        // Build a Bloom snapshot that excludes our own packets so the target
        // peer will send us our self-origin broadcasts during initial sync.
        let snap = buildSnapshotExcludingSelf()
        let payload = RequestSyncPacket(mBytes: snap.mBytes, k: snap.k, bits: snap.bits).encode()
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

    // Build a Bloom snapshot from our knowledge but excluding any packets that we originated.
    private func buildSnapshotExcludingSelf() -> SeenPacketsBloomFilter.Snapshot {
        // Reconstruct a Bloom with the same configuration, and add only others' packets we know.
        let temp = SeenPacketsBloomFilter(maxBytes: config.bloomMaxBytes, targetFpr: config.bloomTargetFpr)

        // 1) Latest announces per peer (exclude self)
        for (sender, pair) in latestAnnouncementByPeer {
            guard sender != myPeerID else { continue }
            let pkt = pair.packet
            let idBytes = PacketIdUtil.computeId(pkt)
            temp.add(idBytes)
        }

        // 2) Broadcast messages (exclude self)
        // Use the current order to avoid large dictionary iteration penalties
        for id in messageOrder {
            if let pkt = messages[id] {
                let sender = pkt.senderID.hexEncodedString()
                if sender == myPeerID { continue }
                let idBytes = PacketIdUtil.computeId(pkt)
                temp.add(idBytes)
            }
        }

        return temp.snapshotActive()
    }

    func handleRequestSync(fromPeerID: String, request: RequestSyncPacket) {
        // Build membership checker from provided parameters
        let mBits = request.mBytes * 8
        let k = request.k
        func mightContain(_ id: Data) -> Bool {
            // Same hashing as local bloom; compute indices, check MSB-first bits in request.bits
            var h1: UInt64 = 1469598103934665603
            var h2: UInt64 = 0x27d4eb2f165667c5
            for b in id { h1 = (h1 ^ UInt64(b)) &* 1099511628211; h2 = (h2 ^ UInt64(b)) &* 0x100000001B3 }
            for i in 0..<k {
                let combined = h1 &+ (UInt64(i) &* h2)
                let idx = Int((combined & 0x7fff_ffff_ffff_ffff) % UInt64(mBits))
                let byteIndex = idx / 8
                let bitIndex = idx % 8
                let byte = request.bits[byteIndex]
                let bit = ((Int(byte) >> (7 - bitIndex)) & 1) == 1
                if !bit { return false }
            }
            return true
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
}
