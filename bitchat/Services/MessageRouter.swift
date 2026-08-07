import BitLogger
import BitFoundation
import Foundation

/// Trust and identity lookups the router needs to pick couriers. Backed by
/// the favorites store in production; injectable for tests.
struct CourierDirectory {
    /// Noise static key for a peer we can address while they're offline.
    var noiseKey: (PeerID) -> Data?
    /// Whether a peer (by Noise static key) is a mutual favorite — the
    /// preferred courier tier. Verified non-favorites are the fallback tier,
    /// read off the transport snapshot.
    var isTrustedCourier: (Data) -> Bool

    @MainActor
    static func favoritesBacked() -> CourierDirectory {
        CourierDirectory(
            noiseKey: { peerID in
                // Offline favorites are addressed by the full 64-hex
                // noise-key ID, which carries the key itself; the favorites
                // lookup only resolves short 16-hex IDs.
                peerID.noiseKey
                    ?? FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID)?.peerNoisePublicKey
            },
            isTrustedCourier: { noiseKey in
                FavoritesPersistenceService.shared.isMutualFavorite(noiseKey)
            }
        )
    }
}

/// Routes messages using available transports (Mesh, Nostr, etc.)
@MainActor
final class MessageRouter {
    typealias QueuedMessage = MessageOutboxStore.QueuedMessage

    private struct PeerMessageKey: Hashable {
        // periphery:ignore - read only via the synthesized Hashable
        // conformance (dictionary-key identity), which the indexer
        // cannot attribute; see retain_codable_properties in .periphery.yml
        // for the same class of false positive.
        let peerID: PeerID
        let messageID: String
    }

    private let transports: [Transport]
    private let now: () -> Date
    private let courierDirectory: CourierDirectory
    private let outboxStore: MessageOutboxStore?
    private let metrics: StoreAndForwardMetrics?

    /// Invoked whenever a retained private message is dropped without a
    /// delivery ack (attempt cap, TTL expiry, or per-peer overflow eviction)
    /// so the UI can surface the failure instead of leaving the message in a
    /// stale "sending/sent" state forever.
    var onMessageDropped: ((_ messageID: String, _ peerID: PeerID) -> Void)?

    /// Invoked when a message with no reachable transport was handed to at
    /// least one courier (a connected peer who will physically carry the
    /// sealed envelope). Delivery stays best-effort: the outbox retains the
    /// message until an ack arrives.
    var onMessageCarried: ((_ messageID: String, _ peerID: PeerID) -> Void)?

    /// Parallel deposit into the internet bridge: park a sealed copy on
    /// relays as a courier drop, so delivery stops requiring a physical
    /// courier encounter. No-op unless the bridge is enabled. Runs alongside
    /// (not instead of) mesh couriers; receivers dedup by message ID.
    /// Completion is true only after at least one default relay explicitly
    /// accepts the event, so a socket write followed by rejection cannot
    /// falsely show the sender's message as "carried".
    var bridgeCourierDeposit: ((
        _ content: String,
        _ messageID: String,
        _ recipientNoiseKey: Data,
        _ completion: @escaping @MainActor (Bool) -> Void
    ) -> Void)?

    /// Re-attempts bridge drops for retained messages whose recipient no
    /// transport can promptly reach anymore. Covers sends that raced the BLE
    /// reachability retention window: a peer stays "reachable" for a minute
    /// after its radio disappears, so the original send trusted the mesh and
    /// skipped the deposit — and nothing else ever retried (field-found).
    /// Safe to call often: the drop layer dedups by message ID.
    func retryBridgeCourierDeposits() {
        guard bridgeCourierDeposit != nil else { return }
        for (peerID, queue) in outbox {
            guard let recipientKey = courierDirectory.noiseKey(peerID) else { continue }
            let promptlyDeliverable = transports.contains {
                $0.isPeerReachable(peerID) && $0.canDeliverPromptly(to: peerID)
            }
            guard !promptlyDeliverable else { continue }
            for message in queue where now().timeIntervalSince(message.timestamp) <= Self.messageTTLSeconds {
                requestBridgeCourierDeposit(message, for: peerID, recipientKey: recipientKey)
            }
        }
    }

