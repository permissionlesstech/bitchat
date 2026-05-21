import BitLogger
import BitFoundation
import Foundation

/// Routes messages using available transports (Mesh, Nostr, etc.)
@MainActor
final class MessageRouter {
    private let transports: [Transport]

    // Outbox entry with timestamp for TTL-based eviction
    private struct QueuedMessage {
        let destinationPeerID: PeerID
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
        transports.first { transport in
            candidatePeerIDs(for: peerID).contains { transport.isPeerReachable($0) }
        }
    }

    private func connectedTransport(for peerID: PeerID) -> Transport? {
        transports.first { transport in
            candidatePeerIDs(for: peerID).contains { transport.isPeerConnected($0) }
        }
    }

    private func candidatePeerIDs(for peerID: PeerID) -> [PeerID] {
        let shortPeerID = peerID.toShort()
        return shortPeerID == peerID ? [peerID] : [peerID, shortPeerID]
    }

    private func outboxKey(for peerID: PeerID) -> PeerID {
        peerID.toShort()
    }

    // MARK: - Message Sending

    func sendPrivate(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        if let transport = reachableTransport(for: peerID) {
            SecureLogger.debug("Routing PM via \(type(of: transport)) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        } else {
            let key = outboxKey(for: peerID)
            // Queue for later with timestamp for TTL tracking
            if outbox[key] == nil { outbox[key] = [] }

            let message = QueuedMessage(destinationPeerID: peerID, content: content, nickname: recipientNickname, messageID: messageID, timestamp: Date())
            outbox[key]?.append(message)

            // Enforce per-peer size limit with FIFO eviction
            if let count = outbox[key]?.count, count > Self.maxMessagesPerPeer {
                let evicted = outbox[key]?.removeFirst()
                SecureLogger.warning("📤 Outbox overflow for \(key.id.prefix(8))… - evicted oldest message: \(evicted?.messageID.prefix(8) ?? "?")…", category: .session)
            }

            SecureLogger.debug("Queued PM for \(peerID.id.prefix(8))… (no reachable transport) id=\(messageID.prefix(8))… queue=\(outbox[key]?.count ?? 0)", category: .session)
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
        let key = outboxKey(for: peerID)
        let matchingKeys = Array(outbox.keys.filter { $0 == peerID || outboxKey(for: $0) == key })
        guard !matchingKeys.isEmpty else { return }

        let queued = matchingKeys.flatMap { outbox[$0] ?? [] }
        guard !queued.isEmpty else { return }

        for matchingKey in matchingKeys {
            outbox.removeValue(forKey: matchingKey)
        }

        SecureLogger.debug("Flushing outbox for \(key.id.prefix(8))… count=\(queued.count)", category: .session)

        let now = Date()
        var remaining: [QueuedMessage] = []

        for message in queued {
            // Skip expired messages (TTL exceeded)
            if now.timeIntervalSince(message.timestamp) > Self.messageTTLSeconds {
                SecureLogger.debug("⏰ Expired queued message for \(message.destinationPeerID.id.prefix(8))… id=\(message.messageID.prefix(8))… (age: \(Int(now.timeIntervalSince(message.timestamp)))s)", category: .session)
                continue
            }

            if let transport = reachableTransport(for: message.destinationPeerID) {
                SecureLogger.debug("Outbox -> \(type(of: transport)) for \(message.destinationPeerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                transport.sendPrivateMessage(message.content, to: message.destinationPeerID, recipientNickname: message.nickname, messageID: message.messageID)
            } else {
                remaining.append(message)
            }
        }

        for message in remaining {
            outbox[outboxKey(for: message.destinationPeerID), default: []].append(message)
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
