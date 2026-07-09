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
        /// Emits whether a relay that carries private messages is up
        /// (fail-closed behind Tor). A connected geohash/custom relay alone
        /// doesn't count: DM sends target the default relay set and would
        /// still queue.
        let relayConnectivity: @MainActor () -> AnyPublisher<Bool, Never>
        /// Paces outbound acks. Defaults to an isolated pacer so tests don't
        /// serialize behind each other; `live` passes the process-wide one.
        let ackPacer: AckPacer

        init(
            notificationCenter: NotificationCenter,
            loadFavorites: @escaping @MainActor () -> [Data: FavoritesPersistenceService.FavoriteRelationship],
            favoriteStatusForNoiseKey: @escaping @MainActor (Data) -> FavoritesPersistenceService.FavoriteRelationship?,
            favoriteStatusForPeerID: @escaping @MainActor (PeerID) -> FavoritesPersistenceService.FavoriteRelationship?,
            currentIdentity: @escaping @MainActor () throws -> NostrIdentity?,
            registerPendingGiftWrap: @escaping @MainActor (String) -> Void,
            sendEvent: @escaping @MainActor (NostrEvent) -> Void,
            scheduleAfter: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void,
            relayConnectivity: @escaping @MainActor () -> AnyPublisher<Bool, Never>,
            ackPacer: AckPacer? = nil
        ) {
            self.notificationCenter = notificationCenter
            self.loadFavorites = loadFavorites
            self.favoriteStatusForNoiseKey = favoriteStatusForNoiseKey
            self.favoriteStatusForPeerID = favoriteStatusForPeerID
            self.currentIdentity = currentIdentity
            self.registerPendingGiftWrap = registerPendingGiftWrap
            self.sendEvent = sendEvent
            self.relayConnectivity = relayConnectivity
            // Default pacer drives its throttle through the same injected
            // scheduler, so tests that step scheduleAfter manually keep
            // control of the ack cadence.
            self.ackPacer = ackPacer ?? AckPacer(scheduleAfter: scheduleAfter)
        }

        @MainActor
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
                },
                relayConnectivity: { NostrRelayManager.shared.$isDMRelayConnected.eraseToAnyPublisher() },
                ackPacer: NostrTransport.sharedAckPacer
            )
        }
    }

    // Provide BLE short peer ID for BitChat embedding
    var senderPeerID = PeerID(str: "")

    // Throttle outbound acks — READ receipts and DELIVERED acks, direct and
    // geohash — to avoid relay rate limits. Reconnect redelivery produces a
    // burst of acks at once: 8 DELIVERED in under a second tripped damus's
    // "noting too much" during July 2026 device testing.
    private enum QueuedAck {
        case readDirect(ReadReceipt, PeerID)
        case deliveredDirect(messageID: String, peerID: PeerID)
        case deliveredGeohash(messageID: String, recipientHex: String, identity: NostrIdentity)
        case readGeohash(messageID: String, recipientHex: String, identity: NostrIdentity)
    }

    /// Ack pacing shared across transport instances. Geohash acks are sent
    /// through short-lived transports created per ack
    /// (`makeGeohashNostrTransport()`), so a per-instance queue would only
    /// ever hold one item and never pace a burst (flagged by Codex on
    /// #1398). Production wires `sharedAckPacer` via `Dependencies.live`;
    /// tests get an isolated instance per `Dependencies` by default.
    /// @unchecked Sendable: all mutable state (`pending`, `isSending`) is
    /// confined to the serial `queue`; the class is only touched via
    /// `enqueue` and the scheduler callback, both of which hop onto it.
    final class AckPacer: @unchecked Sendable {
        typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

        private let queue = DispatchQueue(label: "chat.bitchat.nostr-ack-pacer")
        private var pending: [() -> Void] = []
        private var isSending = false
        private let interval: TimeInterval = TransportConfig.nostrReadAckInterval
        private let scheduleAfter: Scheduler

        init(scheduleAfter: @escaping Scheduler = { delay, action in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: action)
        }) {
            self.scheduleAfter = scheduleAfter
        }

        func enqueue(_ send: @escaping () -> Void) {
            queue.async {
                self.pending.append(send)
                self.processNext()
            }
        }

        /// Must be called on `queue`.
        private func processNext() {
            guard !isSending, !pending.isEmpty else { return }
            isSending = true
            let send = pending.removeFirst()
            send()
            scheduleAfter(interval) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.isSending = false
                    self.processNext()
                }
            }
        }
    }
    static let sharedAckPacer = AckPacer()
    private let dependencies: Dependencies
    private var favoriteStatusObserver: NSObjectProtocol?

    // Reachability Cache (thread-safe)
    private var reachablePeers: Set<PeerID> = []
    // Mirror of the relay manager's connection state, cached here because
    // canDeliverPromptly is called synchronously off the main actor.
    private var relaysConnected = false
    private var relayConnectivityCancellable: AnyCancellable?
    private let queue = DispatchQueue(label: "nostr.transport.state", attributes: .concurrent)

    @MainActor
    init(
        keychain _: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        dependencies: Dependencies? = nil
    ) {
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

        relayConnectivityCancellable = self.dependencies.relayConnectivity()
            .sink { [weak self] connected in
                guard let self else { return }
                self.queue.async(flags: .barrier) { self.relaysConnected = connected }
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
    weak var eventDelegate: TransportEventDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }

    var myPeerID: PeerID { senderPeerID }
    var myNickname: String { "" }
    func setNickname(_ nickname: String) { /* not used for Nostr */ }

    func startServices() { /* no-op */ }
    func stopServices() { /* no-op */ }
    func emergencyDisconnectAll() { /* no-op */ }

    func isPeerConnected(_ peerID: PeerID) -> Bool { false }
    
    func isPeerReachable(_ peerID: PeerID) -> Bool {
        // Callers address peers by either the short 16-hex ID or the full
        // 64-hex noise key (offline favorites), so compare in short form.
        let short = peerID.toShort()
        return queue.sync {
            if reachablePeers.contains(peerID) { return true }
            return reachablePeers.contains(where: { $0.toShort() == short })
        }
    }

    func canDeliverPromptly(to peerID: PeerID) -> Bool {
        // A known npub makes a peer "reachable", but with no relay
        // connection a send only joins the local queue. Answering honestly
        // here lets the router hand a sealed copy to a courier in parallel
        // instead of waiting for internet that may never come.
        isPeerReachable(peerID) && queue.sync { relaysConnected }
    }

    func canDeliverSecurely(to peerID: PeerID) -> Bool {
        // Nostr has no link bindings to forge; a known recipient key plus a
        // connected relay is the strongest delivery signal it has. The router
        // already retains + couriers for Nostr sends, so keep that behavior.
        canDeliverPromptly(to: peerID)
    }

    func peerNickname(peerID: PeerID) -> String? { nil }
    func getPeerNicknames() -> [PeerID: String] { [:] }

    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) { /* no-op */ }

    // Nostr does not use Noise sessions here; the inert Transport defaults
    // for the noise* identity hooks apply.

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
        enqueueAck(.readDirect(receipt, peerID))
    }

    /// Enqueue an ack for paced sending. Captures self strongly on purpose:
    /// geohash acks ride throwaway transport instances that must stay alive
    /// until their ack leaves the queue.
    private func enqueueAck(_ ack: QueuedAck) {
        dependencies.ackPacer.enqueue { self.sendAckItem(ack) }
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
        enqueueAck(.deliveredDirect(messageID: messageID, peerID: peerID))
    }
}

