import Foundation
import BitLogger

// Gossip-based sync manager using on-demand GCS filters
final class GossipSyncManager {
    protocol Delegate: AnyObject {
        func sendPacket(_ packet: BitchatPacket)
        func sendPacket(to peerID: PeerID, packet: BitchatPacket)
        func signPacketForBroadcast(_ packet: BitchatPacket) -> BitchatPacket
        func getConnectedPeers() -> [PeerID]
    }

    private struct PacketStore {
        private(set) var packets: [String: BitchatPacket] = [:]
        private(set) var order: [String] = []

        mutating func insert(idHex: String, packet: BitchatPacket, capacity: Int) {
            guard capacity > 0 else { return }
            if packets[idHex] != nil {
                packets[idHex] = packet
                return
            }
            packets[idHex] = packet
            order.append(idHex)
            while order.count > capacity {
                let victim = order.removeFirst()
                packets.removeValue(forKey: victim)
            }
        }

        func allPackets(isFresh: (BitchatPacket) -> Bool) -> [BitchatPacket] {
            order.compactMap { key in
                guard let packet = packets[key], isFresh(packet) else { return nil }
                return packet
            }
        }

        mutating func remove(where shouldRemove: (BitchatPacket) -> Bool) {
            var nextOrder: [String] = []
            for key in order {
                guard let packet = packets[key] else { continue }
                if shouldRemove(packet) {
                    packets.removeValue(forKey: key)
                } else {
                    nextOrder.append(key)
                }
            }
            order = nextOrder
        }

        mutating func removeExpired(isFresh: (BitchatPacket) -> Bool) {
            remove { !isFresh($0) }
        }
    }

    private struct SyncSchedule {
        let types: SyncTypeFlags
        let interval: TimeInterval
        var lastSent: Date
    }

    struct Config {
        var seenCapacity: Int = 1000          // max packets per sync (cap across types)
        var gcsMaxBytes: Int = 400           // filter size budget (128..1024)
        var gcsTargetFpr: Double = 0.01      // 1%
        var maxMessageAgeSeconds: TimeInterval = 900  // 15 min - discard older messages
        var maintenanceIntervalSeconds: TimeInterval = 30.0
        var stalePeerCleanupIntervalSeconds: TimeInterval = 60.0
        var stalePeerTimeoutSeconds: TimeInterval = 60.0
        var fragmentCapacity: Int = 600
        var fileTransferCapacity: Int = 200
        var fragmentSyncIntervalSeconds: TimeInterval = 30.0
        var fileTransferSyncIntervalSeconds: TimeInterval = 60.0
        var messageSyncIntervalSeconds: TimeInterval = 15.0
    }

    private let myPeerID: PeerID
    private let config: Config
    private let requestSyncManager: RequestSyncManager
    weak var delegate: Delegate?

    // Storage: broadcast packets by type, and latest announce per sender
    private var messages = PacketStore()
    private var fragments = PacketStore()
    private var fileTransfers = PacketStore()
    private var latestAnnouncementByPeer: [PeerID: (id: String, packet: BitchatPacket)] = [:]

    // Timer
    private var periodicTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mesh.sync", qos: .utility)
    private var lastStalePeerCleanup: Date = .distantPast
    private var syncSchedules: [SyncSchedule] = []

