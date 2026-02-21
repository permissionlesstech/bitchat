import BitLogger
import Foundation

/// Routes messages using available transports (Mesh, Nostr, etc.)
@MainActor
final class MessageRouter {
    private let transports: [Transport]

    // Outbox entry with timestamp for TTL-based eviction
    private struct QueuedMessage {
        let content: String
        let nickname: String
        let messageID: String
        let timestamp: Date
        // Tracks when this message was last handed to a transport.
        // nil = never sent (peer was offline). Messages stay in the outbox
        // until a delivery ack confirms receipt.
        var sentAt: Date?
    }

    private var outbox: [PeerID: [QueuedMessage]] = [:]

    // Outbox limits to prevent unbounded memory growth
    private static let maxMessagesPerPeer = 100
    private static let messageTTLSeconds: TimeInterval = 24 * 60 * 60 // 24 hours
    // Don't resend a message that was handed to transport less than this many seconds ago
    private static let resendCooldownSeconds: TimeInterval = 30

    init(transports: [Transport]) {
        self.transports = transports

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

    private func connectedTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerConnected(peerID) }
    }

    private func reachableTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerReachable(peerID) }
    }

    // MARK: - Message Sending

    func sendPrivate(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        // Normalize to short ID for consistent outbox keying (handles both 16-hex and 64-hex formats)
        let normalizedPeerID = peerID.toShort()

        // Always-queue-first: append to outbox, then flush immediately.
        // Messages stay in the outbox until a delivery ack confirms receipt.
        // When peer is connected, the message is queued and instantly flushed (sent).
        // When offline, it stays in the outbox until the peer reconnects.
        if outbox[normalizedPeerID] == nil { outbox[normalizedPeerID] = [] }

        let message = QueuedMessage(content: content, nickname: recipientNickname, messageID: messageID, timestamp: Date(), sentAt: nil)
        outbox[normalizedPeerID]?.append(message)

        // Enforce per-peer size limit with FIFO eviction
        if let count = outbox[normalizedPeerID]?.count, count > Self.maxMessagesPerPeer {
            let evicted = outbox[normalizedPeerID]?.removeFirst()
            SecureLogger.warning("Outbox overflow for \(normalizedPeerID.id.prefix(8))… - evicted oldest message: \(evicted?.messageID.prefix(8) ?? "?")…", category: .session)
        }

        let isConnected = connectedTransport(for: normalizedPeerID) != nil
        SecureLogger.debug("Queued PM for \(normalizedPeerID.id.prefix(8))… id=\(messageID.prefix(8))… queue=\(outbox[normalizedPeerID]?.count ?? 0) connected=\(isConnected)", category: .session)

        // Try immediate delivery
        flushOutbox(for: normalizedPeerID)
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        let normalizedPeerID = peerID.toShort()
        if let transport = reachableTransport(for: normalizedPeerID) {
            SecureLogger.debug("Routing READ ack via \(type(of: transport)) to \(normalizedPeerID.id.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…", category: .session)
            transport.sendReadReceipt(receipt, to: normalizedPeerID)
        } else if !transports.isEmpty {
            SecureLogger.debug("No reachable transport for READ ack to \(normalizedPeerID.id.prefix(8))…", category: .session)
        }
    }

    func sendDeliveryAck(_ messageID: String, to peerID: PeerID) {
        let normalizedPeerID = peerID.toShort()
        if let transport = reachableTransport(for: normalizedPeerID) {
            SecureLogger.debug("Routing DELIVERED ack via \(type(of: transport)) to \(normalizedPeerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            transport.sendDeliveryAck(for: messageID, to: normalizedPeerID)
        }
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        let normalizedPeerID = peerID.toShort()
        if let transport = connectedTransport(for: normalizedPeerID) {
            transport.sendFavoriteNotification(to: normalizedPeerID, isFavorite: isFavorite)
        } else if let transport = reachableTransport(for: normalizedPeerID) {
            transport.sendFavoriteNotification(to: normalizedPeerID, isFavorite: isFavorite)
        }
    }

    // MARK: - Outbox Management

    /// Peer IDs that currently have queued messages in the outbox (for diagnostics)
    var pendingPeerIDs: [PeerID] {
        Array(outbox.keys)
    }

    func flushOutbox(for peerID: PeerID) {
        // Normalize to short ID for consistent outbox lookup (handles both 16-hex and 64-hex formats)
        let normalizedPeerID = peerID.toShort()
        guard var queued = outbox[normalizedPeerID], !queued.isEmpty else {
            return
        }

        let transport = connectedTransport(for: normalizedPeerID)
        let now = Date()
        var sentCount = 0

        // Remove expired messages first (reverse to preserve indices)
        for i in queued.indices.reversed() {
            if now.timeIntervalSince(queued[i].timestamp) > Self.messageTTLSeconds {
                queued.remove(at: i)
            }
        }

        // Send in order (oldest first) to preserve message ordering
        for i in queued.indices {
            // Skip messages recently sent (waiting for delivery ack)
            if let sentAt = queued[i].sentAt, now.timeIntervalSince(sentAt) < Self.resendCooldownSeconds {
                continue
            }

            // Send if transport is available
            if let transport = transport {
                transport.sendPrivateMessage(queued[i].content, to: normalizedPeerID, recipientNickname: queued[i].nickname, messageID: queued[i].messageID)
                queued[i].sentAt = now
                sentCount += 1
            }
        }

        if queued.isEmpty {
            outbox.removeValue(forKey: normalizedPeerID)
        } else {
            outbox[normalizedPeerID] = queued
        }

        if sentCount > 0 {
            SecureLogger.debug("Flush for \(normalizedPeerID.id.prefix(8))…: sent=\(sentCount) remaining=\(queued.count)", category: .session)
        }
    }

    func flushAllOutbox() {
        let pending = Array(outbox.keys)
        guard !pending.isEmpty else { return }
        SecureLogger.debug("Flushing all outboxes: \(pending.count) peers pending", category: .session)
        for key in pending { flushOutbox(for: key) }
    }

    /// Remove a message from the outbox after delivery is confirmed via ack.
    func confirmDelivery(messageID: String) {
        for peerID in Array(outbox.keys) {
            if let idx = outbox[peerID]?.firstIndex(where: { $0.messageID == messageID }) {
                outbox[peerID]?.remove(at: idx)
                if outbox[peerID]?.isEmpty == true {
                    outbox.removeValue(forKey: peerID)
                }
                return
            }
        }
    }

    /// Clear sentAt timestamps for a peer so queued messages are resent on reconnect.
    func resetSendState(for peerID: PeerID) {
        let normalizedPeerID = peerID.toShort()
        guard var queued = outbox[normalizedPeerID], !queued.isEmpty else { return }
        for i in queued.indices {
            queued[i].sentAt = nil
        }
        outbox[normalizedPeerID] = queued
        SecureLogger.debug("Reset send state for \(normalizedPeerID.id.prefix(8))…: \(queued.count) messages will be resent", category: .session)
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
