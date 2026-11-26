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
        func hasSyncTargets() -> Bool
    }

    private struct StoredEntry {
        let packet: BitchatPacket
        let hash64: UInt64
    }

    private struct PacketStore {
        private(set) var packets: [String: StoredEntry] = [:]
        private(set) var order: [String] = []
        /// Sum of retained payload sizes, maintained on every insert/remove.
        private var payloadBytes = 0

        /// Evicts oldest-first until both the count and the byte budget hold.
        /// The count cap alone let a few max-size packets per slot pin
        /// hundreds of MB; the budget bounds memory whatever the sizes.
        mutating func insert(idHex: String, hash64: UInt64, packet: BitchatPacket, capacity: Int, byteBudget: Int) {
            guard capacity > 0, packet.payload.count <= byteBudget else { return }
            let entry = StoredEntry(packet: packet, hash64: hash64)
            if let existing = packets[idHex] {
                payloadBytes += packet.payload.count - existing.packet.payload.count
                packets[idHex] = entry
            } else {
                packets[idHex] = entry
                order.append(idHex)
                payloadBytes += packet.payload.count
            }
            while order.count > capacity || payloadBytes > byteBudget {
                let victim = order.removeFirst()
                if let evicted = packets.removeValue(forKey: victim) {
                    payloadBytes -= evicted.packet.payload.count
                }
            }
        }

        func allEntries(isFresh: (BitchatPacket) -> Bool) -> [StoredEntry] {
            var result: [StoredEntry] = []
            result.reserveCapacity(order.count)
            for key in order {
                guard let entry = packets[key], isFresh(entry.packet) else { continue }
                result.append(entry)
            }
            return result
        }

        func allPackets(isFresh: (BitchatPacket) -> Bool) -> [BitchatPacket] {
            allEntries(isFresh: isFresh).map(\.packet)
        }

        mutating func remove(where shouldRemove: (BitchatPacket) -> Bool) {
            var nextOrder: [String] = []
            nextOrder.reserveCapacity(order.count)
            for key in order {
                guard let entry = packets[key] else { continue }
                if shouldRemove(entry.packet) {
                    packets.removeValue(forKey: key)
                    payloadBytes -= entry.packet.payload.count
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
        // Payload byte budgets on top of the count caps. Each sits well above
        // what the count cap holds in ordinary traffic (1000 chat messages,
        // 600 fragments of ~500 B), so it only binds when packets are
        // oversized — e.g. 200 file transfers at the 1.1 MB frame cap.
        var messageByteBudget: Int = 8 * 1024 * 1024
        var fragmentByteBudget: Int = 1024 * 1024
        var fileTransferByteBudget: Int = 32 * 1024 * 1024
        var groupMessageByteBudget: Int = 4 * 1024 * 1024
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
        // Future bound for every store: matches the ingress skew so nothing
        // the radio accepts is refused here.
        var maxFutureSkewMs: UInt64 = TransportConfig.bleMaxTimestampSkewMs
    }

    private let mySenderIDData: Data
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
    private var latestAnnouncementByPeer: [PeerID: StoredEntry] = [:]
    // Latest verified prekey bundle per owner. Unlike announces, bundles are
    // NOT dropped on leave/stale peer: their whole purpose is reaching a
    // sender while the owner is away.
    private var latestPrekeyBundleByPeer: [PeerID: StoredEntry] = [:]
    private var archiveDirty = false

    // Timer
    private var periodicTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mesh.sync", qos: .utility)
    private var lastStalePeerCleanup: Date = .distantPast
    private var syncSchedules: [SyncSchedule] = []
    private var responseRateLimiter: SyncResponseRateLimiter

    init(myPeerID: PeerID, config: Config = Config(), requestSyncManager: RequestSyncManager, archive: GossipMessageArchive? = nil) {
        self.mySenderIDData = Data(hexString: myPeerID.id) ?? Data()
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
        // Generous leeway on long maintenance cadences lets the OS coalesce CPU wakeups.
        let leeway: DispatchTimeInterval = interval >= 10.0 ? .seconds(5) : .seconds(1)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
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
            let payload = self.buildGcsPayload(for: types)
            self.sendRequestSync(to: peerID, payload: payload)
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
    private func isPacketFresh(_ packet: BitchatPacket, nowMs: UInt64) -> Bool {
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
        // Age windows only bound the past. A future-dated packet would never
        // expire, sort ahead of everything in each GCS filter, and push the
        // requester's since-cursor past all real history, so anything dated
        // beyond the ingress skew is never stored, served or restored.
        if packet.timestamp > nowMs, packet.timestamp - nowMs > config.maxFutureSkewMs {
            return false
        }
        let ageThresholdMs = UInt64(maxAgeSeconds * 1000)

        // If current time is less than threshold, accept all (handle clock issues gracefully)
        guard nowMs >= ageThresholdMs else { return true }

        let cutoffMs = nowMs - ageThresholdMs
        return packet.timestamp >= cutoffMs
    }

    private func isAnnouncementFresh(_ packet: BitchatPacket, nowMs: UInt64) -> Bool {
        guard config.stalePeerTimeoutSeconds > 0 else { return true }
        let timeoutMs = UInt64(config.stalePeerTimeoutSeconds * 1000)
        guard nowMs >= timeoutMs else { return true }
        let cutoffMs = nowMs - timeoutMs
        return packet.timestamp >= cutoffMs
    }

    private static func makeEntry(_ packet: BitchatPacket) -> (idHex: String, entry: StoredEntry) {
        let idBytes = PacketIdUtil.computeId(packet)
        let hash64 = GCSFilter.hash64(idBytes)
        return (idBytes.hexEncodedString(), StoredEntry(packet: packet, hash64: hash64))
    }

    private func _onPublicPacketSeen(_ packet: BitchatPacket) {
        guard let messageType = MessageType(rawValue: packet.type) else { return }
        let isBroadcastRecipient: Bool = {
            guard let r = packet.recipientID else { return true }
            return r.count == 8 && r.allSatisfy { $0 == 0xFF }
        }()
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        switch messageType {
        case .announce:
            guard isPacketFresh(packet, nowMs: nowMs) else { return }
            guard isAnnouncementFresh(packet, nowMs: nowMs) else {
                let sender = PeerID(hexData: packet.senderID)
                removeState(for: sender)
                return
            }
            let sender = PeerID(hexData: packet.senderID)
            let idBytes = PacketIdUtil.computeId(packet)
            latestAnnouncementByPeer[sender] = StoredEntry(packet: packet, hash64: GCSFilter.hash64(idBytes))
        case .message:
            guard isBroadcastRecipient else { return }
            guard isPacketFresh(packet, nowMs: nowMs) else { return }
            let (idHex, entry) = Self.makeEntry(packet)
            messages.insert(idHex: idHex, hash64: entry.hash64, packet: packet, capacity: max(1, config.seenCapacity), byteBudget: config.messageByteBudget)
            archiveDirty = true
        case .fragment:
            guard isBroadcastRecipient else { return }
            guard isPacketFresh(packet, nowMs: nowMs) else { return }
            let (idHex, entry) = Self.makeEntry(packet)
            fragments.insert(idHex: idHex, hash64: entry.hash64, packet: packet, capacity: max(1, config.fragmentCapacity), byteBudget: config.fragmentByteBudget)
        case .fileTransfer:
            guard isBroadcastRecipient else { return }
            guard isPacketFresh(packet, nowMs: nowMs) else { return }
            let (idHex, entry) = Self.makeEntry(packet)
            fileTransfers.insert(idHex: idHex, hash64: entry.hash64, packet: packet, capacity: max(1, config.fileTransferCapacity), byteBudget: config.fileTransferByteBudget)
        case .groupMessage:
            // Opaque ciphertext to non-members; carried and served like any
            // other broadcast so members get backfill from any relay.
            guard isBroadcastRecipient else { return }
            guard isPacketFresh(packet, nowMs: nowMs) else { return }
            let (idHex, entry) = Self.makeEntry(packet)
            groupMessages.insert(idHex: idHex, hash64: entry.hash64, packet: packet, capacity: max(1, config.groupMessageCapacity), byteBudget: config.groupMessageByteBudget)
        case .prekeyBundle:
            // Callers only feed verified bundles here (own bundles at send
            // time, peers' after signature verification), so gossip never
            // spreads a bundle this node couldn't attribute.
            guard isBroadcastRecipient else { return }
            guard isPacketFresh(packet, nowMs: nowMs) else { return }
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
            let idBytes = PacketIdUtil.computeId(packet)
            latestPrekeyBundleByPeer[owner] = StoredEntry(packet: packet, hash64: GCSFilter.hash64(idBytes))
        default:
            break
        }
    }

    private func sendPeriodicSync(for types: SyncTypeFlags) {
        guard let delegate, delegate.hasSyncTargets() else { return }
        // Build the GCS filter ONCE per periodic round and reuse it across all peers.
        let payload = buildGcsPayload(for: types)
        let connectedPeers = delegate.getConnectedPeers()
        if !connectedPeers.isEmpty {
            SecureLogger.debug("Sending periodic sync (\(types.logDescription)) to \(connectedPeers.count) connected peers", category: .sync)
            for peerID in connectedPeers {
                sendRequestSync(to: peerID, payload: payload)
            }
        } else {
            // Fallback to broadcast (discovery phase)
            sendRequestSync(payload: payload)
        }
    }

    private func sendRequestSync(payload: Data) {
        let pkt = BitchatPacket(
            type: MessageType.requestSync.rawValue,
            senderID: mySenderIDData,
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
        let payload = buildGcsPayload(for: .fragment, fragmentIdFilter: filter)
        for peerID in connectedPeers {
            sendRequestSync(to: peerID, payload: payload)
        }
    }

    private func sendRequestSync(to peerID: PeerID, payload: Data) {
        // Register the request for RSR validation
        requestSyncManager.registerRequest(to: peerID)

        let recipient: Data
        if let decoded = Data(hexString: peerID.id) {
            recipient = decoded.count > 8 ? Data(decoded.prefix(8)) : decoded
        } else {
            recipient = Data()
        }
        let pkt = BitchatPacket(
            type: MessageType.requestSync.rawValue,
            senderID: mySenderIDData,
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
        let now = Date()
        // A response can replay the whole store, so bound how often one peer
        // can trigger a diff pass regardless of how fast it asks.
        guard responseRateLimiter.shouldRespond(to: peerID, now: now) else {
            SecureLogger.warning("Rate-limited REQUEST_SYNC from \(peerID.id.prefix(8))…", category: .sync)
            return
        }
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000)
        let requestedTypes = (request.types ?? .publicMessages)
        // The requester's filter only covers packets at or after this cursor;
        // older packets are outside the filter but not missing, and without
        // the cursor they would be re-sent every round.
        let since = request.sinceTimestamp
        // Decode GCS into sorted set and prepare membership checker
        let sorted = GCSFilter.decodeToSortedSet(p: request.p, m: request.m, data: request.data)
        func mightContain(hash64: UInt64) -> Bool {
            let bucket = GCSFilter.bucket(forHash64: hash64, modulus: request.m)
            return GCSFilter.contains(sortedValues: sorted, candidate: bucket)
        }
        func isFresh(_ pkt: BitchatPacket) -> Bool {
            isPacketFresh(pkt, nowMs: nowMs)
        }

        func sendIfMissing(_ packet: BitchatPacket, hash64: UInt64) {
            guard !mightContain(hash64: hash64) else { return }
            var toSend = packet
            toSend.ttl = 0
            toSend.isRSR = true // Mark as solicited response
            delegate?.sendPacket(to: peerID, packet: toSend)
        }

        // Announces are exempt from the since-cursor: they carry the signing
        // keys needed to verify everything else, and there is at most one per
        // peer, so the resend cost is negligible.
        if requestedTypes.contains(.announce) {
            for (_, entry) in latestAnnouncementByPeer {
                guard isFresh(entry.packet) else { continue }
                sendIfMissing(entry.packet, hash64: entry.hash64)
            }
        }

        if requestedTypes.contains(.message) {
            let toSendMsgs = messages.allEntries(isFresh: isFresh)
            for entry in toSendMsgs {
                if let since, entry.packet.timestamp < since { continue }
                sendIfMissing(entry.packet, hash64: entry.hash64)
            }
        }

        if requestedTypes.contains(.fragment) {
            // A fragment-ID filter narrows the diff to exactly the named
            // fragment streams (targeted resync for stalled reassemblies)
            // and bypasses the since-cursor for them; the GCS filter still
            // excludes the pieces the requester already holds. Fragment
            // payloads start with the 8-byte stream ID.
            let fragmentIdFilter = RequestSyncPacket.decodeFragmentIdFilter(request.fragmentIdFilter)
            let frags = fragments.allEntries(isFresh: isFresh)
            for entry in frags {
                if let fragmentIdFilter {
                    guard fragmentIdFilter.contains(Data(entry.packet.payload.prefix(8))) else { continue }
                } else if let since, entry.packet.timestamp < since {
                    continue
                }
                sendIfMissing(entry.packet, hash64: entry.hash64)
            }
        }

        if requestedTypes.contains(.fileTransfer) {
            let files = fileTransfers.allEntries(isFresh: isFresh)
            for entry in files {
                if let since, entry.packet.timestamp < since { continue }
                sendIfMissing(entry.packet, hash64: entry.hash64)
            }
        }

        if requestedTypes.contains(.groupMessage) {
            let groupPkts = groupMessages.allEntries(isFresh: isFresh)
            for entry in groupPkts {
                if let since, entry.packet.timestamp < since { continue }
                sendIfMissing(entry.packet, hash64: entry.hash64)
            }
        }
        // Like announces, prekey bundles are exempt from the since-cursor:
        // there is at most one per owner (newer replaces older), so the
        // resend cost is bounded and a joining peer must be able to learn
        // bundles generated long before it arrived.
        if requestedTypes.contains(.prekeyBundle) {
            for (_, entry) in latestPrekeyBundleByPeer {
                guard isFresh(entry.packet) else { continue }
                sendIfMissing(entry.packet, hash64: entry.hash64)
            }
        }
        if requestedTypes.contains(.boardPost) {
            // The board store already filters to live posts and tombstones;
            // no freshness window applies (posts sync until their own expiry).
            let boardPackets = boardPacketsProvider?() ?? []
            for pkt in boardPackets {
                if let since, pkt.timestamp < since { continue }
                sendIfMissing(pkt, hash64: GCSFilter.hash64(PacketIdUtil.computeId(pkt)))
            }
        }
    }

    // Build REQUEST_SYNC payload using current candidates and GCS params
    private func buildGcsPayload(for types: SyncTypeFlags, fragmentIdFilter: String? = nil) -> Data {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        func isFresh(_ pkt: BitchatPacket) -> Bool {
            isPacketFresh(pkt, nowMs: nowMs)
        }
        var candidates: [(timestamp: UInt64, hash64: UInt64)] = []
        if types.contains(.announce) {
            for (_, entry) in latestAnnouncementByPeer where isFresh(entry.packet) {
                candidates.append((entry.packet.timestamp, entry.hash64))
            }
        }
        if types.contains(.message) {
            for entry in messages.allEntries(isFresh: isFresh) {
                candidates.append((entry.packet.timestamp, entry.hash64))
            }
        }
        if types.contains(.fragment) {
            for entry in fragments.allEntries(isFresh: isFresh) {
                candidates.append((entry.packet.timestamp, entry.hash64))
            }
        }
        if types.contains(.fileTransfer) {
            for entry in fileTransfers.allEntries(isFresh: isFresh) {
                candidates.append((entry.packet.timestamp, entry.hash64))
            }
        }
        if types.contains(.groupMessage) {
            for entry in groupMessages.allEntries(isFresh: isFresh) {
                candidates.append((entry.packet.timestamp, entry.hash64))
            }
        }
        if types.contains(.prekeyBundle) {
            for (_, entry) in latestPrekeyBundleByPeer where isFresh(entry.packet) {
                candidates.append((entry.packet.timestamp, entry.hash64))
            }
        }
        if types.contains(.boardPost) {
            for pkt in boardPacketsProvider?() ?? [] {
                candidates.append((pkt.timestamp, GCSFilter.hash64(PacketIdUtil.computeId(pkt))))
            }
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
        var hashes: [UInt64] = []
        hashes.reserveCapacity(takeN)
        for i in 0..<takeN {
            hashes.append(candidates[i].hash64)
        }
        let params = GCSFilter.buildFilter(precomputedHashes: hashes, maxBytes: config.gcsMaxBytes, targetFpr: config.gcsTargetFpr)
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
            ? candidates[covered - 1].timestamp
            : nil
        let req = RequestSyncPacket(p: params.p, m: params.m, data: params.data, types: types, sinceTimestamp: sinceTimestamp, fragmentIdFilter: fragmentIdFilter)
        return req.encode()
    }

    // Periodic cleanup of expired messages and announcements
    private func cleanupExpiredMessages(nowMs: UInt64) {
        func isFresh(_ pkt: BitchatPacket) -> Bool {
            isPacketFresh(pkt, nowMs: nowMs)
        }
        // Remove expired announcements
        if !latestAnnouncementByPeer.isEmpty {
            latestAnnouncementByPeer = latestAnnouncementByPeer.filter { _, entry in
                isFresh(entry.packet)
            }
        }

        if !messages.packets.isEmpty {
            let messageCountBefore = messages.packets.count
            messages.removeExpired(isFresh: isFresh)
            if messages.packets.count != messageCountBefore {
                archiveDirty = true
            }
        }
        if !fragments.packets.isEmpty {
            fragments.removeExpired(isFresh: isFresh)
        }
        if !fileTransfers.packets.isEmpty {
            fileTransfers.removeExpired(isFresh: isFresh)
        }
        if !groupMessages.packets.isEmpty {
            groupMessages.removeExpired(isFresh: isFresh)
        }
        if !latestPrekeyBundleByPeer.isEmpty {
            latestPrekeyBundleByPeer = latestPrekeyBundleByPeer.filter { _, entry in
                isFresh(entry.packet)
            }
        }
    }

    // MARK: - Archive (public message persistence)

    /// Rebuild the public message store from disk on launch, dropping
    /// anything that aged out while the app was dead — or that is dated in
    /// the future, which an older build could have archived from a sync
    /// reply. Any drop rewrites the file so it is purged from disk too.
    ///
    /// Bounded like live intake: entries are stored oldest-first, so walk
    /// them newest-first and stop once the count or byte budget is spent. An
    /// oversized archive then costs at most one budget of decode work at
    /// launch instead of re-inflating everything it holds.
    private func restoreArchivedMessages() {
        guard let archive else { return }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let capacity = max(1, config.seenCapacity)
        var kept: [(idHex: String, hash64: UInt64, packet: BitchatPacket)] = []
        var keptBytes = 0
        var droppedAny = false
        for data in archive.load().reversed() {
            guard kept.count < capacity else { break }
            guard let packet = BitchatPacket.from(data),
                  packet.type == MessageType.message.rawValue,
                  isPacketFresh(packet, nowMs: nowMs) else {
                droppedAny = true
                continue
            }
            guard keptBytes + packet.payload.count <= config.messageByteBudget else { break }
            keptBytes += packet.payload.count
            let (idHex, entry) = Self.makeEntry(packet)
            kept.append((idHex, entry.hash64, packet))
        }
        for entry in kept.reversed() {
            messages.insert(idHex: entry.idHex, hash64: entry.hash64, packet: entry.packet, capacity: capacity, byteBudget: config.messageByteBudget)
        }
        if !kept.isEmpty {
            SecureLogger.debug("Restored \(kept.count) archived public message(s) for gossip sync", category: .sync)
        }
        if !kept.isEmpty || droppedAny {
            archiveDirty = true
        }
    }

    private func persistArchiveIfDirty() {
        guard archiveDirty, let archive else { return }
        archiveDirty = false
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let packets = messages.allPackets { isPacketFresh($0, nowMs: nowMs) }
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
            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            completion(self.messages.allPackets { self.isPacketFresh($0, nowMs: nowMs) })
        }
    }

    private func performPeriodicMaintenance(now: Date = Date()) {
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000)
        cleanupExpiredMessages(nowMs: nowMs)
        cleanupStaleAnnouncementsIfNeeded(now: now)
        persistArchiveIfDirty()
        requestSyncManager.cleanup() // Cleanup expired sync requests
        responseRateLimiter.prune(now: now)

        // Skip sync filter construction and signing when no peer links exist.
        guard delegate?.hasSyncTargets() == true else { return }
        
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
        guard !latestAnnouncementByPeer.isEmpty else { return }
        let timeoutMs = UInt64(config.stalePeerTimeoutSeconds * 1000)
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000)
        guard nowMs >= timeoutMs else { return }
        let cutoff = nowMs - timeoutMs
        let stalePeerIDs = latestAnnouncementByPeer.compactMap { peerID, entry in
            entry.packet.timestamp < cutoff ? peerID : nil
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

    /// Drop every carried public message and clear the archive on disk.
    ///
    /// Used when someone clears the mesh timeline: the watermark already stops
    /// cleared messages from being shown again, so anything left in the
    /// archive is retained purely to serve other peers — and a person who
    /// clears a timeline reasonably reads that as "this is gone from my
    /// phone". The cost is that this device stops offering the recent public
    /// backlog to peers until it hears fresh traffic.
    func removeAllPublicMessages() {
        queue.async { [weak self] in
            guard let self else { return }
            self.messages.remove { _ in true }
            self.archiveDirty = true
            // Persist now rather than waiting for maintenance: a relaunch in
            // the gap would restore the purged messages from disk.
            self.persistArchiveIfDirty()
            self.archive?.wipe()
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

extension GossipSyncManager.Delegate {
    func hasSyncTargets() -> Bool { true }
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