    init(myPeerID: PeerID, config: Config = Config(), requestSyncManager: RequestSyncManager) {
        self.myPeerID = myPeerID
        self.config = config
        self.requestSyncManager = requestSyncManager
        var schedules: [SyncSchedule] = []
        if config.seenCapacity > 0 && config.messageSyncIntervalSeconds > 0 {
            schedules.append(SyncSchedule(types: .publicMessages, interval: config.messageSyncIntervalSeconds, lastSent: .distantPast))
        }
        if config.fragmentCapacity > 0 && config.fragmentSyncIntervalSeconds > 0 {
            schedules.append(SyncSchedule(types: .fragment, interval: config.fragmentSyncIntervalSeconds, lastSent: .distantPast))
        }
        if config.fileTransferCapacity > 0 && config.fileTransferSyncIntervalSeconds > 0 {
            schedules.append(SyncSchedule(types: .fileTransfer, interval: config.fileTransferSyncIntervalSeconds, lastSent: .distantPast))
        }
        syncSchedules = schedules
    }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(0.1, config.maintenanceIntervalSeconds)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.performPeriodicMaintenance()
        }
        timer.resume()
        periodicTimer = timer
    }

    func stop() {
        periodicTimer?.cancel(); periodicTimer = nil
    }

    func scheduleInitialSyncToPeer(_ peerID: PeerID, delaySeconds: TimeInterval = 5.0) {
        queue.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self = self else { return }
            self.sendRequestSync(to: peerID, types: .publicMessages)
            if self.config.fragmentCapacity > 0 && self.config.fragmentSyncIntervalSeconds > 0 {
                self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.sendRequestSync(to: peerID, types: .fragment)
                }
            }
            if self.config.fileTransferCapacity > 0 && self.config.fileTransferSyncIntervalSeconds > 0 {
                self.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.sendRequestSync(to: peerID, types: .fileTransfer)
                }
            }
        }
    }

    func onPublicPacketSeen(_ packet: BitchatPacket) {
        queue.async { [weak self] in
            self?._onPublicPacketSeen(packet)
        }
    }

    // Helper to check if a packet is within the age threshold
    private func isPacketFresh(_ packet: BitchatPacket) -> Bool {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let ageThresholdMs = UInt64(config.maxMessageAgeSeconds * 1000)

        // If current time is less than threshold, accept all (handle clock issues gracefully)
        guard nowMs >= ageThresholdMs else { return true }

        let cutoffMs = nowMs - ageThresholdMs
        return packet.timestamp >= cutoffMs
    }

    private func isAnnouncementFresh(_ packet: BitchatPacket) -> Bool {
        guard config.stalePeerTimeoutSeconds > 0 else { return true }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let timeoutMs = UInt64(config.stalePeerTimeoutSeconds * 1000)
        guard nowMs >= timeoutMs else { return true }
        let cutoffMs = nowMs - timeoutMs
        return packet.timestamp >= cutoffMs
    }

    private func _onPublicPacketSeen(_ packet: BitchatPacket) {
        guard let messageType = MessageType(rawValue: packet.type) else { return }
        let isBroadcastRecipient: Bool = {
            guard let r = packet.recipientID else { return true }
            return r.count == 8 && r.allSatisfy { $0 == 0xFF }
        }()

        switch messageType {
        case .announce:
            guard isPacketFresh(packet) else { return }
            guard isAnnouncementFresh(packet) else {
                let sender = PeerID(hexData: packet.senderID)
                removeState(for: sender)
                return
            }
            let idHex = PacketIdUtil.computeId(packet).hexEncodedString()
            let sender = PeerID(hexData: packet.senderID)
            latestAnnouncementByPeer[sender] = (id: idHex, packet: packet)
        case .message:
            guard isBroadcastRecipient else { return }
            guard isPacketFresh(packet) else { return }
            let idHex = PacketIdUtil.computeId(packet).hexEncodedString()
            messages.insert(idHex: idHex, packet: packet, capacity: max(1, config.seenCapacity))
        case .fragment:
            guard isBroadcastRecipient else { return }
            guard isPacketFresh(packet) else { return }
            let idHex = PacketIdUtil.computeId(packet).hexEncodedString()
            fragments.insert(idHex: idHex, packet: packet, capacity: max(1, config.fragmentCapacity))
        case .fileTransfer:
            guard isBroadcastRecipient else { return }
            guard isPacketFresh(packet) else { return }
            let idHex = PacketIdUtil.computeId(packet).hexEncodedString()
            fileTransfers.insert(idHex: idHex, packet: packet, capacity: max(1, config.fileTransferCapacity))
        default:
            break
        }
    }

    private func sendPeriodicSync(for types: SyncTypeFlags) {
        // Unicast sync to connected peers to allow RSR attribution
        if let connectedPeers = delegate?.getConnectedPeers(), !connectedPeers.isEmpty {
            SecureLogger.debug("Sending periodic sync to \(connectedPeers.count) connected peers", category: .sync)
            for peerID in connectedPeers {
                sendRequestSync(to: peerID, types: types)
            }
        } else {
            // Fallback to broadcast (discovery phase)
            sendRequestSync(for: types)
        }
    }

    private func sendRequestSync(for types: SyncTypeFlags) {
        let payload = buildGcsPayload(for: types)
        let pkt = BitchatPacket(
            type: MessageType.requestSync.rawValue,
            senderID: Data(hexString: myPeerID.id) ?? Data(),
            recipientID: nil, // broadcast
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 0 // local-only
        )
        let signed = delegate?.signPacketForBroadcast(pkt) ?? pkt
        delegate?.sendPacket(signed)
    }

    private func sendRequestSync(to peerID: PeerID, types: SyncTypeFlags) {
        // Register the request for RSR validation
        requestSyncManager.registerRequest(to: peerID)
        
        let payload = buildGcsPayload(for: types)
        var recipient = Data()
        var temp = peerID.id
        while temp.count >= 2 && recipient.count < 8 {
            let hexByte = String(temp.prefix(2))
            if let b = UInt8(hexByte, radix: 16) { recipient.append(b) }
            temp = String(temp.dropFirst(2))
        }
        let pkt = BitchatPacket(
            type: MessageType.requestSync.rawValue,
            senderID: Data(hexString: myPeerID.id) ?? Data(),
            recipientID: recipient,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 0 // local-only
        )
        let signed = delegate?.signPacketForBroadcast(pkt) ?? pkt
        delegate?.sendPacket(to: peerID, packet: signed)
    }

    func handleRequestSync(from peerID: PeerID, request: RequestSyncPacket) {
        queue.async { [weak self] in
            self?._handleRequestSync(from: peerID, request: request)
        }
    }

    private func _handleRequestSync(from peerID: PeerID, request: RequestSyncPacket) {
        let requestedTypes = (request.types ?? .publicMessages)
        // Decode GCS into sorted set and prepare membership checker
        let sorted = GCSFilter.decodeToSortedSet(p: request.p, m: request.m, data: request.data)
        func mightContain(_ id: Data) -> Bool {
            let bucket = GCSFilter.bucket(for: id, modulus: request.m)
            return GCSFilter.contains(sortedValues: sorted, candidate: bucket)
        }

        if requestedTypes.contains(.announce) {
            for (_, pair) in latestAnnouncementByPeer {
                let (idHex, pkt) = pair
                guard isPacketFresh(pkt) else { continue }
                let idBytes = Data(hexString: idHex) ?? Data()
                if !mightContain(idBytes) {
                    var toSend = pkt
                    toSend.ttl = 0
                    toSend.isRSR = true // Mark as solicited response
                    delegate?.sendPacket(to: peerID, packet: toSend)
                }
            }
        }

        if requestedTypes.contains(.message) {
            let toSendMsgs = messages.allPackets(isFresh: isPacketFresh)
            for pkt in toSendMsgs {
                let idBytes = PacketIdUtil.computeId(pkt)
                if !mightContain(idBytes) {
                    var toSend = pkt
                    toSend.ttl = 0
                    toSend.isRSR = true // Mark as solicited response
                    delegate?.sendPacket(to: peerID, packet: toSend)
                }
            }
        }

        if requestedTypes.contains(.fragment) {
            let frags = fragments.allPackets(isFresh: isPacketFresh)
            for pkt in frags {
                let idBytes = PacketIdUtil.computeId(pkt)
                if !mightContain(idBytes) {
                    var toSend = pkt
                    toSend.ttl = 0
                    toSend.isRSR = true // Mark as solicited response
                    delegate?.sendPacket(to: peerID, packet: toSend)
                }
            }
        }

        if requestedTypes.contains(.fileTransfer) {
            let files = fileTransfers.allPackets(isFresh: isPacketFresh)
            for pkt in files {
                let idBytes = PacketIdUtil.computeId(pkt)
                if !mightContain(idBytes) {
                    var toSend = pkt
                    toSend.ttl = 0
                    toSend.isRSR = true // Mark as solicited response
                    delegate?.sendPacket(to: peerID, packet: toSend)
                }
            }
        }
    }

    // Build REQUEST_SYNC payload using current candidates and GCS params
    private func buildGcsPayload(for types: SyncTypeFlags) -> Data {
        var candidates: [BitchatPacket] = []
        if types.contains(.announce) {
            for (_, pair) in latestAnnouncementByPeer where isPacketFresh(pair.packet) {
                candidates.append(pair.packet)
            }
        }
        if types.contains(.message) {
            candidates.append(contentsOf: messages.allPackets(isFresh: isPacketFresh))
        }
        if types.contains(.fragment) {
            candidates.append(contentsOf: fragments.allPackets(isFresh: isPacketFresh))
        }
        if types.contains(.fileTransfer) {
            candidates.append(contentsOf: fileTransfers.allPackets(isFresh: isPacketFresh))
        }
        if candidates.isEmpty {
            let p = GCSFilter.deriveP(targetFpr: config.gcsTargetFpr)
            let req = RequestSyncPacket(p: p, m: 1, data: Data(), types: types)
            return req.encode()
        }

        // Sort by timestamp desc
        candidates.sort { $0.timestamp > $1.timestamp }

        let p = GCSFilter.deriveP(targetFpr: config.gcsTargetFpr)
        let nMax = GCSFilter.estimateMaxElements(sizeBytes: config.gcsMaxBytes, p: p)
        let cap: Int
        if types == .fragment {
            cap = max(1, config.fragmentCapacity)
        } else if types == .fileTransfer {
            cap = max(1, config.fileTransferCapacity)
        } else {
            cap = max(1, config.seenCapacity)
        }
        let takeN = min(candidates.count, min(nMax, cap))
        if takeN <= 0 {
            let req = RequestSyncPacket(p: p, m: 1, data: Data(), types: types)
            return req.encode()
        }
        let ids: [Data] = candidates.prefix(takeN).map { PacketIdUtil.computeId($0) }
        let params = GCSFilter.buildFilter(ids: ids, maxBytes: config.gcsMaxBytes, targetFpr: config.gcsTargetFpr)
        let req = RequestSyncPacket(p: params.p, m: params.m, data: params.data, types: types)
        return req.encode()
    }

    // Periodic cleanup of expired messages and announcements
    private func cleanupExpiredMessages() {
        // Remove expired announcements
        latestAnnouncementByPeer = latestAnnouncementByPeer.filter { _, pair in
            isPacketFresh(pair.packet)
        }

        messages.removeExpired(isFresh: isPacketFresh)
        fragments.removeExpired(isFresh: isPacketFresh)
        fileTransfers.removeExpired(isFresh: isPacketFresh)
    }

    private func performPeriodicMaintenance(now: Date = Date()) {
        cleanupExpiredMessages()
        cleanupStaleAnnouncementsIfNeeded(now: now)
        requestSyncManager.cleanup() // Cleanup expired sync requests
        
        for index in syncSchedules.indices {
            guard syncSchedules[index].interval > 0 else { continue }
            if syncSchedules[index].lastSent == .distantPast || now.timeIntervalSince(syncSchedules[index].lastSent) >= syncSchedules[index].interval {
                syncSchedules[index].lastSent = now
                sendPeriodicSync(for: syncSchedules[index].types)
            }
        }
    }

    private func cleanupStaleAnnouncementsIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastStalePeerCleanup) >= config.stalePeerCleanupIntervalSeconds else {
            return
        }
        lastStalePeerCleanup = now
        cleanupStaleAnnouncements(now: now)
    }

    private func cleanupStaleAnnouncements(now: Date) {
        let timeoutMs = UInt64(config.stalePeerTimeoutSeconds * 1000)
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000)
        guard nowMs >= timeoutMs else { return }
        let cutoff = nowMs - timeoutMs
        let stalePeerIDs = latestAnnouncementByPeer.compactMap { peerID, pair in
            pair.packet.timestamp < cutoff ? peerID : nil
        }
        guard !stalePeerIDs.isEmpty else { return }
        for peerKey in stalePeerIDs {
            removeState(for: peerKey)
        }
    }

    // Explicit removal hook for LEAVE/stale peer
    func removeAnnouncementForPeer(_ peerID: PeerID) {
        queue.async { [weak self] in
            self?.removeState(for: peerID)
        }
    }

    private func removeState(for peerID: PeerID) {
        _ = latestAnnouncementByPeer.removeValue(forKey: peerID)
        messages.remove { PeerID(hexData: $0.senderID) == peerID }
        fragments.remove { PeerID(hexData: $0.senderID) == peerID }
        fileTransfers.remove { PeerID(hexData: $0.senderID) == peerID }
    }
}

#if DEBUG
extension GossipSyncManager {
    func _performMaintenanceSynchronously(now: Date = Date()) {
        queue.sync {
            performPeriodicMaintenance(now: now)
        }
    }

    func _hasAnnouncement(for peerID: PeerID) -> Bool {
        queue.sync {
            latestAnnouncementByPeer[peerID] != nil
        }
    }

    func _messageCount(for peerID: PeerID) -> Int {
        queue.sync {
            messages.allPackets { _ in true }.filter { PeerID(hexData: $0.senderID) == peerID }.count
        }
    }
}
#endif
