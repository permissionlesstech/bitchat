import BitLogger
import BitFoundation
import Foundation

/// Trust and identity lookups the router needs to pick couriers. Backed by
/// the favorites store in production; injectable for tests.
struct CourierDirectory {
    /// Noise static key for a peer we can address while they're offline.
    var noiseKey: (PeerID) -> Data?
    /// Whether a peer (by Noise static key) may carry our mail.
    var isTrustedCourier: (Data) -> Bool

    @MainActor
    static func favoritesBacked() -> CourierDirectory {
        CourierDirectory(
            noiseKey: { peerID in
                FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID)?.peerNoisePublicKey
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
    private let transports: [Transport]
    private let now: () -> Date
    private let courierDirectory: CourierDirectory

    /// Invoked whenever a retained private message is dropped without a
    /// delivery ack (attempt cap, TTL expiry, or per-peer overflow eviction)
    /// so the UI can surface the failure instead of leaving the message in a
    /// stale "sending/sent" state forever.
    var onMessageDropped: ((_ messageID: String, _ peerID: PeerID) -> Void)?

    /// Invoked when a message with no reachable transport was handed to at
    /// least one courier (a connected mutual favorite who will physically
    /// carry the sealed envelope). Delivery stays best-effort: the outbox
    /// retains the message until an ack arrives.
    var onMessageCarried: ((_ messageID: String, _ peerID: PeerID) -> Void)?

    // Outbox entry with timestamp for TTL-based eviction
    private struct QueuedMessage {
        let content: String
        let nickname: String
        let messageID: String
        let timestamp: Date
        var sendAttempts: Int = 0
    }

    private var outbox: [PeerID: [QueuedMessage]] = [:]

    // Outbox limits to prevent unbounded memory growth
    private static let maxMessagesPerPeer = 100
    private static let messageTTLSeconds: TimeInterval = 24 * 60 * 60 // 24 hours
    // Bound resends of messages sent on a weak reachability signal that never
    // get a delivery ack (e.g. peer on an old client that doesn't ack).
    private static let maxSendAttempts = 8
    // Redundant couriers improve delivery odds; receivers dedup by message ID.
    private static let maxCouriersPerMessage = 3

    init(
        transports: [Transport],
        now: @escaping () -> Date = Date.init,
        courierDirectory: CourierDirectory? = nil
    ) {
        self.transports = transports
        self.now = now
        self.courierDirectory = courierDirectory ?? .favoritesBacked()

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
               let _ = note.userInfo?["isKeyUpdate"] as? Bool {
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
        if let transport = connectedTransport(for: peerID) {
            // A live link is a strong delivery signal; trust it outright.
            SecureLogger.debug("Routing PM via \(type(of: transport)) (connected) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
            return
        }

        let message = QueuedMessage(content: content, nickname: recipientNickname, messageID: messageID, timestamp: now(), sendAttempts: 1)
        if let transport = reachableTransport(for: peerID) {
            // Reachability without a connection is a freshness heuristic (e.g.
            // the mesh retention window), so the send can silently go nowhere.
            // Send now, but retain a copy until a delivery/read ack clears it;
            // receivers dedup resends by message ID.
            SecureLogger.debug("Routing PM via \(type(of: transport)) (reachable) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
            enqueue(message, for: peerID)
        } else {
            var unsent = message
            unsent.sendAttempts = 0
            enqueue(unsent, for: peerID)
            SecureLogger.debug("Queued PM for \(peerID.id.prefix(8))… (no reachable transport) id=\(messageID.prefix(8))… queue=\(outbox[peerID]?.count ?? 0)", category: .session)
            attemptCourierDeposit(content: content, messageID: messageID, for: peerID)
        }
    }

    /// Last resort when no transport can reach the peer: seal the message to
    /// their known static key and hand it to connected mutual favorites who
    /// may physically encounter them. The queued copy above stays retained,
    /// so direct delivery still wins if the peer reappears first (receivers
    /// dedup by message ID).
    private func attemptCourierDeposit(content: String, messageID: String, for peerID: PeerID) {
        guard let recipientKey = courierDirectory.noiseKey(peerID) else { return }
        for transport in transports {
            let couriers = transport.currentPeerSnapshots()
                .filter { snapshot in
                    guard snapshot.isConnected,
                          let key = snapshot.noisePublicKey,
                          key != recipientKey else { return false }
                    return courierDirectory.isTrustedCourier(key)
                }
                .prefix(Self.maxCouriersPerMessage)
                .map(\.peerID)
            guard !couriers.isEmpty else { continue }
            if transport.sendCourierMessage(content, messageID: messageID, recipientNoiseKey: recipientKey, via: Array(couriers)) {
                SecureLogger.debug("📦 PM \(messageID.prefix(8))… handed to \(couriers.count) courier(s) for \(peerID.id.prefix(8))…", category: .session)
                onMessageCarried?(messageID, peerID)
                return
            }
        }
    }

    /// A delivery or read ack confirms receipt; stop retaining the message.
    func markDelivered(_ messageID: String) {
        for (peerID, queue) in outbox {
            let filtered = queue.filter { $0.messageID != messageID }
            guard filtered.count != queue.count else { continue }
            outbox[peerID] = filtered.isEmpty ? nil : filtered
        }
    }

    private func enqueue(_ message: QueuedMessage, for peerID: PeerID) {
        var queue = outbox[peerID] ?? []
        // Re-sending an already-queued ID replaces the entry (keeps attempt count fresh)
        queue.removeAll { $0.messageID == message.messageID }
        queue.append(message)

        // Enforce per-peer size limit with FIFO eviction
        if queue.count > Self.maxMessagesPerPeer {
            let evicted = queue.removeFirst()
            SecureLogger.warning("📤 Outbox overflow for \(peerID.id.prefix(8))… - evicted oldest message: \(evicted.messageID.prefix(8))…", category: .session)
            onMessageDropped?(evicted.messageID, peerID)
        }
        outbox[peerID] = queue
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        if let transport = reachableTransport(for: peerID) {
            SecureLogger.debug("Routing READ ack via \(type(of: transport)) to \(peerID.id.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…", category: .session)
            transport.sendReadReceipt(receipt, to: peerID)
        } else if !transports.isEmpty {
            SecureLogger.debug("No reachable transport for READ ack to \(peerID.id.prefix(8))…", category: .session)
        }
    }

    func sendDeliveryAck(_ messageID: String, to peerID: PeerID) {
        if let transport = reachableTransport(for: peerID) {
            SecureLogger.debug("Routing DELIVERED ack via \(type(of: transport)) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            transport.sendDeliveryAck(for: messageID, to: peerID)
        }
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        if let transport = connectedTransport(for: peerID) {
            transport.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        } else if let transport = reachableTransport(for: peerID) {
            transport.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        }
    }

    // MARK: - Outbox Management

    func flushOutbox(for peerID: PeerID) {
        guard let queued = outbox[peerID], !queued.isEmpty else { return }
        SecureLogger.debug("Flushing outbox for \(peerID.id.prefix(8))… count=\(queued.count)", category: .session)

        let now = now()
        var remaining: [QueuedMessage] = []

        for message in queued {
            // Skip expired messages (TTL exceeded)
            if now.timeIntervalSince(message.timestamp) > Self.messageTTLSeconds {
                SecureLogger.debug("⏰ Expired queued message for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… (age: \(Int(now.timeIntervalSince(message.timestamp)))s)", category: .session)
                onMessageDropped?(message.messageID, peerID)
                continue
            }

            if let transport = connectedTransport(for: peerID) {
                // Live link: send and stop retaining.
                SecureLogger.debug("Outbox -> \(type(of: transport)) (connected) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                transport.sendPrivateMessage(message.content, to: peerID, recipientNickname: message.nickname, messageID: message.messageID)
            } else if let transport = reachableTransport(for: peerID) {
                // Weak signal: send but keep retaining until an ack clears it,
                // bounded by attempt count for peers that never ack.
                guard message.sendAttempts < Self.maxSendAttempts else {
                    SecureLogger.warning("📤 Dropping unacked PM for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… after \(message.sendAttempts) attempts", category: .session)
                    onMessageDropped?(message.messageID, peerID)
                    continue
                }
                SecureLogger.debug("Outbox -> \(type(of: transport)) (reachable) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                transport.sendPrivateMessage(message.content, to: peerID, recipientNickname: message.nickname, messageID: message.messageID)
                var retained = message
                retained.sendAttempts += 1
                remaining.append(retained)
            } else {
                remaining.append(message)
            }
        }

        if remaining.isEmpty {
            outbox.removeValue(forKey: peerID)
        } else {
            outbox[peerID] = remaining
        }
    }

    func flushAllOutbox() {
        for key in Array(outbox.keys) { flushOutbox(for: key) }
    }

    /// Periodically clean up expired messages from all outboxes
    func cleanupExpiredMessages() {
        let now = now()
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
                onMessageDropped?(messageID, peerID)
            }
        }
    }
}
