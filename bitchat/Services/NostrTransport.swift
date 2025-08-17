import Foundation
import Combine

// Minimal Nostr transport conforming to Transport for offline sending
final class NostrTransport: Transport {
    weak var delegate: BitchatDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        Just([]).eraseToAnyPublisher()
    }
    func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }

    // Provide BLE short peer ID for BitChat embedding
    var senderPeerID: String = ""

    var myPeerID: String { senderPeerID }
    var myNickname: String { "" }
    func setNickname(_ nickname: String) { /* not used for Nostr */ }

    func startServices() { /* no-op */ }
    func stopServices() { /* no-op */ }
    func emergencyDisconnectAll() { /* no-op */ }

    func isPeerConnected(_ peerID: String) -> Bool { false }
    func getPeerNicknames() -> [String : String] { [:] }

    func getFingerprint(for peerID: String) -> String? { nil }
    func getNoiseSessionState(for peerID: String) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: String) { /* no-op */ }
    func getNoiseService() -> NoiseEncryptionService { NoiseEncryptionService() }

    // Public broadcast not supported over Nostr here
    func sendMessage(_ content: String, mentions: [String]) { /* no-op */ }

    func sendPrivateMessage(_ content: String, to peerID: String, recipientNickname: String, messageID: String) {
        Task { @MainActor in
            guard let noiseKey = Data(hexString: peerID),
                  let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                  let recipientNostrPubkey = fav.peerNostrPublicKey else { return }
            guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: messageID, recipientPeerID: peerID, senderPeerID: senderPeerID),
                  let event = try? NostrProtocol.createPrivateMessage(content: embedded, recipientPubkey: recipientNostrPubkey, senderIdentity: senderIdentity) else { return }
            NostrRelayManager.shared.sendEvent(event)
        }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String) {
        Task { @MainActor in
            guard let noiseKey = Data(hexString: peerID),
                  let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                  let recipientNostrPubkey = fav.peerNostrPublicKey else { return }
            guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
            guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .readReceipt, messageID: receipt.originalMessageID, recipientPeerID: peerID, senderPeerID: senderPeerID),
                  let event = try? NostrProtocol.createPrivateMessage(content: ack, recipientPubkey: recipientNostrPubkey, senderIdentity: senderIdentity) else { return }
            NostrRelayManager.shared.sendEvent(event)
        }
    }

    func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        Task { @MainActor in
            guard let noiseKey = Data(hexString: peerID),
                  let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                  let recipientNostrPubkey = fav.peerNostrPublicKey else { return }
            guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
            let content = isFavorite ? "[FAVORITED]:\(senderIdentity.npub)" : "[UNFAVORITED]:\(senderIdentity.npub)"
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: UUID().uuidString, recipientPeerID: peerID, senderPeerID: senderPeerID),
                  let event = try? NostrProtocol.createPrivateMessage(content: embedded, recipientPubkey: recipientNostrPubkey, senderIdentity: senderIdentity) else { return }
            NostrRelayManager.shared.sendEvent(event)
        }
    }

    func sendBroadcastAnnounce() { /* no-op for Nostr */ }
    func sendDeliveryAck(for messageID: String, to peerID: String) {
        Task { @MainActor in
            guard let noiseKey = Data(hexString: peerID),
                  let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                  let recipientNostrPubkey = fav.peerNostrPublicKey else { return }
            guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
            guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .delivered, messageID: messageID, recipientPeerID: peerID, senderPeerID: senderPeerID),
                  let event = try? NostrProtocol.createPrivateMessage(content: ack, recipientPubkey: recipientNostrPubkey, senderIdentity: senderIdentity) else { return }
            NostrRelayManager.shared.sendEvent(event)
        }
    }
}
