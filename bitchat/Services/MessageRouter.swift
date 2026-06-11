import BitLogger
import BitFoundation
import Foundation

/// Routes messages using available transports (Mesh, Nostr, etc.)
@MainActor
final class MessageRouter {
    private let transports: [Transport]
    // Used to stamp our own Nostr identity onto favorite notifications so the
    // recipient can learn our npub. Optional so tests can omit it.
    private let idBridge: NostrIdentityBridge?

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

    init(transports: [Transport], idBridge: NostrIdentityBridge? = nil) {
        self.transports = transports
        self.idBridge = idBridge

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
        // Normalize to the short ID so the outbox is keyed consistently. Callers
        // pass either a 16-hex short ID (active chat) or a 64-hex noise-key ID
        // (e.g. favorite toggles); a peer reconnect flushes by short ID, so a
        // mismatch would otherwise leave queued messages stranded.
        let peerID = peerID.toShort()
        if let transport = connectedTransport(for: peerID) {
            // A live link is a strong delivery signal; trust it outright.
            SecureLogger.debug("Routing PM via \(type(of: transport)) (connected) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
            return
        }

        let message = QueuedMessage(content: content, nickname: recipientNickname, messageID: messageID, timestamp: Date(), sendAttempts: 1)
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
        // Route favorites through the outbox (same `[FAVORITED]:<npub>` payload the
        // transports built internally) so they survive a Noise handshake delay or
        // offline queuing instead of being dropped when the peer is momentarily
        // unreachable. The recipient parses the prefix and never displays it.
        var content = isFavorite ? "[FAVORITED]" : "[UNFAVORITED]"
        if let npub = try? idBridge?.getCurrentNostrIdentity()?.npub {
            content += ":" + npub
        }
        sendPrivate(content, to: peerID, recipientNickname: "", messageID: UUID().uuidString)
    }

    // MARK: - Outbox Management

    func flushOutbox(for peerID: PeerID) {
        // Match the short-ID keying used when enqueuing in sendPrivate.
        let peerID = peerID.toShort()
        guard let queued = outbox[peerID], !queued.isEmpty else { return }
        SecureLogger.debug("Flushing outbox for \(peerID.id.prefix(8))… count=\(queued.count)", category: .session)

        let now = Date()
        var remaining: [QueuedMessage] = []

        for message in queued {
            // Skip expired messages (TTL exceeded)
            if now.timeIntervalSince(message.timestamp) > Self.messageTTLSeconds {
                SecureLogger.debug("⏰ Expired queued message for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… (age: \(Int(now.timeIntervalSince(message.timestamp)))s)", category: .session)
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
        let now = Date()
        for peerID in Array(outbox.keys) {
            outbox[peerID]?.removeAll { now.timeIntervalSince($0.timestamp) > Self.messageTTLSeconds }
            if outbox[peerID]?.isEmpty == true {
                outbox.removeValue(forKey: peerID)
            }
        }
    }
}
