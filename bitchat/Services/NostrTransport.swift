import BitLogger
import BitFoundation
import Foundation
import Combine

// Minimal Nostr transport conforming to Transport for offline sending
final class NostrTransport: Transport, @unchecked Sendable {
    struct Dependencies {
        let notificationCenter: NotificationCenter
        let loadFavorites: @MainActor () -> [Data: FavoritesPersistenceService.FavoriteRelationship]
        let favoriteStatusForNoiseKey: @MainActor (Data) -> FavoritesPersistenceService.FavoriteRelationship?
        let favoriteStatusForPeerID: @MainActor (PeerID) -> FavoritesPersistenceService.FavoriteRelationship?
        let currentIdentity: @MainActor () throws -> NostrIdentity?
        let registerPendingGiftWrap: @MainActor (String) -> Void
        let sendEvent: @MainActor (NostrEvent) -> Void
        let scheduleAfter: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

        static func live(idBridge: NostrIdentityBridge) -> Dependencies {
            Dependencies(
                notificationCenter: .default,
                loadFavorites: { FavoritesPersistenceService.shared.favorites },
                favoriteStatusForNoiseKey: { FavoritesPersistenceService.shared.getFavoriteStatus(for: $0) },
                favoriteStatusForPeerID: { FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: $0) },
                currentIdentity: { try idBridge.getCurrentNostrIdentity() },
                registerPendingGiftWrap: { NostrRelayManager.registerPendingGiftWrap(id: $0) },
                sendEvent: { NostrRelayManager.shared.sendEvent($0) },
                scheduleAfter: { delay, action in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
                }
            )
        }
    }

    // Provide BLE short peer ID for BitChat embedding
    var senderPeerID = PeerID(str: "")

    // Throttle READ receipts to avoid relay rate limits
    private struct QueuedRead {
        let receipt: ReadReceipt
        let peerID: PeerID
    }
    private var readQueue: [QueuedRead] = []
    private var isSendingReadAcks = false
    private let readAckInterval: TimeInterval = TransportConfig.nostrReadAckInterval
    private let keychain: KeychainManagerProtocol
    private let idBridge: NostrIdentityBridge
    private let dependencies: Dependencies
    private var favoriteStatusObserver: NSObjectProtocol?

    // Reachability Cache (thread-safe)
    private var reachablePeers: Set<PeerID> = []
    private let queue = DispatchQueue(label: "nostr.transport.state", attributes: .concurrent)

    @MainActor
    init(
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        dependencies: Dependencies? = nil
    ) {
        self.keychain = keychain
        self.idBridge = idBridge
        self.dependencies = dependencies ?? .live(idBridge: idBridge)
        
        setupObservers()
        
        // Synchronously warm the cache to avoid startup race
        let favorites = self.dependencies.loadFavorites()
        let reachable = favorites.values
            .filter { $0.peerNostrPublicKey != nil }
            .map { PeerID(publicKey: $0.peerNoisePublicKey) }
            
        queue.sync(flags: .barrier) {
            self.reachablePeers = Set(reachable)
        }
    }

    deinit {
        if let favoriteStatusObserver {
            dependencies.notificationCenter.removeObserver(favoriteStatusObserver)
        }
    }

    private func setupObservers() {
        favoriteStatusObserver = dependencies.notificationCenter.addObserver(
            forName: .favoriteStatusChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshReachablePeers()
        }
    }

    private func refreshReachablePeers() {
        Task { @MainActor in
            let favorites = dependencies.loadFavorites()
            let reachable = favorites.values
                .filter { $0.peerNostrPublicKey != nil }
                .map { PeerID(publicKey: $0.peerNoisePublicKey) }
            
            self.queue.async(flags: .barrier) { [weak self] in
                self?.reachablePeers = Set(reachable)
            }
        }
    }

    // MARK: - Transport Protocol Conformance

    weak var delegate: BitchatDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        Just([]).eraseToAnyPublisher()
    }
    func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }

    var myPeerID: PeerID { senderPeerID }
    var myNickname: String { "" }
    func setNickname(_ nickname: String) { /* not used for Nostr */ }

    func startServices() { /* no-op */ }
    func stopServices() { /* no-op */ }
    func emergencyDisconnectAll() { /* no-op */ }

    func isPeerConnected(_ peerID: PeerID) -> Bool { false }
    
    func isPeerReachable(_ peerID: PeerID) -> Bool {
        queue.sync {
            // Check if exact match
            if reachablePeers.contains(peerID) { return true }
            // Check for short ID match
            if peerID.isShort {
                return reachablePeers.contains(where: { $0.toShort() == peerID })
            }
            return false
        }
    }
    
    func peerNickname(peerID: PeerID) -> String? { nil }
    func getPeerNicknames() -> [PeerID : String] { [:] }

    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) { /* no-op */ }
    
    // Nostr does not use Noise sessions here; return a cached placeholder to avoid reallocation
    private static var cachedNoiseService: NoiseEncryptionService?
    func getNoiseService() -> NoiseEncryptionService {
        if let noiseService = Self.cachedNoiseService {
            return noiseService
        }
        let noiseService = NoiseEncryptionService(keychain: keychain)
        Self.cachedNoiseService = noiseService
        return noiseService
    }

    // Public broadcast not supported over Nostr here
    func sendMessage(_ content: String, mentions: [String]) { /* no-op */ }

    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        Task { @MainActor in
            guard let recipientNpub = resolveRecipientNpub(for: peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? dependencies.currentIdentity() else { return }
            SecureLogger.debug("NostrTransport: preparing PM to \(recipientNpub.prefix(16))… id=\(messageID.prefix(8))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: messageID, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
                SecureLogger.error("NostrTransport: failed to embed PM packet", category: .session)
                return
            }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: senderIdentity)
        }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        // Enqueue and process with throttling to avoid relay rate limits
        // Use barrier to synchronize access to readQueue
        queue.async(flags: .barrier) { [weak self] in
            self?.readQueue.append(QueuedRead(receipt: receipt, peerID: peerID))
            self?.processReadQueueIfNeeded()
        }
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        Task { @MainActor in
            guard let recipientNpub = resolveRecipientNpub(for: peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? dependencies.currentIdentity() else { return }
            let content = isFavorite ? "[FAVORITED]:\(senderIdentity.npub)" : "[UNFAVORITED]:\(senderIdentity.npub)"
            SecureLogger.debug("NostrTransport: preparing FAVORITE(\(isFavorite)) to \(recipientNpub.prefix(16))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: UUID().uuidString, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
                SecureLogger.error("NostrTransport: failed to embed favorite notification", category: .session)
                return
            }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: senderIdentity)
        }
    }

    func sendBroadcastAnnounce() { /* no-op for Nostr */ }
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {
        Task { @MainActor in
            guard let recipientNpub = resolveRecipientNpub(for: peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? dependencies.currentIdentity() else { return }
            SecureLogger.debug("NostrTransport: preparing DELIVERED ack id=\(messageID.prefix(8))…", category: .session)
            guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .delivered, messageID: messageID, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
                SecureLogger.error("NostrTransport: failed to embed DELIVERED ack", category: .session)
                return
            }
            sendWrappedMessage(content: ack, recipientHex: recipientHex, senderIdentity: senderIdentity)
        }
    }
}

