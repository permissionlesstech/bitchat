import Foundation

/// Routes messages between BLE and Nostr transports
@MainActor
final class MessageRouter {
    private let mesh: Transport
    private let nostr: NostrTransport
    private var outbox: [String: [(content: String, nickname: String, messageID: String)]] = [:] // peerID -> queued messages

    init(mesh: Transport, nostr: NostrTransport) {
        self.mesh = mesh
        self.nostr = nostr
        self.nostr.senderPeerID = mesh.myPeerID

        // Observe favorites changes to learn Nostr mapping and flush queued messages
        NotificationCenter.default.addObserver(
            forName: .favoriteStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let data = note.userInfo?["peerPublicKey"] as? Data {
                let peerID = PeerIDUtils.derivePeerID(fromPublicKey: data)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
            // Handle key updates
            if let newKey = note.userInfo?["peerPublicKey"] as? Data,
               let _ = note.userInfo?["isKeyUpdate"] as? Bool {
                let peerID = PeerIDUtils.derivePeerID(fromPublicKey: newKey)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
        }
    }

    func sendPrivate(_ content: String, to peerID: String, recipientNickname: String, messageID: String) {
        let reachableMesh = mesh.isPeerReachable(peerID)
        if reachableMesh {
            SecureLogger.log("Routing PM via mesh (reachable) to \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            // BLEService will initiate a handshake if needed and queue the message
            mesh.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        } else if canSendViaNostr(peerID: peerID) {
            SecureLogger.log("Routing PM via Nostr to \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            nostr.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        } else {
            // Queue for later (when mesh connects or Nostr mapping appears)
            if outbox[peerID] == nil { outbox[peerID] = [] }
            outbox[peerID]?.append((content, recipientNickname, messageID))
            SecureLogger.log("Queued PM for \(peerID.prefix(8))… (no mesh, no Nostr mapping) id=\(messageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
        }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String) {
        // Prefer mesh for reachable peers; BLE will queue if handshake is needed
        if mesh.isPeerReachable(peerID) {
            SecureLogger.log("Routing READ ack via mesh (reachable) to \(peerID.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            mesh.sendReadReceipt(receipt, to: peerID)
        } else {
            SecureLogger.log("Routing READ ack via Nostr to \(peerID.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            nostr.sendReadReceipt(receipt, to: peerID)
        }
    }

    func sendDeliveryAck(_ messageID: String, to peerID: String) {
        if mesh.isPeerReachable(peerID) {
            SecureLogger.log("Routing DELIVERED ack via mesh (reachable) to \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                            category: SecureLogger.session, level: .debug)
            mesh.sendDeliveryAck(for: messageID, to: peerID)
        } else {
            nostr.sendDeliveryAck(for: messageID, to: peerID)
        }
    }

    func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        if mesh.isPeerConnected(peerID) {
            mesh.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        } else {
            nostr.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        }
    }

    // MARK: - Outbox Management
    private func canSendViaNostr(peerID: String) -> Bool {
        guard let noiseKey = Data(hexString: peerID) else { return false }
        if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
           fav.peerNostrPublicKey != nil {
            return true
        }
        return false
    }

    func flushOutbox(for peerID: String) {
        guard let queued = outbox[peerID], !queued.isEmpty else { return }
        SecureLogger.log("Flushing outbox for \(peerID.prefix(8))… count=\(queued.count)",
                        category: SecureLogger.session, level: .debug)
        // Prefer mesh if connected; else try Nostr if mapping exists
        for (content, nickname, messageID) in queued {
            if mesh.isPeerReachable(peerID) {
                SecureLogger.log("Outbox -> mesh for \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                                category: SecureLogger.session, level: .debug)
                mesh.sendPrivateMessage(content, to: peerID, recipientNickname: nickname, messageID: messageID)
            } else if canSendViaNostr(peerID: peerID) {
                SecureLogger.log("Outbox -> Nostr for \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                                category: SecureLogger.session, level: .debug)
                nostr.sendPrivateMessage(content, to: peerID, recipientNickname: nickname, messageID: messageID)
            } else {
                continue
            }
        }
        // Remove all flushed items (remaining ones, if any, will be re-queued on next call)
        outbox[peerID]?.removeAll()
    }

    func flushAllOutbox() {
        for key in outbox.keys { flushOutbox(for: key) }
    }
}