// MARK: - Geohash Helpers

extension NostrTransport {

    // MARK: Geohash ACK helpers
    func sendDeliveryAckGeohash(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        enqueueAck(.deliveredGeohash(messageID: messageID, recipientHex: recipientHex, identity: identity))
    }

    func sendReadReceiptGeohash(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        enqueueAck(.readGeohash(messageID: messageID, recipientHex: recipientHex, identity: identity))
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


    /// Sends a single ack item (invoked by the pacer, one per interval)
    private func sendAckItem(_ item: QueuedAck) {
        Task { @MainActor in
            switch item {
            case .readDirect(let receipt, let peerID):
                guard let recipientNpub = resolveRecipientNpub(for: peerID),
                      let recipientHex = npubToHex(recipientNpub),
                      let senderIdentity = try? dependencies.currentIdentity() else { return }
                SecureLogger.debug("NostrTransport: preparing READ ack id=\(receipt.originalMessageID.prefix(8))…", category: .session)
                guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .readReceipt, messageID: receipt.originalMessageID, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
                    SecureLogger.error("NostrTransport: failed to embed READ ack", category: .session)
                    return
                }
                sendWrappedMessage(content: ack, recipientHex: recipientHex, senderIdentity: senderIdentity)

            case .deliveredDirect(let messageID, let peerID):
                guard let recipientNpub = resolveRecipientNpub(for: peerID),
                      let recipientHex = npubToHex(recipientNpub),
                      let senderIdentity = try? dependencies.currentIdentity() else { return }
                SecureLogger.debug("NostrTransport: preparing DELIVERED ack id=\(messageID.prefix(8))…", category: .session)
                guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .delivered, messageID: messageID, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
                    SecureLogger.error("NostrTransport: failed to embed DELIVERED ack", category: .session)
                    return
                }
                sendWrappedMessage(content: ack, recipientHex: recipientHex, senderIdentity: senderIdentity)

            case .deliveredGeohash(let messageID, let recipientHex, let identity):
                SecureLogger.debug("GeoDM: send DELIVERED mid=\(messageID.prefix(8))…", category: .session)
                guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .delivered, messageID: messageID, senderPeerID: senderPeerID) else { return }
                sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: identity, registerPending: true)

            case .readGeohash(let messageID, let recipientHex, let identity):
                SecureLogger.debug("GeoDM: send READ mid=\(messageID.prefix(8))…", category: .session)
                guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: messageID, senderPeerID: senderPeerID) else { return }
                sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: identity, registerPending: true)
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
