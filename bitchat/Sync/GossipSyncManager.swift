import Foundation
import BitLogger
import BitFoundation

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
        var maxMessageAgeSeconds: TimeInterval = 900  // 15 min - fragments/files/announces
        // Whole public messages stay sync-able much longer so devices carry
        // the room's recent history between partitions and across restarts.
        var publicMessageMaxAgeSeconds: TimeInterval = 900
        var maintenanceIntervalSeconds: TimeInterval = 30.0
        var stalePeerCleanupIntervalSeconds: TimeInterval = 60.0
        var stalePeerTimeoutSeconds: TimeInterval = 60.0
        var fragmentCapacity: Int = 600
        var fileTransferCapacity: Int = 200
        var groupMessageCapacity: Int = 200
        var fragmentSyncIntervalSeconds: TimeInterval = 30.0
        var fileTransferSyncIntervalSeconds: TimeInterval = 60.0
        var messageSyncIntervalSeconds: TimeInterval = 15.0
        // Board posts are few but long-lived (days, until each post's own
        // expiry), so they get a slow round with their own capacity instead
        // of competing with the 15-minute message window.
        var boardCapacity: Int = 200
        var boardSyncIntervalSeconds: TimeInterval = 60.0
        var responseRateLimitMaxResponses: Int = 8
        var responseRateLimitWindowSeconds: TimeInterval = 30.0
        // Prekey bundles: one per peer, own sync round, long freshness so
        // bundles persist mesh-wide while their owners are offline.
        var prekeyBundleCapacity: Int = 200
        var prekeyBundleSyncIntervalSeconds: TimeInterval = 60.0
        var prekeyBundleMaxAgeSeconds: TimeInterval = 24 * 60 * 60
    }

    private let myPeerID: PeerID
    private let config: Config
    private let requestSyncManager: RequestSyncManager
    private let archive: GossipMessageArchive?
    weak var delegate: Delegate?

    /// Source of raw signed board packets (posts + tombstones). The board
    /// store is the single owner of board retention (expiry, tombstones,
    /// caps, persistence), so sync rounds query it instead of keeping a
    /// second copy here. Must be thread-safe; set before `start()`.
    var boardPacketsProvider: (() -> [BitchatPacket])?

    // Storage: broadcast packets by type, and latest announce per sender
    private var messages = PacketStore()
    private var fragments = PacketStore()
    private var fileTransfers = PacketStore()
    private var groupMessages = PacketStore()
    private var latestAnnouncementByPeer: [PeerID: BitchatPacket] = [:]
    // Latest verified prekey bundle per owner. Unlike announces, bundles are
    // NOT dropped on leave/stale peer: their whole purpose is reaching a
    // sender while the owner is away.
    private var latestPrekeyBundleByPeer: [PeerID: (id: String, packet: BitchatPacket)] = [:]
    private var archiveDirty = false

    // Timer
    private var periodicTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mesh.sync", qos: .utility)
    private var lastStalePeerCleanup: Date = .distantPast
    private var syncSchedules: [SyncSchedule] = []
    private var responseRateLimiter: SyncResponseRateLimiter

    init(myPeerID: PeerID, config: Config = Config(), requestSyncManager: RequestSyncManager, archive: GossipMessageArchive? = nil) {
        self.myPeerID = myPeerID
        self.config = config
        self.requestSyncManager = requestSyncManager
        self.archive = archive
        self.responseRateLimiter = SyncResponseRateLimiter(
            maxResponses: config.responseRateLimitMaxResponses,
            window: config.responseRateLimitWindowSeconds
        )
        var schedules: [SyncSchedule] = []
        if config.seenCapacity > 0 && config.messageSyncIntervalSeconds > 0 {
            // Group messages ride the public-message cadence; old clients
            // ignore the extended bit and answer with announces/messages only.
            var messageTypes: SyncTypeFlags = .publicMessages
            if config.groupMessageCapacity > 0 {
                messageTypes.formUnion(.groupMessage)
            }
            schedules.append(SyncSchedule(types: messageTypes, interval: config.messageSyncIntervalSeconds, lastSent: .distantPast))
        }
        if config.fragmentCapacity > 0 && config.fragmentSyncIntervalSeconds > 0 {
            schedules.append(SyncSchedule(types: .fragment, interval: config.fragmentSyncIntervalSeconds, lastSent: .distantPast))
        }
        if config.fileTransferCapacity > 0 && config.fileTransferSyncIntervalSeconds > 0 {
            schedules.append(SyncSchedule(types: .fileTransfer, interval: config.fileTransferSyncIntervalSeconds, lastSent: .distantPast))
        }
        if config.prekeyBundleCapacity > 0 && config.prekeyBundleSyncIntervalSeconds > 0 {
            schedules.append(SyncSchedule(types: .prekeyBundle, interval: config.prekeyBundleSyncIntervalSeconds, lastSent: .distantPast))
        }
        if config.boardCapacity > 0 && config.boardSyncIntervalSeconds > 0 {
            schedules.append(SyncSchedule(types: .board, interval: config.boardSyncIntervalSeconds, lastSent: .distantPast))
        }
        syncSchedules = schedules

        if archive != nil {
            queue.async { [weak self] in
                self?.restoreArchivedMessages()
            }
        }
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

            var types: SyncTypeFlags = .publicMessages
            if self.config.groupMessageCapacity > 0 {
                types.formUnion(.groupMessage)
            }
            if self.config.fragmentCapacity > 0 && self.config.fragmentSyncIntervalSeconds > 0 {
                types.formUnion(.fragment)
            }
            if self.config.fileTransferCapacity > 0 && self.config.fileTransferSyncIntervalSeconds > 0 {
                types.formUnion(.fileTransfer)
            }
            if self.config.prekeyBundleCapacity > 0 && self.config.prekeyBundleSyncIntervalSeconds > 0 {
                types.formUnion(.prekeyBundle)
            }
            if self.config.boardCapacity > 0 && self.config.boardSyncIntervalSeconds > 0 && self.boardPacketsProvider != nil {
                types.formUnion(.board)
            }
            self.sendRequestSync(to: peerID, types: types)
        }
    }

    func onPublicPacketSeen(_ packet: BitchatPacket) {
        queue.async { [weak self] in
            self?._onPublicPacketSeen(packet)
        }
    }

    // Helper to check if a packet is within the age threshold. Whole public
    // messages get the long town-crier window; fragments, file transfers and
    // announces keep the short one.
    private func isPacketFresh(_ packet: BitchatPacket) -> Bool {
        // Group messages share the whole-message window: members off the mesh
        // for a while should backfill their crew's history like public chat.
        let maxAgeSeconds: TimeInterval
        switch packet.type {
        case MessageType.message.rawValue, MessageType.groupMessage.rawValue:
            maxAgeSeconds = config.publicMessageMaxAgeSeconds
        case MessageType.prekeyBundle.rawValue:
            maxAgeSeconds = config.prekeyBundleMaxAgeSeconds
        default:
            maxAgeSeconds = config.maxMessageAgeSeconds
        }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let ageThresholdMs = UInt64(maxAgeSeconds * 1000)

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
            let sender = PeerID(hexData: packet.senderID)
            latestAnnouncementByPeer[sender] = packet
        case .message:
            guard isBroadcastRecipient else { return }
            guard isPacketFresh(packet) else { return }
            let idHex = PacketIdUtil.computeId(packet).hexEncodedString()
            messages.insert(idHex: idHex, packet: packet, capacity: max(1, config.seenCapacity))
            archiveDirty = true
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
        case .groupMessage:
            // Opaque ciphertext to non-members; carried and served like any
            // other broadcast so members get backfill from any relay.
            guard isBroadcastRecipient else { return }
            guard isPacketFresh(packet) else { return }
            let idHex = PacketIdUtil.computeId(packet).hexEncodedString()
            groupMessages.insert(idHex: idHex, packet: packet, capacity: max(1, config.groupMessageCapacity))
        case .prekeyBundle:
            // Callers only feed verified bundles here (own bundles at send
            // time, peers' after signature verification), so gossip never
            // spreads a bundle this node couldn't attribute.
            guard isBroadcastRecipient else { return }
            guard isPacketFresh(packet) else { return }
            // Key by the bundle's authenticated identity (its noise static key),
            // NOT the unauthenticated packet senderID. Otherwise one valid
            // bundle re-broadcast under many fabricated sender IDs would create
            // one cache entry each and exhaust the per-owner cap, starving
            // legitimate bundles. One owner ⇒ at most one entry.
            guard let bundle = PrekeyBundle.decode(packet.payload) else { return }
            let owner = PeerID(publicKey: bundle.noiseStaticPublicKey)
            if let existing = latestPrekeyBundleByPeer[owner],
               existing.packet.timestamp >= packet.timestamp {
                return
            }
            // Bounded owner count; replacing a known owner's bundle is always
            // allowed so the cap can't block refreshes.
            guard latestPrekeyBundleByPeer[owner] != nil
                    || latestPrekeyBundleByPeer.count < max(1, config.prekeyBundleCapacity) else { return }
            let idHex = PacketIdUtil.computeId(packet).hexEncodedString()
            latestPrekeyBundleByPeer[owner] = (id: idHex, packet: packet)
        default:
            break
        }
    }

    private func sendPeriodicSync(for types: SyncTypeFlags) {
        // Unicast sync to connected peers to allow RSR attribution
        if let connectedPeers = delegate?.getConnectedPeers(), !connectedPeers.isEmpty {
            SecureLogger.debug("Sending periodic sync (\(types.logDescription)) to \(connectedPeers.count) connected peers", category: .sync)
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

    /// Targeted fragment recovery: ask connected peers for the specific
    /// fragment streams whose reassembly has stalled, instead of waiting on
    /// the next periodic GCS fragment round to cover them.
    func requestMissingFragments(fragmentIDs: [Data]) {
        queue.async { [weak self] in
            self?._requestMissingFragments(fragmentIDs)
        }
    }

    private func _requestMissingFragments(_ fragmentIDs: [Data]) {
        guard let filter = RequestSyncPacket.encodeFragmentIdFilter(fragmentIDs) else { return }
        guard let connectedPeers = delegate?.getConnectedPeers(), !connectedPeers.isEmpty else { return }
        SecureLogger.debug("Requesting \(fragmentIDs.count) stalled fragment stream(s) from \(connectedPeers.count) peer(s)", category: .sync)
        for peerID in connectedPeers {
            sendRequestSync(to: peerID, types: .fragment, fragmentIdFilter: filter)
        }
    }

    private func sendRequestSync(to peerID: PeerID, types: SyncTypeFlags, fragmentIdFilter: String? = nil) {
        // Register the request for RSR validation
        requestSyncManager.registerRequest(to: peerID)

        let payload = buildGcsPayload(for: types, fragmentIdFilter: fragmentIdFilter)
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
        // A response can replay the whole store, so bound how often one peer
        // can trigger a diff pass regardless of how fast it asks.
        guard responseRateLimiter.shouldRespond(to: peerID, now: Date()) else {
            SecureLogger.warning("Rate-limited REQUEST_SYNC from \(peerID.id.prefix(8))…", category: .sync)
            return
        }
        let requestedTypes = (request.types ?? .publicMessages)
        // The requester's filter only covers packets at or after this cursor;
        // older packets are outside the filter but not missing, and without
        // the cursor they would be re-sent every round.
        let since = request.sinceTimestamp
        // Decode GCS into sorted set and prepare membership checker
        let sorted = GCSFilter.decodeToSortedSet(p: request.p, m: request.m, data: request.data)
        func mightContain(_ id: Data) -> Bool {
            let bucket = GCSFilter.bucket(for: id, modulus: request.m)
            return GCSFilter.contains(sortedValues: sorted, candidate: bucket)
        }

        // Announces are exempt from the since-cursor: they carry the signing
        // keys needed to verify everything else, and there is at most one per
        // peer, so the resend cost is negligible.
        if requestedTypes.contains(.announce) {
            for (_, pkt) in latestAnnouncementByPeer {
                guard isPacketFresh(pkt) else { continue }
                let idBytes = PacketIdUtil.computeId(pkt)
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
                if let since, pkt.timestamp < since { continue }
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
            // A fragment-ID filter narrows the diff to exactly the named
            // fragment streams (targeted resync for stalled reassemblies)
            // and bypasses the since-cursor for them; the GCS filter still
            // excludes the pieces the requester already holds. Fragment
            // payloads start with the 8-byte stream ID.
            let fragmentIdFilter = RequestSyncPacket.decodeFragmentIdFilter(request.fragmentIdFilter)
            let frags = fragments.allPackets(isFresh: isPacketFresh)
            for pkt in frags {
                if let fragmentIdFilter {
                    guard fragmentIdFilter.contains(Data(pkt.payload.prefix(8))) else { continue }
                } else if let since, pkt.timestamp < since {
                    continue
                }
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
                if let since, pkt.timestamp < since { continue }
                let idBytes = PacketIdUtil.computeId(pkt)
                if !mightContain(idBytes) {
                    var toSend = pkt
                    toSend.ttl = 0
                    toSend.isRSR = true // Mark as solicited response
                    delegate?.sendPacket(to: peerID, packet: toSend)
                }
            }
        }

        if requestedTypes.contains(.groupMessage) {
            let groupPkts = groupMessages.allPackets(isFresh: isPacketFresh)
            for pkt in groupPkts {
                if let since, pkt.timestamp < since { continue }
                let idBytes = PacketIdUtil.computeId(pkt)
                if !mightContain(idBytes) {
                    var toSend = pkt
                    toSend.ttl = 0
                    toSend.isRSR = true // Mark as solicited response
                    delegate?.sendPacket(to: peerID, packet: toSend)
                }
            }
        }
        // Like announces, prekey bundles are exempt from the since-cursor:
        // there is at most one per owner (newer replaces older), so the
        // resend cost is bounded and a joining peer must be able to learn
        // bundles generated long before it arrived.
        if requestedTypes.contains(.prekeyBundle) {
            for (_, pair) in latestPrekeyBundleByPeer {
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
        if requestedTypes.contains(.boardPost) {
            // The board store already filters to live posts and tombstones;
            // no freshness window applies (posts sync until their own expiry).
            let boardPackets = boardPacketsProvider?() ?? []
            for pkt in boardPackets {
                if let since, pkt.timestamp < since { continue }
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
    private func buildGcsPayload(for types: SyncTypeFlags, fragmentIdFilter: String? = nil) -> Data {
        var candidates: [BitchatPacket] = []
        if types.contains(.announce) {
            for (_, pkt) in latestAnnouncementByPeer where isPacketFresh(pkt) {
                candidates.append(pkt)
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
        if types.contains(.groupMessage) {
            candidates.append(contentsOf: groupMessages.allPackets(isFresh: isPacketFresh))
        }
        if types.contains(.prekeyBundle) {
            for (_, pair) in latestPrekeyBundleByPeer where isPacketFresh(pair.packet) {
                candidates.append(pair.packet)
            }
        }
        if types.contains(.boardPost) {
            candidates.append(contentsOf: boardPacketsProvider?() ?? [])
        }
        if candidates.isEmpty {
            let p = GCSFilter.deriveP(targetFpr: config.gcsTargetFpr)
            let req = RequestSyncPacket(p: p, m: 1, data: Data(), types: types, fragmentIdFilter: fragmentIdFilter)
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
        } else if types == .prekeyBundle {
            cap = max(1, config.prekeyBundleCapacity)
        } else if types == .board {
            cap = max(1, config.boardCapacity)
        } else {
            cap = max(1, config.seenCapacity)
        }
        let takeN = min(candidates.count, min(nMax, cap))
        if takeN <= 0 {
            let req = RequestSyncPacket(p: p, m: 1, data: Data(), types: types, fragmentIdFilter: fragmentIdFilter)
            return req.encode()
        }
        let included = Array(candidates.prefix(takeN))
        let ids: [Data] = included.map { PacketIdUtil.computeId($0) }
        let params = GCSFilter.buildFilter(ids: ids, maxBytes: config.gcsMaxBytes, targetFpr: config.gcsTargetFpr)
        // When the filter can't cover every candidate — either the store
        // exceeds `takeN` or the encoder trimmed the tail to fit the byte
        // budget — tell the responder how far back the filter actually
        // reaches. `includedCount` counts inputs in newest-first order, so the
        // covered set is a contiguous newest-prefix and the oldest included
        // timestamp is an exact cursor. Packets older than it are outside the
        // filter but not missing; without the cursor the responder would
        // re-send that entire tail every round.
        let covered = params.includedCount
        let sinceTimestamp: UInt64? = (covered < candidates.count && covered > 0)
            ? included[covered - 1].timestamp
            : nil
        let req = RequestSyncPacket(p: params.p, m: params.m, data: params.data, types: types, sinceTimestamp: sinceTimestamp, fragmentIdFilter: fragmentIdFilter)
        return req.encode()
    }

    // Periodic cleanup of expired messages and announcements
    private func cleanupExpiredMessages() {
        // Remove expired announcements
        latestAnnouncementByPeer = latestAnnouncementByPeer.filter { _, pkt in
            isPacketFresh(pkt)
        }

        let messageCountBefore = messages.packets.count
        messages.removeExpired(isFresh: isPacketFresh)
        if messages.packets.count != messageCountBefore {
            archiveDirty = true
        }
        fragments.removeExpired(isFresh: isPacketFresh)
        fileTransfers.removeExpired(isFresh: isPacketFresh)
        groupMessages.removeExpired(isFresh: isPacketFresh)
        latestPrekeyBundleByPeer = latestPrekeyBundleByPeer.filter { _, pair in
            isPacketFresh(pair.packet)
        }
    }

    // MARK: - Archive (public message persistence)

    /// Rebuild the public message store from disk on launch, dropping
    /// anything that aged out while the app was dead.
    private func restoreArchivedMessages() {
        guard let archive else { return }
        var restored = 0
        for data in archive.load() {
            guard let packet = BitchatPacket.from(data),
                  packet.type == MessageType.message.rawValue,
                  isPacketFresh(packet) else { continue }
            let idHex = PacketIdUtil.computeId(packet).hexEncodedString()
            messages.insert(idHex: idHex, packet: packet, capacity: max(1, config.seenCapacity))
            restored += 1
        }
        if restored > 0 {
            SecureLogger.debug("Restored \(restored) archived public message(s) for gossip sync", category: .sync)
            archiveDirty = true
        }
    }

    private func persistArchiveIfDirty() {
        guard archiveDirty, let archive else { return }
        archiveDirty = false
        let packets = messages.allPackets(isFresh: isPacketFresh)
            .compactMap { $0.toBinaryData(padding: false) }
        archive.save(packets)
    }

    /// Flush the archive outside the maintenance cadence (app backgrounding).
    func persistNow() {
        queue.async { [weak self] in
            self?.persistArchiveIfDirty()
        }
    }

    /// Snapshot of the carried public-message packets (fresh window only),
    /// for the "heard here earlier" timeline echoes. Completion runs on the
    /// sync queue.
    func collectPublicMessagePackets(completion: @escaping ([BitchatPacket]) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion([])
                return
            }
            completion(self.messages.allPackets(isFresh: self.isPacketFresh))
        }
    }

    private func performPeriodicMaintenance(now: Date = Date()) {
        cleanupExpiredMessages()
        cleanupStaleAnnouncementsIfNeeded(now: now)
        persistArchiveIfDirty()
        requestSyncManager.cleanup() // Cleanup expired sync requests
        responseRateLimiter.prune(now: now)
        
        // One request per due schedule rather than a union filter: each type
        // group gets the full GCS capacity and its own since-cursor, so heavy
        // fragment traffic can't crowd messages out of the filter.
        for index in syncSchedules.indices {
            guard syncSchedules[index].interval > 0 else { continue }
            // No board source wired up means nothing to offer or store;
            // skip the round entirely.
            if syncSchedules[index].types == .board && boardPacketsProvider == nil { continue }
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
        let stalePeerIDs = latestAnnouncementByPeer.compactMap { peerID, pkt in
            pkt.timestamp < cutoff ? peerID : nil
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

    /// Block-time hygiene: drop the carried public messages from a blocked
    /// sender and persist immediately, so nothing of theirs can resurface as
    /// an archived echo on the next launch. Narrower than `removeState(for:)`
    /// — the peer's announcement and in-flight fragments are untouched.
    func removePublicMessages(from peerID: PeerID) {
        queue.async { [weak self] in
            guard let self else { return }
            let countBefore = self.messages.packets.count
            self.messages.remove { PeerID(hexData: $0.senderID) == peerID }
            guard self.messages.packets.count != countBefore else { return }
            self.archiveDirty = true
            // Persist now rather than waiting for maintenance: a relaunch in
            // the gap would restore the purged messages from disk.
            self.persistArchiveIfDirty()
        }
    }

    private func removeState(for peerID: PeerID) {
        // Deliberately keeps the peer's prekey bundle: bundles exist to reach
        // owners who left the mesh, and they age out on their own schedule.
        _ = latestAnnouncementByPeer.removeValue(forKey: peerID)
        let messageCountBefore = messages.packets.count
        messages.remove { PeerID(hexData: $0.senderID) == peerID }
        if messages.packets.count != messageCountBefore {
            archiveDirty = true
        }
        fragments.remove { PeerID(hexData: $0.senderID) == peerID }
        fileTransfers.remove { PeerID(hexData: $0.senderID) == peerID }
        groupMessages.remove { PeerID(hexData: $0.senderID) == peerID }
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

    func _hasPrekeyBundle(for peerID: PeerID) -> Bool {
        queue.sync {
            latestPrekeyBundleByPeer[peerID] != nil
        }
    }

    func _messageCount(for peerID: PeerID) -> Int {
        queue.sync {
            messages.allPackets { _ in true }.filter { PeerID(hexData: $0.senderID) == peerID }.count
        }
    }
}
#endif
