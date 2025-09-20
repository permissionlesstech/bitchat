import BitLogger
import Foundation

/// Routes messages between BLE and Nostr transports
@MainActor
final class MessageRouter {
    private let mesh: Transport
    private let nostr: NostrTransport
    private var outbox: [Peer: [(content: String, nickname: String, messageID: String)]] = [:] // Peer -> queued messages

    init(mesh: Transport, nostr: NostrTransport) {
        self.mesh = mesh
        self.nostr = nostr
        self.nostr.senderPeer = mesh.myPeer

        // Observe favorites changes to learn Nostr mapping and flush queued messages
        NotificationCenter.default.addObserver(
            forName: .favoriteStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let data = note.userInfo?["peerPublicKey"] as? Data {
                let peer = Peer(publicKey: data)
                Task { @MainActor in
                    self.flushOutbox(for: peer)
                }
            }
            // Handle key updates
            if let newKey = note.userInfo?["peerPublicKey"] as? Data,
               let _ = note.userInfo?["isKeyUpdate"] as? Bool {
                let peer = Peer(publicKey: newKey)
                Task { @MainActor in
                    self.flushOutbox(for: peer)
                }
            }
        }
    }

    func sendPrivate(_ content: String, to peer: Peer, recipientNickname: String, messageID: String) {
        let reachableMesh = mesh.isPeerReachable(peer)
        if reachableMesh {
            SecureLogger.debug("Routing PM via mesh (reachable) to \(peer.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            // BLEService will initiate a handshake if needed and queue the message
            mesh.sendPrivateMessage(content, to: peer, recipientNickname: recipientNickname, messageID: messageID)
        } else if canSendViaNostr(peer: peer) {
            SecureLogger.debug("Routing PM via Nostr to \(peer.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            nostr.sendPrivateMessage(content, to: peer, recipientNickname: recipientNickname, messageID: messageID)
        } else {
            // Queue for later (when mesh connects or Nostr mapping appears)
            if outbox[peer] == nil { outbox[peer] = [] }
            outbox[peer]?.append((content, recipientNickname, messageID))
            SecureLogger.debug("Queued PM for \(peer.id.prefix(8))… (no mesh, no Nostr mapping) id=\(messageID.prefix(8))…", category: .session)
        }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peer: Peer) {
        // Prefer mesh for reachable peers; BLE will queue if handshake is needed
        if mesh.isPeerReachable(peer) {
            SecureLogger.debug("Routing READ ack via mesh (reachable) to \(peer.id.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…", category: .session)
            mesh.sendReadReceipt(receipt, to: peer)
        } else {
            SecureLogger.debug("Routing READ ack via Nostr to \(peer.id.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…", category: .session)
            nostr.sendReadReceipt(receipt, to: peer)
        }
    }

    func sendDeliveryAck(_ messageID: String, to peer: Peer) {
        if mesh.isPeerReachable(peer) {
            SecureLogger.debug("Routing DELIVERED ack via mesh (reachable) to \(peer.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            mesh.sendDeliveryAck(for: messageID, to: peer)
        } else {
            nostr.sendDeliveryAck(for: messageID, to: peer)
        }
    }

    func sendFavoriteNotification(to peer: Peer, isFavorite: Bool) {
        // Route via mesh when connected; else use Nostr
        if mesh.isPeerConnected(peer) {
            mesh.sendFavoriteNotification(to: peer, isFavorite: isFavorite)
        } else {
            nostr.sendFavoriteNotification(to: peer, isFavorite: isFavorite)
        }
    }

    // MARK: - Outbox Management
    private func canSendViaNostr(peer: Peer) -> Bool {
        // Two forms are supported:
        // - 64-hex Noise public key (32 bytes)
        // - 16-hex short peer ID (derived from Noise pubkey)
        if let noiseKey = peer.noiseKey {
            if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
               fav.peerNostrPublicKey != nil {
                return true
            }
        } else if peer.isShort {
            if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: peer),
               fav.peerNostrPublicKey != nil {
                return true
            }
        }
        return false
    }

    func flushOutbox(for peer: Peer) {
        guard let queued = outbox[peer], !queued.isEmpty else { return }
        SecureLogger.debug("Flushing outbox for \(peer.id.prefix(8))… count=\(queued.count)", category: .session)
        var remaining: [(content: String, nickname: String, messageID: String)] = []
        // Prefer mesh if connected; else try Nostr if mapping exists
        for (content, nickname, messageID) in queued {
            if mesh.isPeerReachable(peer) {
                SecureLogger.debug("Outbox -> mesh for \(peer.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
                mesh.sendPrivateMessage(content, to: peer, recipientNickname: nickname, messageID: messageID)
            } else if canSendViaNostr(peer: peer) {
                SecureLogger.debug("Outbox -> Nostr for \(peer.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
                nostr.sendPrivateMessage(content, to: peer, recipientNickname: nickname, messageID: messageID)
            } else {
                // Keep unsent items queued
                remaining.append((content, nickname, messageID))
            }
        }
        // Persist only items we could not send
        if remaining.isEmpty {
            outbox.removeValue(forKey: peer)
        } else {
            outbox[peer] = remaining
        }
    }

    func flushAllOutbox() {
        for key in Array(outbox.keys) { flushOutbox(for: key) }
    }
}
