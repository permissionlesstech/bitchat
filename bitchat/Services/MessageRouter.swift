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
    }

    private var outbox: [PeerID: [QueuedMessage]] = [:]

    // Outbox limits to prevent unbounded memory growth
    private static let maxMessagesPerPeer = 100
    private static let messageTTLSeconds: TimeInterval = 24 * 60 * 60 // 24 hours

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

    private func reachableTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerReachable(peerID) }
    }

    private func connectedTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerConnected(peerID) }
    }

    // MARK: - Message Sending

    func sendPrivate(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        if let transport = reachableTransport(for: peerID) {
            SecureLogger.debug("Routing PM via \(type(of: transport)) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        } else {
            // Queue for later with timestamp for TTL tracking
            if outbox[peerID] == nil { outbox[peerID] = [] }

            let message = QueuedMessage(content: content, nickname: recipientNickname, messageID: messageID, timestamp: Date())
            outbox[peerID]?.append(message)

            // Enforce per-peer size limit with FIFO eviction
            if let count = outbox[peerID]?.count, count > Self.maxMessagesPerPeer {
                let evicted = outbox[peerID]?.removeFirst()
                SecureLogger.warning("📤 Outbox overflow for \(peerID.id.prefix(8))… - evicted oldest message: \(evicted?.messageID.prefix(8) ?? "?")…", category: .session)
            }

            SecureLogger.debug("Queued PM for \(peerID.id.prefix(8))… (no reachable transport) id=\(messageID.prefix(8))… queue=\(outbox[peerID]?.count ?? 0)", category: .session)
        }
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

        let now = Date()
        var remaining: [QueuedMessage] = []

        for message in queued {
            // Skip expired messages (TTL exceeded)
            if now.timeIntervalSince(message.timestamp) > Self.messageTTLSeconds {
                SecureLogger.debug("⏰ Expired queued message for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… (age: \(Int(now.timeIntervalSince(message.timestamp)))s)", category: .session)
                continue
            }

            if let transport = reachableTransport(for: peerID) {
                SecureLogger.debug("Outbox -> \(type(of: transport)) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                transport.sendPrivateMessage(message.content, to: peerID, recipientNickname: message.nickname, messageID: message.messageID)
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
