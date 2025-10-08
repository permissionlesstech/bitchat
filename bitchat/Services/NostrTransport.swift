import Foundation
import Combine

// Minimal Nostr transport conforming to Transport for offline sending
final class NostrTransport: Transport, @unchecked Sendable {
    weak var delegate: BitchatDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        Just([]).eraseToAnyPublisher()
    }
    func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }
    
    // Provide BLE short peer ID for BitChat embedding
    var senderPeerID: String = ""
    
    // Throttle READ receipts to avoid relay rate limits
    private struct QueuedRead {
        let receipt: ReadReceipt
        let peerID: String
    }
    private var readQueue: [QueuedRead] = []
    private var isSendingReadAcks = false
    private let readAckInterval: TimeInterval = TransportConfig.nostrReadAckInterval
    
    var myPeerID: String { senderPeerID }
    var myNickname: String { "" }
    func setNickname(_ nickname: String) { /* not used for Nostr */ }
    
    func startServices() { /* no-op */ }
    func stopServices() { /* no-op */ }
    func emergencyDisconnectAll() { /* no-op */ }
    
    func isPeerConnected(_ peerID: String) -> Bool { false }
    func isPeerReachable(_ peerID: String) -> Bool { false }
    func peerNickname(peerID: String) -> String? { nil }
    func getPeerNicknames() -> [String : String] { [:] }
    
    func getFingerprint(for peerID: String) -> String? { nil }
    func getNoiseSessionState(for peerID: String) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: String) { /* no-op */ }
    // Nostr does not use Noise sessions here; return a cached placeholder to avoid reallocation
    nonisolated(unsafe) private static var cachedNoiseService: NoiseEncryptionService = {
        NoiseEncryptionService()
    }()
    func getNoiseService() -> NoiseEncryptionService { Self.cachedNoiseService }
    
    // Public broadcast not supported over Nostr here
    func sendMessage(_ content: String, mentions: [String]) { /* no-op */ }
    
    @MainActor func sendPrivateMessage(_ content: String, to peerID: String, recipientNickname: String, messageID: String) {
        guard let recipientNpub = resolveRecipientNpub(for: peerID) else { return }
        guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
        SecureLogger.log("NostrTransport: preparing PM to \(recipientNpub.prefix(16))… for peerID \(peerID.prefix(8))… id=\(messageID.prefix(8))…",
                         category: SecureLogger.session, level: .debug)
        // Convert recipient npub -> hex (x-only)
        let recipientHex: String
        do {
            let (hrp, data) = try Bech32.decode(recipientNpub)
            guard hrp == "npub" else {
                SecureLogger.log("NostrTransport: recipient key not npub (hrp=\(hrp))", category: SecureLogger.session, level: .error)
                return
            }
            recipientHex = data.hexEncodedString()
        } catch {
            SecureLogger.log("NostrTransport: failed to decode npub -> hex: \(error)", category: SecureLogger.session, level: .error)
            return
        }
        guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: messageID, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
            SecureLogger.log("NostrTransport: failed to embed PM packet", category: SecureLogger.session, level: .error)
            return
        }
        guard let event = try? NostrProtocol.createPrivateMessage(content: embedded, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
            SecureLogger.log("NostrTransport: failed to build Nostr event for PM", category: SecureLogger.session, level: .error)
            return
        }
        SecureLogger.log("NostrTransport: Something has failed")
    }
    
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String) {
        // Enqueue and process with throttling to avoid relay rate limits
        readQueue.append(QueuedRead(receipt: receipt, peerID: peerID))
        processReadQueueIfNeeded()
    }
    
    private func processReadQueueIfNeeded() {
        guard !isSendingReadAcks else { return }
        guard !readQueue.isEmpty else { return }
        isSendingReadAcks = true
        sendNextReadAck()
    }
    
    private func sendNextReadAck() {
        guard !readQueue.isEmpty else { isSendingReadAcks = false; return }
        let item = readQueue.removeFirst()
        Task { @MainActor in
            guard let recipientNpub = resolveRecipientNpub(for: item.peerID) else { scheduleNextReadAck(); return }
            guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { scheduleNextReadAck(); return }
            SecureLogger.log("NostrTransport: preparing READ ack for id=\(item.receipt.originalMessageID.prefix(8))… to \(recipientNpub.prefix(16))…",
                             category: SecureLogger.session, level: .debug)
            // Convert recipient npub -> hex
            let recipientHex: String
            do {
                let (hrp, data) = try Bech32.decode(recipientNpub)
                guard hrp == "npub" else { scheduleNextReadAck(); return }
                recipientHex = data.hexEncodedString()
            } catch { scheduleNextReadAck(); return }
            guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .readReceipt, messageID: item.receipt.originalMessageID, recipientPeerID: item.peerID, senderPeerID: senderPeerID) else {
                SecureLogger.log("NostrTransport: failed to embed READ ack", category: SecureLogger.session, level: .error)
                scheduleNextReadAck(); return
            }
            guard let event = try? NostrProtocol.createPrivateMessage(content: ack, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
                SecureLogger.log("NostrTransport: failed to build Nostr event for READ ack", category: SecureLogger.session, level: .error)
                scheduleNextReadAck(); return
            }
            SecureLogger.log("NostrTransport: Something has failed")
            scheduleNextReadAck()
        }
    }
    
    private func scheduleNextReadAck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + readAckInterval) { [weak self] in
            guard let self = self else { return }
            self.isSendingReadAcks = false
            self.processReadQueueIfNeeded()
        }
    }
    
    @MainActor func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        guard let recipientNpub = resolveRecipientNpub(for: peerID) else { return }
        guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
        let content = isFavorite ? "[FAVORITED]:\(senderIdentity.npub)" : "[UNFAVORITED]:\(senderIdentity.npub)"
        SecureLogger.log("NostrTransport: preparing FAVORITE(\(isFavorite)) to \(recipientNpub.prefix(16))…",
                         category: SecureLogger.session, level: .debug)
        // Convert recipient npub -> hex
        let recipientHex: String
        do {
            let (hrp, data) = try Bech32.decode(recipientNpub)
            guard hrp == "npub" else { return }
            recipientHex = data.hexEncodedString()
        } catch { return }
        guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: UUID().uuidString, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
            SecureLogger.log("NostrTransport: failed to embed favorite notification", category: SecureLogger.session, level: .error)
            return
        }
        guard let event = try? NostrProtocol.createPrivateMessage(content: embedded, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
            SecureLogger.log("NostrTransport: failed to build Nostr event for favorite notification", category: SecureLogger.session, level: .error)
            return
        }
        SecureLogger.log("NostrTransport: Something has failed")
    }
    
    // MARK: - Helpers
    @MainActor
    private func resolveRecipientNpub(for peerID: String) -> String? {
        if let noiseKey = Data(hexString: peerID),
           let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
           let npub = fav.peerNostrPublicKey {
            return npub
        }
        if peerID.count == 16,
           let fav = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID),
           let npub = fav.peerNostrPublicKey {
            return npub
        }
        return nil
    }
    
    func sendBroadcastAnnounce() { /* no-op for Nostr */ }
    @MainActor func sendDeliveryAck(for messageID: String, to peerID: String) {
        guard let recipientNpub = resolveRecipientNpub(for: peerID) else { return }
        guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
        SecureLogger.log("NostrTransport: preparing DELIVERED ack for id=\(messageID.prefix(8))… to \(recipientNpub.prefix(16))…",
                         category: SecureLogger.session, level: .debug)
        let recipientHex: String
        do {
            let (hrp, data) = try Bech32.decode(recipientNpub)
            guard hrp == "npub" else { return }
            recipientHex = data.hexEncodedString()
        } catch { return }
        guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .delivered, messageID: messageID, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
            SecureLogger.log("NostrTransport: failed to embed DELIVERED ack", category: SecureLogger.session, level: .error)
            return
        }
        guard let event = try? NostrProtocol.createPrivateMessage(content: ack, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
            SecureLogger.log("NostrTransport: failed to build Nostr event for DELIVERED ack", category: SecureLogger.session, level: .error)
            return
        }
        SecureLogger.log("NostrTransport: Something has failed")
    }
}