    /// Arms the periodic sweep behind `retryBridgeCourierDeposits`. Called
    /// once by the bootstrapper after the deposit closure is wired; separate
    /// from init so tests drive the retry directly.
    func startBridgeDepositSweep(interval: TimeInterval = 120) {
        bridgeSweepTask?.cancel()
        bridgeSweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                // Expire stale outbox entries in-session too — otherwise a DM
                // to a peer that never reconnects sits on "sending" until the
                // next relaunch instead of surfacing as failed.
                self?.cleanupExpiredMessages()
                self?.retryBridgeCourierDeposits()
            }
        }
    }

    private var bridgeSweepTask: Task<Void, Never>?
    private var bridgeDepositsInFlight = Set<PeerMessageKey>()

    private var outbox: [PeerID: [QueuedMessage]] = [:]
    /// Peer/message pairs whose latest router-owned transmission used an
    /// already-established secure session and still await an ack. Peer scope
    /// is required because message IDs are not globally unique across direct
    /// conversations. This deliberately excludes messages handed to BLE while
    /// a handshake is pending: BLE owns those sends and drains its queue after
    /// authentication, so retrying them here would duplicate every normal
    /// first-handshake DM.
    private var secureTransmissions = Set<PeerMessageKey>()

    // Outbox limits to prevent unbounded memory growth
    private static let maxMessagesPerPeer = 100
    private static let messageTTLSeconds: TimeInterval = 24 * 60 * 60 // 24 hours
    // Bound actual sends that never receive an ack, whether they used weak
    // reachability or an apparently secure session that keeps being replaced.
    // Connected pre-handshake sends are transport-owned and do not burn this
    // cap because BLE queues/drains them itself.
    private static let maxSendAttempts = 8
    // Redundant couriers improve delivery odds; receivers dedup by message ID.
    private static let maxCouriersPerMessage = 3

    init(
        transports: [Transport],
        now: @escaping () -> Date = Date.init,
        courierDirectory: CourierDirectory? = nil,
        outboxStore: MessageOutboxStore? = nil,
        metrics: StoreAndForwardMetrics? = nil
    ) {
        self.transports = transports
        self.now = now
        self.courierDirectory = courierDirectory ?? .favoritesBacked()
        self.outboxStore = outboxStore
        self.metrics = metrics
        self.outbox = outboxStore?.load() ?? [:]
        outboxStore?.setRecoveryHandler { [weak self] recovered in
            self?.mergeRecoveredOutbox(recovered)
        }

        // Observe favorites changes to learn Nostr mapping and flush queued messages
        NotificationCenter.default.addObserver(
            forName: .favoriteStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let data = note.userInfo?["peerPublicKey"] as? Data {
                let peerID = PeerID(publicKey: data)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
            // Handle key updates
            if let newKey = note.userInfo?["peerPublicKey"] as? Data,
               note.userInfo?["isKeyUpdate"] is Bool {
                let peerID = PeerID(publicKey: newKey)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
        }
    }

    // MARK: - Transport Selection

    private func reachableTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerReachable(peerID) }
    }

    private func connectedTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerConnected(peerID) }
    }

    // MARK: - Message Sending

    func sendPrivate(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        let message = QueuedMessage(
            content: content,
            nickname: recipientNickname,
            messageID: messageID,
            timestamp: now(),
            sendAttempts: 1
        )

        if let transport = connectedTransport(for: peerID), transport.canDeliverSecurely(to: peerID) {
            // Even an established Noise session can be stale after the peer
            // restarts or replaces its app. Persist before handing the packet
            // to the transport so a fast ack cannot race ahead of retention,
            // then keep the copy until a delivery/read ack clears it. A
            // replacement handshake will retry this same message ID, which
            // receivers deduplicate.
            enqueue(message, for: peerID)
            secureTransmissions.insert(PeerMessageKey(peerID: peerID, messageID: messageID))
            SecureLogger.debug("Routing PM via \(type(of: transport)) (connected) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
            return
        }

        if let transport = connectedTransport(for: peerID) {
            // "Connected" without an established secure session is forgeable:
            // link bindings heal on signature-verified "direct" announces, but
            // directness rides on the unsigned TTL, so a replayed announce can
            // bind an absent peer's ID to the replayer's link — where the send
            // stalls on a handshake the replayer can never complete. Send now
            // (a genuine link finishes the handshake and delivers), but retain
            // a copy and hand a sealed copy to couriers so nothing is silently
            // lost; receivers dedup resends by message ID.
            //
            // Deliberate metadata tradeoff: every pre-handshake first DM to a
            // connected peer hands nearby verified peers a sealed copy, so
            // they learn a DM to this recipient exists (never its content —
            // the envelope is opaque). Accepted for delivery robustness; the
            // deposit is cleared on ack. Don't "optimize" the courier call
            // away.
            SecureLogger.debug("Routing PM via \(type(of: transport)) (connected, no secure session) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            enqueue(message, for: peerID)
            secureTransmissions.remove(PeerMessageKey(peerID: peerID, messageID: messageID))
            transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
            attemptCourierDeposit(messageID: messageID, for: peerID)
            return
        }

        if let transport = reachableTransport(for: peerID) {
            // Reachability without a connection is a freshness heuristic (e.g.
            // the mesh retention window), so the send can silently go nowhere.
            // Send now, but retain a copy until a delivery/read ack clears it;
            // receivers dedup resends by message ID.
            SecureLogger.debug("Routing PM via \(type(of: transport)) (reachable) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            enqueue(message, for: peerID)
            transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
            // "Reachable" without prompt delivery means the send only joined
            // a queue (Nostr with relays down): also hand a sealed copy to
            // any connected couriers rather than waiting for internet that
            // may never come. Double delivery is harmless — receivers dedup
            // by message ID, and delivered/read acks never downgrade.
            if !transport.canDeliverPromptly(to: peerID) {
                attemptCourierDeposit(messageID: messageID, for: peerID)
            }
        } else {
            var unsent = message
            unsent.sendAttempts = 0
            enqueue(unsent, for: peerID)
            SecureLogger.debug("Queued PM for \(peerID.id.prefix(8))… (no reachable transport) id=\(messageID.prefix(8))… queue=\(outbox[peerID]?.count ?? 0)", category: .session)
            attemptCourierDeposit(messageID: messageID, for: peerID)
        }
    }

    // MARK: - Couriers

    /// Last resort when no transport can deliver promptly — the peer is
    /// unreachable, or only reachable through a send queue waiting on
    /// internet: seal the message to their known static key and hand it to
    /// connected couriers who may physically encounter them. Mutual favorites
    /// are preferred; signature-verified strangers fill remaining slots so a
    /// crowd without favorites can still carry mail (envelopes are opaque
    /// either way). The queued copy stays retained, so direct delivery still
    /// wins if the peer reappears first (receivers dedup by message ID).
    private func attemptCourierDeposit(messageID: String, for peerID: PeerID) {
        guard let recipientKey = courierDirectory.noiseKey(peerID),
              let entry = queuedMessage(messageID, for: peerID) else { return }
        // The bridge drop needs no connected courier — only the recipient
        // key — so it runs before the courier-slot bookkeeping.
        requestBridgeCourierDeposit(entry, for: peerID, recipientKey: recipientKey)
        let remainingSlots = Self.maxCouriersPerMessage - entry.depositedCourierKeys.count
        guard remainingSlots > 0 else { return }

        for transport in transports {
            guard let courierTransport = transport as? MeshCourierTransporting else { continue }
            let couriers = eligibleCouriers(
                on: transport,
                recipientKey: recipientKey,
                excluding: entry.depositedCourierKeys,
                limit: remainingSlots
            )
            guard !couriers.isEmpty else { continue }
            if courierTransport.sendCourierMessage(entry.content, messageID: messageID, recipientNoiseKey: recipientKey, via: couriers.map(\.peerID)) {
                SecureLogger.debug("📦 PM \(messageID.prefix(8))… handed to \(couriers.count) courier(s) for \(peerID.id.prefix(8))…", category: .session)
                recordCourierDeposit(messageID: messageID, for: peerID, courierKeys: couriers.map(\.noiseKey))
                onMessageCarried?(messageID, peerID)
                return
            }
        }
    }

    /// A courier candidate just connected: hand them any queued mail they are
    /// not already carrying. This is what turns couriering from "a favorite
    /// happened to be around at send time" into eventual spread — deposits
    /// retry as eligible peers appear, until each message rides with
    /// `maxCouriersPerMessage` distinct couriers or expires.
    func courierBecameAvailable(_ peerID: PeerID) {
        for transport in transports {
            guard let courierTransport = transport as? MeshCourierTransporting else { continue }
            guard transport.isPeerConnected(peerID),
                  let snapshot = transport.currentPeerSnapshots().first(where: { $0.peerID == peerID && $0.isConnected }),
                  let courierKey = snapshot.noisePublicKey,
                  courierDirectory.isTrustedCourier(courierKey) || snapshot.isVerified else { continue }

            let currentDate = now()
            for (recipient, queue) in outbox {
                // Mail *to* this peer flushes directly on connect.
                guard recipient != peerID,
                      let recipientKey = courierDirectory.noiseKey(recipient),
                      recipientKey != courierKey else { continue }
                for message in queue {
                    guard message.depositedCourierKeys.count < Self.maxCouriersPerMessage,
                          !message.depositedCourierKeys.contains(courierKey),
                          currentDate.timeIntervalSince(message.timestamp) <= Self.messageTTLSeconds else { continue }
                    if courierTransport.sendCourierMessage(message.content, messageID: message.messageID, recipientNoiseKey: recipientKey, via: [peerID]) {
                        SecureLogger.debug("📦 Deposit retry: PM \(message.messageID.prefix(8))… handed to \(peerID.id.prefix(8))… for \(recipient.id.prefix(8))…", category: .session)
                        recordCourierDeposit(messageID: message.messageID, for: recipient, courierKeys: [courierKey])
                        onMessageCarried?(message.messageID, recipient)
                    }
                }
            }
            return
        }
    }

    private struct CourierCandidate {
        let peerID: PeerID
        let noiseKey: Data
    }

    private func eligibleCouriers(
        on transport: Transport,
        recipientKey: Data,
        excluding excludedKeys: Set<Data>,
        limit: Int
    ) -> [CourierCandidate] {
        guard limit > 0 else { return [] }
        let candidates = transport.currentPeerSnapshots().compactMap { snapshot -> (CourierCandidate, isFavorite: Bool)? in
            guard snapshot.isConnected,
                  let key = snapshot.noisePublicKey,
                  key != recipientKey,
                  !excludedKeys.contains(key) else { return nil }
            let isFavorite = courierDirectory.isTrustedCourier(key)
            guard isFavorite || snapshot.isVerified else { return nil }
            return (CourierCandidate(peerID: snapshot.peerID, noiseKey: key), isFavorite)
        }
        return candidates
            .sorted { $0.isFavorite && !$1.isFavorite }
            .prefix(limit)
            .map(\.0)
    }

    private func queuedMessage(_ messageID: String, for peerID: PeerID) -> QueuedMessage? {
        outbox[peerID]?.first { $0.messageID == messageID }
    }

    private func requestBridgeCourierDeposit(
        _ message: QueuedMessage,
        for peerID: PeerID,
        recipientKey: Data
    ) {
        let inFlightKey = PeerMessageKey(peerID: peerID, messageID: message.messageID)
        guard let bridgeCourierDeposit,
              bridgeDepositsInFlight.insert(inFlightKey).inserted else { return }
        bridgeCourierDeposit(message.content, message.messageID, recipientKey) { [weak self] succeeded in
            guard let self else { return }
            self.bridgeDepositsInFlight.remove(inFlightKey)
            // A direct delivery may have cleared the outbox while the relay
            // relay confirmation was in flight; do not regress its UI state.
            guard succeeded, self.queuedMessage(message.messageID, for: peerID) != nil else { return }
            self.onMessageCarried?(message.messageID, peerID)
        }
    }

    private func recordCourierDeposit(messageID: String, for peerID: PeerID, courierKeys: [Data]) {
        metrics?.record(.courierDeposited)
        guard var queue = outbox[peerID],
              let index = queue.firstIndex(where: { $0.messageID == messageID }) else { return }
        queue[index].depositedCourierKeys.formUnion(courierKeys)
        outbox[peerID] = queue
        persistOutbox()
    }

    // MARK: - Outbox Management

    /// A locally trusted delivery transition confirms receipt; stop retaining
    /// every copy of the message. Authenticated remote receipts must use the
    /// peer-bound overload below instead.
    func markDelivered(_ messageID: String) {
        clearRetainedMessage(messageID)
    }

    /// Stops retaining a message only for the authenticated conversation
    /// aliases that produced the accepted receipt. A peer that learns another
    /// conversation's message ID cannot use it to clear that conversation's
    /// retry state.
    func markDelivered(_ messageID: String, from peerIDs: Set<PeerID>) {
        guard !peerIDs.isEmpty else { return }
        _ = markDelivered(messageID, for: Array(peerIDs))
    }

    private func clearRetainedMessage(_ messageID: String) {
        var cleared = false
        for (peerID, queue) in outbox {
            let filtered = queue.filter { $0.messageID != messageID }
            guard filtered.count != queue.count else { continue }
            outbox[peerID] = filtered.isEmpty ? nil : filtered
            cleared = true
        }
        let matchingSecureTransmissions = secureTransmissions.filter {
            $0.messageID == messageID
        }
        secureTransmissions.subtract(matchingSecureTransmissions)
        // The durable snapshot may still be hidden by protected data. Record
        // the ack even when this cold-load view cannot find the message, then
        // persist the current view so the store retains a removal tombstone.
        outboxStore?.recordRemoval(messageID: messageID)
        if cleared {
            metrics?.record(.outboxDelivered)
        }
        persistOutbox()
    }

    /// A delivery or read ack authenticated to one account confirms receipt
    /// only for that account's transport aliases. A colliding message ID
    /// queued for another peer must remain retained.
    @discardableResult
    func markDelivered(_ messageID: String, for peerAliases: [PeerID]) -> Bool {
        let peerIDs = Set(peerAliases)
        guard !peerIDs.isEmpty else { return false }

        var cleared = false
        for peerID in peerIDs {
            guard let queue = outbox[peerID] else { continue }
            let filtered = queue.filter { $0.messageID != messageID }
            guard filtered.count != queue.count else { continue }
            outbox[peerID] = filtered.isEmpty ? nil : filtered
            cleared = true
        }
        for peerID in peerIDs {
            secureTransmissions.remove(PeerMessageKey(peerID: peerID, messageID: messageID))
        }
        // Preserve the scoped ack even when protected data hides the durable
        // queue during a cold launch.
        outboxStore?.recordRemoval(messageID: messageID, for: peerIDs)
        if cleared {
            metrics?.record(.outboxDelivered)
        }
        persistOutbox()
        return cleared
    }

    private func enqueue(_ message: QueuedMessage, for peerID: PeerID) {
        var message = message
        var queue = outbox[peerID] ?? []
        // Re-sending an already-queued ID replaces the entry (keeps attempt
        // count fresh) but must not forget which couriers already carry it,
        // or the replacement re-burns the same courier slots.
        if let existing = queue.firstIndex(where: { $0.messageID == message.messageID }) {
            message.depositedCourierKeys.formUnion(queue[existing].depositedCourierKeys)
            queue.remove(at: existing)
        }
        queue.append(message)

        // Enforce per-peer size limit with FIFO eviction
        if queue.count > Self.maxMessagesPerPeer {
            let evicted = queue.removeFirst()
            SecureLogger.warning("📤 Outbox overflow for \(peerID.id.prefix(8))… - evicted oldest message: \(evicted.messageID.prefix(8))…", category: .session)
            dropMessage(evicted.messageID, for: peerID)
        }
        outbox[peerID] = queue
        metrics?.record(.outboxQueued)
        persistOutbox()
    }

    @discardableResult
    private func removeQueuedMessage(_ messageID: String, for peerID: PeerID) -> Bool {
        guard let queue = outbox[peerID],
              let index = queue.firstIndex(where: { $0.messageID == messageID }) else {
            return false
        }
        var updated = queue
        updated.remove(at: index)
        outbox[peerID] = updated.isEmpty ? nil : updated
        return true
    }

    @discardableResult
    private func incrementSendAttemptsIfQueued(_ messageID: String, for peerID: PeerID) -> Bool {
        guard var queue = outbox[peerID],
              let index = queue.firstIndex(where: { $0.messageID == messageID }) else {
            // A synchronous delivery/read ack may have cleared the retained
            // copy while `sendPrivateMessage` was on the stack. Never
            // resurrect it from the flush snapshot.
            return false
        }
        queue[index].sendAttempts += 1
        outbox[peerID] = queue
        return true
    }

    private func dropMessage(_ messageID: String, for peerID: PeerID) {
        secureTransmissions.remove(PeerMessageKey(peerID: peerID, messageID: messageID))
        metrics?.record(.outboxDropped)
        onMessageDropped?(messageID, peerID)
    }

    private func persistOutbox() {
        outboxStore?.save(outbox)
    }

    /// A cold BLE restoration can launch before protected files are readable.
    /// The store initially returns an empty snapshot in that case, then calls
    /// back after first unlock. Merge by message ID instead of replacing work
    /// accepted during the locked wake, persist the union, and immediately
    /// resume normal delivery attempts.
    private func mergeRecoveredOutbox(_ recovered: MessageOutboxStore.Snapshot) {
        for (peerID, recoveredQueue) in recovered {
            var queue = outbox[peerID] ?? []
            for var recoveredMessage in recoveredQueue {
                if let index = queue.firstIndex(where: { $0.messageID == recoveredMessage.messageID }) {
                    recoveredMessage.sendAttempts = max(recoveredMessage.sendAttempts, queue[index].sendAttempts)
                    recoveredMessage.depositedCourierKeys.formUnion(queue[index].depositedCourierKeys)
                    queue[index] = recoveredMessage
                } else {
                    queue.append(recoveredMessage)
                }
            }
            queue.sort { $0.timestamp < $1.timestamp }
            if queue.count > Self.maxMessagesPerPeer {
                let overflow = queue.count - Self.maxMessagesPerPeer
                for dropped in queue.prefix(overflow) {
                    dropMessage(dropped.messageID, for: peerID)
                }
                queue.removeFirst(overflow)
            }
            outbox[peerID] = queue
        }
        persistOutbox()
        flushAllOutbox()
        retryBridgeCourierDeposits()
    }

    /// Panic wipe: forget queued mail on disk and in memory.
    func wipeOutbox() {
        outbox.removeAll()
        secureTransmissions.removeAll()
        outboxStore?.wipe()
    }

    /// Returns true only when the receipt was handed to a reachable transport.
    /// A false result means it was dropped (no route) and must NOT be recorded
    /// as sent, or the sender's message would stay unread forever — the receipt
    /// is retried on the next read scan (chat open / foreground / reconnect).
    @discardableResult
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) -> Bool {
        if let transport = reachableTransport(for: peerID) {
            SecureLogger.debug("Routing READ ack via \(type(of: transport)) to \(peerID.id.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…", category: .session)
            transport.sendReadReceipt(receipt, to: peerID)
            return true
        } else if !transports.isEmpty {
            SecureLogger.debug("No reachable transport for READ ack to \(peerID.id.prefix(8))… — leaving unsent for retry", category: .session)
        }
        return false
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        if let transport = connectedTransport(for: peerID) {
            transport.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        } else if let transport = reachableTransport(for: peerID) {
            transport.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        }
    }

    /// Retries only messages that the router previously transmitted through
    /// an already-established secure session and that still await an ack.
    ///
    /// A peer restart can leave that local session looking usable until the
    /// replacement handshake arrives; the first ciphertext is then
    /// undecryptable remotely. Normal pre-handshake sends are intentionally
    /// absent from `secureTransmissions` because BLE already queues
    /// and drains them when authentication completes.
    func retrySecurePrivateMessagesAfterAuthentication(for peerIDAliases: [PeerID]) {
        typealias Candidate = (
            peerID: PeerID,
            message: QueuedMessage,
            aliasOrder: Int,
            queueOrder: Int
        )

        var visitedPeerIDs = Set<PeerID>()
        var retriedMessageIDs = Set<String>()
        var outboxChanged = false
        let currentDate = now()
        var candidates: [Candidate] = []

        for (aliasOrder, peerID) in peerIDAliases.enumerated() {
            guard visitedPeerIDs.insert(peerID).inserted else { continue }
            guard let queued = outbox[peerID], !queued.isEmpty,
                  let transport = connectedTransport(for: peerID),
                  transport.canDeliverSecurely(to: peerID) else {
                continue
            }

            for (queueOrder, message) in queued.enumerated() {
                let key = PeerMessageKey(peerID: peerID, messageID: message.messageID)
                guard secureTransmissions.contains(key) else { continue }
                candidates.append((
                    peerID: peerID,
                    message: message,
                    aliasOrder: aliasOrder,
                    queueOrder: queueOrder
                ))
            }
        }

        // Conversation migration can leave retained messages split across the
        // ephemeral and stable outbox keys. Merge both queues into one
        // chronological stream so callback alias order cannot send newer mail
        // ahead of older mail.
        candidates.sort { lhs, rhs in
            if lhs.message.timestamp != rhs.message.timestamp {
                return lhs.message.timestamp < rhs.message.timestamp
            }
            if lhs.aliasOrder != rhs.aliasOrder {
                return lhs.aliasOrder < rhs.aliasOrder
            }
            if lhs.queueOrder != rhs.queueOrder {
                return lhs.queueOrder < rhs.queueOrder
            }
            return lhs.message.messageID < rhs.message.messageID
        }

        for candidate in candidates {
            let peerID = candidate.peerID
            let message = candidate.message
            let key = PeerMessageKey(peerID: peerID, messageID: message.messageID)
            guard retriedMessageIDs.insert(message.messageID).inserted,
                  secureTransmissions.contains(key),
                  queuedMessage(message.messageID, for: peerID) != nil,
                  let transport = connectedTransport(for: peerID),
                  transport.canDeliverSecurely(to: peerID) else {
                continue
            }

            if currentDate.timeIntervalSince(message.timestamp) > Self.messageTTLSeconds {
                if removeQueuedMessage(message.messageID, for: peerID) {
                    dropMessage(message.messageID, for: peerID)
                    outboxChanged = true
                }
                continue
            }

            guard message.sendAttempts < Self.maxSendAttempts else {
                SecureLogger.warning(
                    "📤 Dropping unacked PM for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… after \(message.sendAttempts) secure attempts",
                    category: .session
                )
                if removeQueuedMessage(message.messageID, for: peerID) {
                    dropMessage(message.messageID, for: peerID)
                    outboxChanged = true
                }
                continue
            }

            SecureLogger.debug(
                "Auth retry -> \(type(of: transport)) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…",
                category: .session
            )
            transport.sendPrivateMessage(
                message.content,
                to: peerID,
                recipientNickname: message.nickname,
                messageID: message.messageID
            )
            metrics?.record(.outboxResent)
            outboxChanged = incrementSendAttemptsIfQueued(message.messageID, for: peerID) || outboxChanged
        }

        if outboxChanged {
            persistOutbox()
        }
    }

    func flushOutbox(for peerID: PeerID) {
        guard let queued = outbox[peerID], !queued.isEmpty else { return }
        SecureLogger.debug("Flushing outbox for \(peerID.id.prefix(8))… count=\(queued.count)", category: .session)

        let now = now()
        var outboxChanged = false

        for message in queued {
            // A synchronous ack from an earlier send in this flush may have
            // removed an entry from the live outbox. The snapshot is only an
            // iteration order; never use it to recreate removed messages.
            guard queuedMessage(message.messageID, for: peerID) != nil else { continue }

            // Skip expired messages (TTL exceeded)
            if now.timeIntervalSince(message.timestamp) > Self.messageTTLSeconds {
                SecureLogger.debug("⏰ Expired queued message for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… (age: \(Int(now.timeIntervalSince(message.timestamp)))s)", category: .session)
                if removeQueuedMessage(message.messageID, for: peerID) {
                    dropMessage(message.messageID, for: peerID)
                    outboxChanged = true
                }
                continue
            }

            if let transport = connectedTransport(for: peerID), transport.canDeliverSecurely(to: peerID) {
                // A secure session is meaningful enough to retry, but not
                // proof that this particular ciphertext reached the peer: the
                // remote app may have restarted while our old session still
                // looked established. Retain until an ack, while bounding
                // actual secure transmissions for peers that never ack.
                guard message.sendAttempts < Self.maxSendAttempts else {
                    SecureLogger.warning("📤 Dropping unacked PM for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… after \(message.sendAttempts) attempts", category: .session)
                    if removeQueuedMessage(message.messageID, for: peerID) {
                        dropMessage(message.messageID, for: peerID)
                        outboxChanged = true
                    }
                    continue
                }
                SecureLogger.debug("Outbox -> \(type(of: transport)) (connected) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                secureTransmissions.insert(
                    PeerMessageKey(peerID: peerID, messageID: message.messageID)
                )
                transport.sendPrivateMessage(message.content, to: peerID, recipientNickname: message.nickname, messageID: message.messageID)
                metrics?.record(.outboxResent)
                outboxChanged = incrementSendAttemptsIfQueued(message.messageID, for: peerID) || outboxChanged
            } else if let transport = connectedTransport(for: peerID) {
                // "Connected" without a secure session — possibly a stolen
                // binding from a replayed announce: send (a genuine link
                // finishes the handshake and delivers) but keep retaining
                // until an ack clears it. These flushes do NOT count toward
                // the attempt-cap drop: the message was transmitted over a
                // live link, so a peer whose handshake stalls across
                // reconnect flapping must not burn through the cap and lose
                // the store-and-forward copy this retention exists to
                // preserve. Retention stays bounded by the 24h outbox TTL
                // and the per-peer FIFO cap.
                SecureLogger.debug("Outbox -> \(type(of: transport)) (connected, no secure session) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                secureTransmissions.remove(
                    PeerMessageKey(peerID: peerID, messageID: message.messageID)
                )
                transport.sendPrivateMessage(message.content, to: peerID, recipientNickname: message.nickname, messageID: message.messageID)
                metrics?.record(.outboxResent)
            } else if let transport = reachableTransport(for: peerID) {
                // Reachability without a connection is a freshness heuristic,
                // so the send can silently go nowhere: send but keep retaining
                // until an ack clears it, bounded by attempt count for peers
                // that never ack.
                guard message.sendAttempts < Self.maxSendAttempts else {
                    SecureLogger.warning("📤 Dropping unacked PM for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… after \(message.sendAttempts) attempts", category: .session)
                    if removeQueuedMessage(message.messageID, for: peerID) {
                        dropMessage(message.messageID, for: peerID)
                        outboxChanged = true
                    }
                    continue
                }
                SecureLogger.debug("Outbox -> \(type(of: transport)) (reachable) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                transport.sendPrivateMessage(message.content, to: peerID, recipientNickname: message.nickname, messageID: message.messageID)
                metrics?.record(.outboxResent)
                outboxChanged = incrementSendAttemptsIfQueued(message.messageID, for: peerID) || outboxChanged
            }
        }

        if outboxChanged {
            persistOutbox()
        }
    }

    func flushAllOutbox() {
        for key in Array(outbox.keys) { flushOutbox(for: key) }
    }

    /// Periodically clean up expired messages from all outboxes
    func cleanupExpiredMessages() {
        let now = now()
        var droppedAny = false
        for peerID in Array(outbox.keys) {
            var expiredMessageIDs: [String] = []
            outbox[peerID]?.removeAll { message in
                guard now.timeIntervalSince(message.timestamp) > Self.messageTTLSeconds else { return false }
                expiredMessageIDs.append(message.messageID)
                return true
            }
            if outbox[peerID]?.isEmpty == true {
                outbox.removeValue(forKey: peerID)
            }
            for messageID in expiredMessageIDs {
                SecureLogger.debug("⏰ Expired queued message for \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
                dropMessage(messageID, for: peerID)
                droppedAny = true
            }
        }
        if droppedAny {
            persistOutbox()
        }
    }
}