// MARK: - Geohash Helpers

extension NostrTransport {

    // MARK: Geohash ACK helpers
    func sendDeliveryAckGeohash(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        Task { @MainActor in
            SecureLogger.debug("GeoDM: send DELIVERED mid=\(messageID.prefix(8))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .delivered, messageID: messageID, senderPeerID: senderPeerID) else { return }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: identity, registerPending: true)
        }
    }

    func sendReadReceiptGeohash(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        Task { @MainActor in
            SecureLogger.debug("GeoDM: send READ mid=\(messageID.prefix(8))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: messageID, senderPeerID: senderPeerID) else { return }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: identity, registerPending: true)
        }
    }

    // MARK: Geohash DMs (per-geohash identity)
    func sendPrivateMessageGeohash(content: String, toRecipientHex recipientHex: String, from identity: NostrIdentity, messageID: String) {
        Task { @MainActor in
            guard !recipientHex.isEmpty else { return }
            SecureLogger.debug("GeoDM: send PM mid=\(messageID.prefix(8))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostrNoRecipient(content: content, messageID: messageID, senderPeerID: senderPeerID) else {
                SecureLogger.error("NostrTransport: failed to embed geohash PM packet", category: .session)
                return
            }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: identity, registerPending: true)
        }
    }
}

// MARK: - Private Helpers

extension NostrTransport {
    /// Converts npub bech32 string to hex pubkey
    @MainActor
    private func npubToHex(_ npub: String) -> String? {
        do {
            let (hrp, data) = try Bech32.decode(npub)
            guard hrp == "npub" else { return nil }
            return data.hexEncodedString()
        } catch {
            SecureLogger.error("NostrTransport: failed to decode npub -> hex: \(error)", category: .session)
            return nil
        }
    }

    /// Creates and sends a gift-wrapped private message event
    @MainActor
    private func sendWrappedMessage(content: String, recipientHex: String, senderIdentity: NostrIdentity, registerPending: Bool = false) {
        guard let event = try? NostrProtocol.createPrivateMessage(content: content, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
            SecureLogger.error("NostrTransport: failed to build Nostr event", category: .session)
            return
        }
        if registerPending {
            dependencies.registerPendingGiftWrap(event.id)
        }
        dependencies.sendEvent(event)
    }

    /// Must be called within a barrier on `queue`
    private func processReadQueueIfNeeded() {
        guard !isSendingReadAcks else { return }
        guard !readQueue.isEmpty else { return }
        isSendingReadAcks = true
        let item = readQueue.removeFirst()
        sendReadAckItem(item)
    }

    /// Sends a single read ack item (called after extraction from queue within barrier)
    private func sendReadAckItem(_ item: QueuedRead) {
        Task { @MainActor in
            defer { scheduleNextReadAck() }
            guard let recipientNpub = resolveRecipientNpub(for: item.peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? dependencies.currentIdentity() else { return }
            SecureLogger.debug("NostrTransport: preparing READ ack id=\(item.receipt.originalMessageID.prefix(8))…", category: .session)
            guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .readReceipt, messageID: item.receipt.originalMessageID, recipientPeerID: item.peerID, senderPeerID: senderPeerID) else {
                SecureLogger.error("NostrTransport: failed to embed READ ack", category: .session)
                return
            }
            sendWrappedMessage(content: ack, recipientHex: recipientHex, senderIdentity: senderIdentity)
        }
    }

    private func scheduleNextReadAck() {
        dependencies.scheduleAfter(readAckInterval) { [weak self] in
            self?.queue.async(flags: .barrier) { [weak self] in
                self?.isSendingReadAcks = false
                self?.processReadQueueIfNeeded()
            }
        }
    }

    @MainActor
    private func resolveRecipientNpub(for peerID: PeerID) -> String? {
        if let noiseKey = Data(hexString: peerID.id),
           let fav = dependencies.favoriteStatusForNoiseKey(noiseKey),
           let npub = fav.peerNostrPublicKey {
            return npub
        }
        if peerID.id.count == 16,
           let fav = dependencies.favoriteStatusForPeerID(peerID),
           let npub = fav.peerNostrPublicKey {
            return npub
        }
        return nil
    }
}
