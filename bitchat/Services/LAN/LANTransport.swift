//
// LANTransport.swift
// bitchat
//
// Wi-Fi LAN transport: local-network discovery and a Noise-encrypted
// peer-to-peer link, alongside the existing BLE mesh and Nostr transports.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Foundation
import Network

/// Phone-to-phone transport over the local Wi-Fi network.
///
/// The transport is **inert by default**: with the feature flag off it opens
/// no listener, starts no browser and triggers no local-network permission
/// prompt. When the flag is on (and the local-network permission has been
/// granted) the transport advertises a Bonjour service, browses for peers,
/// opens a TCP link to every peer it finds and runs the existing Noise XX
/// handshake over that link.
///
/// Identity is shared with the other transports: the Noise static key comes
/// from the same keychain entry, so the peer ID (and therefore the
/// fingerprint shown in the UI) is identical to the BLE mesh peer ID.
final class LANTransport: Transport {
    // MARK: - Types

    /// One live link to a remote peer.
    private final class Link {
        let connection: LANConnection
        /// Peer ID, known after the identity exchange.
        var peerID: PeerID?
        /// `true` when we opened the connection (we send the first frame).
        let isOutbound: Bool
        /// Ed25519 key learned from the signed hello.
        var signingPublicKey: Data?
        /// Creation time, used to expire links that never complete a hello.
        let createdAt = Date()
        var sentHello = false
        var receivedHello = false
        var sentHandshake = false
        var isAuthenticated = false
        /// Set before an intentional close so the cancellation callback does
        /// not publish a second disconnect.
        var isClosed = false

        init(connection: LANConnection, isOutbound: Bool) {
            self.connection = connection
            self.isOutbound = isOutbound
        }
    }

    // MARK: - Configuration

    private let settings: LANTransportSettings
    private let noiseService: NoiseEncryptionService
    private let registry: LANPeerRegistry
    private let queue = DispatchQueue(label: "chat.bitchat.lan.transport")
    private let linkQueue = DispatchQueue(label: "chat.bitchat.lan.link")

    /// Local-network permission state observed by the transport.
    private(set) var permissionState: LANPermissionState = .unknown

    /// The transport's feature flag. When `false` the transport stays inert.
    var isEnabled: Bool { settings.isEnabled }

    /// The latest permission state, safe to read from the UI thread.
    var currentPermissionState: LANPermissionState {
        queue.sync { permissionState }
    }

    // MARK: - Delegates

    var delegate: BitchatDelegate?
    var eventDelegate: TransportEventDelegate?
    var peerEventsDelegate: TransportPeerEventsDelegate?

    // MARK: - Identity

    private var nickname: String
    private let localPeerID: PeerID
    private let localPeerIDData: Data

    // MARK: - Networking state

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [ObjectIdentifier: Link] = [:]
    private var isRunning = false
    /// A panic wipe rotated the keychain identity under this instance; the
    /// in-memory Noise service is stale and must not be started again until
    /// the app creates a fresh transport on next launch.
    private var identityInvalidated = false
    private var maintenanceTimer: DispatchSourceTimer?
    private var peerAuthenticatedHandler: ((PeerID, String) -> Void)?
    private var handshakeRequiredHandler: ((PeerID) -> Void)?

    // MARK: - Init

    init(
        keychain: KeychainManagerProtocol,
        settings: LANTransportSettings = LANTransportSettings(),
        nickname: String = "anon",
        permissionState: LANPermissionState = .unknown
    ) {
        self.settings = settings
        self.nickname = nickname
        self.permissionState = permissionState
        // A dedicated Noise service instance: it loads the same identity key
        // from the keychain (so the peer ID and fingerprint are shared with
        // the BLE mesh) but keeps its own session table, so a session is
        // never silently reused across two physical links.
        self.noiseService = NoiseEncryptionService(keychain: keychain)
        self.registry = LANPeerRegistry()
        let staticKey = noiseService.getStaticPublicKeyData()
        self.localPeerID = PeerID(publicKey: staticKey)
        self.localPeerIDData = Data(hexString: localPeerID.id) ?? Data()
    }

    // MARK: - Transport: identity

    var myPeerID: PeerID { localPeerID }
    var myNickname: String { queue.sync { nickname } }

    func setNickname(_ nickname: String) {
        queue.async { [weak self] in
            self?.nickname = nickname
        }
    }

    // MARK: - Transport: lifecycle

    func startServices() {
        queue.async { [weak self] in
            self?.startIfAllowed()
        }
    }

    func stopServices() {
        queue.async { [weak self] in
            self?.stop()
        }
    }

    /// Apply the settings toggle immediately instead of waiting for the next
    /// launch. Disabling tears every link down; enabling starts discovery and
    /// triggers the Local Network prompt on first use.
    func setEnabled(_ enabled: Bool) {
        if enabled, queue.sync(execute: { identityInvalidated }) {
            settings.isEnabled = false
            SecureLogger.warning(
                "LAN transport needs an app restart after a panic wipe; refusing to start",
                category: .security
            )
            return
        }
        settings.isEnabled = enabled
        queue.async { [weak self] in
            guard let self else { return }
            if enabled {
                self.startIfAllowed()
            } else {
                self.stop()
            }
        }
    }

    /// The keychain identity was rotated by a panic wipe. Tear down every
    /// link and quarantine this instance; only a fresh app launch may rebuild
    /// the Noise service under the new identity.
    func invalidateAfterPanic() {
        settings.isEnabled = false
        // Synchronous: the keychain wipe that follows must not race a live
        // LAN link that still holds the old identity.
        queue.sync { [weak self] in
            guard let self else { return }
            self.identityInvalidated = true
            self.stop()
        }
    }

    /// Clear a denied/unavailable in-memory state and try again. The system
    /// permission itself can only be changed in Settings; this lets a user
    /// retry after returning from there, or after turning Wi-Fi back on.
    func retryPermission() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stop()
            self.updatePermissionState(.unknown)
            self.startIfAllowed()
        }
    }

    func emergencyDisconnectAll() {
        queue.async { [weak self] in
            self?.teardownLinks()
        }
    }

    /// Start the transport when the feature flag allows it.
    ///
    /// Nothing happens when the flag is off: no listener, no browser, no
    /// permission prompt.
    private func startIfAllowed() {
        guard settings.isEnabled, !identityInvalidated else {
            SecureLogger.debug("LAN transport disabled or awaiting restart; staying inert", category: .session)
            return
        }
        guard !isRunning else { return }
        guard permissionState.canAttemptStart else {
            // A known denial keeps the transport inert. `unknown` is allowed:
            // the first Bonjour browse/advertise is what triggers the system
            // permission prompt.
            SecureLogger.debug(
                "LAN transport not starting (permission: \(permissionState.rawValue))",
                category: .session
            )
            return
        }
        isRunning = true
        startListener()
        startBrowser()
        startMaintenanceTimer()
    }

    private func stop() {
        isRunning = false
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        teardownLinks()
        registry.removeAll()
        publishPeerSnapshots()
    }

    // MARK: - Transport: peers

    func currentPeerSnapshots() -> [TransportPeerSnapshot] {
        queue.sync { registry.snapshots(now: Date()) }
    }

    func isPeerConnected(_ peerID: PeerID) -> Bool {
        queue.sync { registry.state(of: peerID)?.isAuthenticated ?? false }
    }

    func isPeerReachable(_ peerID: PeerID) -> Bool {
        isPeerConnected(peerID)
    }

    func canDeliverPromptly(to peerID: PeerID) -> Bool {
        isPeerConnected(peerID)
    }

    func canDeliverSecurely(to peerID: PeerID) -> Bool {
        queue.sync { noiseService.hasEstablishedSession(with: peerID) }
    }

    func peerNickname(peerID: PeerID) -> String? {
        queue.sync { nicknameForPeer(peerID) }
    }

    func getPeerNicknames() -> [PeerID: String] {
        queue.sync {
            var result: [PeerID: String] = [:]
            for (peerID, peer) in registry.peers where !peer.nickname.isEmpty {
                result[peerID] = peer.nickname
            }
            return result
        }
    }

    func getFingerprint(for peerID: PeerID) -> String? {
        noiseService.getPeerFingerprint(peerID)
    }

    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState {
        queue.sync {
            if noiseService.hasEstablishedSession(with: peerID) {
                return .established
            }
            if registry.state(of: peerID) == .handshaking {
                return .handshaking
            }
            return .none
        }
    }

    func triggerHandshake(with peerID: PeerID) {
        queue.async { [weak self] in
            self?.startHandshake(with: peerID)
        }
    }

    // MARK: - Transport: Noise identity

    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data? {
        noiseService.getPeerPublicKeyData(peerID)
    }

    func noiseIdentityFingerprint() -> String {
        noiseService.getIdentityFingerprint()
    }

    func noiseStaticPublicKeyData() -> Data {
        noiseService.getStaticPublicKeyData()
    }

    func noiseSigningPublicKeyData() -> Data {
        noiseService.getSigningPublicKeyData()
    }

    func noiseSignData(_ data: Data) -> Data? {
        noiseService.signData(data)
    }

    func noiseVerifySignature(_ signature: Data, for data: Data, publicKey: Data) -> Bool {
        noiseService.verifySignature(signature, for: data, publicKey: publicKey)
    }

    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    ) {
        queue.async { [weak self] in
            self?.peerAuthenticatedHandler = onPeerAuthenticated
            self?.handshakeRequiredHandler = onHandshakeRequired
        }
    }

    // MARK: - Transport: messaging

    func sendMessage(_ content: String, mentions: [String]) {
        sendMessage(content, mentions: mentions, messageID: UUID().uuidString, timestamp: Date())
    }

    func sendMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        queue.async { [weak self] in
            guard let self else { return }
            let packet = BitchatPacket(
                type: MessageType.message.rawValue,
                senderID: self.localPeerIDData,
                recipientID: nil,
                timestamp: UInt64(timestamp.timeIntervalSince1970 * 1000),
                payload: Data(content.utf8),
                signature: nil,
                ttl: 1
            )
            guard let signed = self.noiseService.signPacket(packet) else { return }
            self.broadcast(signed)
        }
    }

    func sendPrivateMessage(
        _ content: String,
        to peerID: PeerID,
        recipientNickname: String,
        messageID: String
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let payload = BLENoisePayloadFactory.privateMessage(
                content: content,
                messageID: messageID
            ) else {
                SecureLogger.error("LAN transport: failed to encode private message", category: .session)
                return
            }
            if self.sendNoisePayload(payload, to: peerID) {
                self.deliverEvent(.messageDeliveryStatusUpdated(messageID: messageID, status: .sent))
            }
        }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        queue.async { [weak self] in
            guard let self else { return }
            let payload = BLENoisePayloadFactory.readReceipt(originalMessageID: receipt.originalMessageID)
            self.sendNoisePayload(payload, to: peerID)
        }
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        let content = isFavorite ? "[FAVORITED]" : "[UNFAVORITED]"
        sendPrivateMessage(content, to: peerID, recipientNickname: "", messageID: UUID().uuidString)
    }

    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {
        queue.async { [weak self] in
            guard let self else { return }
            let payload = BLENoisePayloadFactory.delivered(messageID: messageID)
            self.sendNoisePayload(payload, to: peerID)
        }
    }

    func sendBroadcastAnnounce() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let packet = self.makeHelloPacket() else { return }
            self.broadcast(packet)
        }
    }

    // MARK: - Discovery

    private func startListener() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(
                name: LANTransportConfig.serviceName(for: localPeerID),
                type: LANTransportConfig.serviceType,
                domain: nil,
                txtRecord: nil
            )
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    self.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.queue.async {
                    self.accept(connection: connection)
                }
            }
            listener.start(queue: linkQueue)
            self.listener = listener
        } catch {
            SecureLogger.error("LAN transport: failed to start listener: \(error)", category: .session)
            updatePermissionState(.unavailable)
        }
    }

    private func startBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: LANTransportConfig.serviceType,
            domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                self.handleBrowserState(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.queue.async {
                self.handleBrowseResults(results)
            }
        }
        browser.start(queue: linkQueue)
        self.browser = browser
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            updatePermissionState(.granted)
        case .failed(let error):
            SecureLogger.error("LAN transport: listener failed: \(error)", category: .session)
            updatePermissionState(LANPermissionStateResolver.resolve(failure: Self.failureKind(for: error)))
        case .cancelled, .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            updatePermissionState(.granted)
        case .failed(let error):
            SecureLogger.error("LAN transport: browser failed: \(error)", category: .session)
            updatePermissionState(LANPermissionStateResolver.resolve(failure: Self.failureKind(for: error)))
        case .cancelled, .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            guard let peerID = LANTransportConfig.peerID(fromServiceName: name) else { continue }
            guard peerID != localPeerID else { continue }
            guard !hasLink(to: peerID) else { continue }
            connect(to: result.endpoint, peerID: peerID)
        }
    }

    private func hasLink(to peerID: PeerID) -> Bool {
        links.values.contains { $0.peerID == peerID }
    }

    // MARK: - Links

    private func connect(to endpoint: NWEndpoint, peerID: PeerID) {
        guard links.count < LANTransportConfig.maxConcurrentConnections else {
            SecureLogger.warning("LAN transport: connection cap reached; not dialing", category: .session)
            return
        }
        let connection = LANConnection(endpoint: endpoint, queue: linkQueue)
        let link = Link(connection: connection, isOutbound: true)
        link.peerID = peerID
        register(link: link)
        registry.discover(
            peerID: peerID,
            endpointDescription: String(describing: endpoint),
            now: Date()
        )
        connection.onFrame = { [weak self] payload in
            self?.queue.async {
                self?.handleFrame(payload, from: link)
            }
        }
        connection.onStateChange = { [weak self] state in
            self?.queue.async {
                self?.handleLinkState(state, link: link)
            }
        }
        connection.start()
    }

    private func accept(connection: NWConnection) {
        guard links.count < LANTransportConfig.maxConcurrentConnections else {
            SecureLogger.warning("LAN transport: connection cap reached; rejecting", category: .session)
            connection.cancel()
            return
        }
        let lanConnection = LANConnection(connection: connection, queue: linkQueue)
        let link = Link(connection: lanConnection, isOutbound: false)
        register(link: link)
        lanConnection.onFrame = { [weak self] payload in
            self?.queue.async {
                self?.handleFrame(payload, from: link)
            }
        }
        lanConnection.onStateChange = { [weak self] state in
            self?.queue.async {
                self?.handleLinkState(state, link: link)
            }
        }
        lanConnection.start()
    }

    private func register(link: Link) {
        links[ObjectIdentifier(link.connection)] = link
    }

    private func teardownLinks() {
        for link in links.values {
            link.isClosed = true
            link.connection.cancel()
        }
        links.removeAll()
    }

    private func handleLinkState(_ state: LANConnection.State, link: Link) {
        guard !link.isClosed else { return }
        switch state {
        case .connecting:
            break
        case .ready:
            if link.isOutbound, !link.sentHello {
                sendHello(on: link)
            }
        case .failed, .cancelled:
            if let peerID = link.peerID {
                registry.disconnect(peerID: peerID, now: Date())
                deliverEvent(.peerDisconnected(peerID))
            }
            links.removeValue(forKey: ObjectIdentifier(link.connection))
            publishPeerSnapshots()
        }
    }

    // MARK: - Frames

    /// A packet received on a link must claim the identity that link was
    /// authenticated as, and must be addressed to us when it carries a
    /// recipient. Without this check a peer could inject a packet under a
    /// different sender ID on its own TCP link.
    private func packetMatchesLink(_ packet: BitchatPacket, peerID: PeerID) -> Bool {
        guard LANInboundPolicy.senderMatches(packet, peerID: peerID) else {
            SecureLogger.warning("LAN transport: sender ID does not match the link", category: .security)
            return false
        }
        guard LANInboundPolicy.recipientMatches(packet, localPeerID: localPeerID) else {
            SecureLogger.warning("LAN transport: packet addressed to another peer dropped", category: .security)
            return false
        }
        return true
    }

    private func handleFrame(_ payload: Data, from link: Link) {
        guard let packet = BitchatPacket.from(payload) else {
            SecureLogger.warning("LAN transport: malformed packet dropped", category: .session)
            return
        }
        switch packet.type {
        case MessageType.announce.rawValue:
            handleHello(packet, link: link)
        case MessageType.noiseHandshake.rawValue:
            handleHandshake(packet, link: link)
        case MessageType.noiseEncrypted.rawValue:
            handleEncrypted(packet, link: link)
        case MessageType.message.rawValue:
            handlePublicMessage(packet, link: link)
        default:
            break
        }
    }

    /// The identity exchange: an announce packet carrying the peer's Noise
    /// and signing keys, signed with the peer's Ed25519 key.
    private func handleHello(_ packet: BitchatPacket, link: Link) {
        // A link gets exactly one identity. A second hello is an attempt to
        // re-bind an established connection to somebody else.
        guard !link.receivedHello else {
            SecureLogger.warning("LAN transport: duplicate hello dropped", category: .security)
            dropLink(link, notify: false)
            return
        }
        let senderID = PeerID(hexData: packet.senderID)
        guard let announcement = AnnouncementPacket.decode(from: packet.payload) else {
            SecureLogger.warning("LAN transport: malformed hello dropped", category: .session)
            return
        }
        // The advertised peer ID must be derived from the advertised Noise
        // key, otherwise a peer could claim somebody else's identity.
        guard PeerID(publicKey: announcement.noisePublicKey) == senderID else {
            SecureLogger.warning("LAN transport: hello identity mismatch dropped", category: .security)
            return
        }
        // The Bonjour name is only a routing hint, but a mismatch means the
        // service is lying (or stale); do not let it create a second identity.
        if let advertised = link.peerID, advertised != senderID {
            SecureLogger.warning("LAN transport: hello does not match advertised peer; dropping", category: .security)
            // Do not evict a legitimate live peer that happens to share the
            // advertised ID; only clean up this link's discovery hint.
            if !links.values.contains(where: { $0 !== link && $0.peerID == advertised }) {
                registry.remove(peerID: advertised)
            }
            dropLink(link, notify: false)
            return
        }
        // The hello is signed with the peer's Ed25519 key; an unsigned or
        // forged hello never reaches the Noise handshake.
        guard noiseService.verifyPacketSignature(packet, publicKey: announcement.signingPublicKey) else {
            SecureLogger.warning("LAN transport: hello signature invalid", category: .security)
            return
        }

        // Crossed outbound connections are common when both sides browse at
        // once. Keep exactly one link: the outbound link of the smaller peer
        // ID, otherwise the older link. Both sides compute the same winner.
        if let existing = links.values.first(where: { $0 !== link && $0.peerID == senderID }) {
            if shouldKeep(existing: existing, incoming: link, peerID: senderID) {
                dropLink(link, notify: false)
                return
            }
            dropLink(existing, notify: existing.isAuthenticated)
        }

        link.receivedHello = true
        link.peerID = senderID
        link.signingPublicKey = announcement.signingPublicKey
        registry.discover(
            peerID: senderID,
            nickname: announcement.nickname,
            noisePublicKey: announcement.noisePublicKey,
            signingPublicKey: announcement.signingPublicKey,
            now: Date()
        )
        registry.beginHandshake(peerID: senderID, now: Date())

        // Answer with our own hello (the responder never speaks first).
        if !link.sentHello {
            sendHello(on: link)
        }
        // The side that opened the connection drives the Noise handshake, so
        // the two peers never cross their initiations.
        if link.isOutbound, !link.sentHandshake {
            startHandshake(with: senderID)
        }
        publishPeerSnapshots()
    }

    private func shouldKeep(existing: Link, incoming: Link, peerID: PeerID) -> Bool {
        LANLinkArbitration.shouldKeep(
            existingIsOutbound: existing.isOutbound,
            incomingIsOutbound: incoming.isOutbound,
            existingCreatedAt: existing.createdAt,
            incomingCreatedAt: incoming.createdAt,
            localPeerID: localPeerID,
            remotePeerID: peerID
        )
    }

    private func dropLink(_ link: Link, notify: Bool) {
        if notify, let peerID = link.peerID {
            registry.disconnect(peerID: peerID, now: Date())
            deliverEvent(.peerDisconnected(peerID))
        }
        link.isClosed = true
        link.connection.cancel()
        links.removeValue(forKey: ObjectIdentifier(link.connection))
        publishPeerSnapshots()
    }

    private func handleHandshake(_ packet: BitchatPacket, link: Link) {
        // The signed hello must arrive first. Without this guard a peer that
        // advertises somebody else's Bonjour name could start a Noise session
        // before proving the advertised identity.
        guard link.receivedHello,
              let peerID = link.peerID,
              packetMatchesLink(packet, peerID: peerID) else { return }
        registry.beginHandshake(peerID: peerID, now: Date())
        do {
            let result = try noiseService.processHandshakeMessageWithResult(
                from: peerID,
                message: packet.payload
            )
            if let response = result.response {
                sendHandshakeMessage(response, to: peerID, link: link)
            }
            if result.didEstablishAuthenticatedSession || noiseService.hasEstablishedSession(with: peerID) {
                finishAuthentication(peerID: peerID, link: link)
            }
        } catch {
            SecureLogger.error("LAN transport: handshake failed: \(error)", category: .security)
            registry.disconnect(peerID: peerID, now: Date())
            deliverEvent(.peerDisconnected(peerID))
            publishPeerSnapshots()
        }
    }

    private func handleEncrypted(_ packet: BitchatPacket, link: Link) {
        guard link.receivedHello,
              let peerID = link.peerID,
              link.isAuthenticated,
              packetMatchesLink(packet, peerID: peerID) else { return }
        registry.markTraffic(peerID: peerID, now: Date())
        do {
            let plaintext = try noiseService.decrypt(packet.payload, from: peerID)
            guard let payload = NoisePayload.decode(plaintext) else { return }
            deliverEvent(
                .noisePayloadReceived(
                    peerID: peerID,
                    type: payload.type,
                    payload: payload.data,
                    timestamp: Date()
                )
            )
        } catch {
            SecureLogger.error("LAN transport: decrypt failed: \(error)", category: .security)
        }
    }

    private func handlePublicMessage(_ packet: BitchatPacket, link: Link) {
        let senderID = PeerID(hexData: packet.senderID)
        guard link.isAuthenticated,
              let signingKey = link.signingPublicKey,
              link.peerID == senderID,
              packetMatchesLink(packet, peerID: senderID),
              noiseService.verifyPacketSignature(packet, publicKey: signingKey) else {
            SecureLogger.warning("LAN transport: unsigned or unauthenticated public message dropped", category: .security)
            return
        }
        guard senderID != localPeerID else { return }
        registry.markTraffic(peerID: senderID, now: Date())
        let content = String(data: packet.payload, encoding: .utf8) ?? ""
        deliverEvent(
            .publicMessageReceived(
                peerID: senderID,
                nickname: nicknameForPeer(senderID) ?? "",
                content: content,
                timestamp: Date(timeIntervalSince1970: Double(packet.timestamp) / 1000),
                messageID: nil
            )
        )
    }

    // MARK: - Sending

    private func makeHelloPacket() -> BitchatPacket? {
        let announcement = AnnouncementPacket(
            nickname: nickname,
            noisePublicKey: noiseService.getStaticPublicKeyData(),
            signingPublicKey: noiseService.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        guard let payload = announcement.encode() else { return nil }
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: localPeerIDData,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 1
        )
        return noiseService.signPacket(packet)
    }

    private func sendHello(on link: Link) {
        guard let packet = makeHelloPacket() else { return }
        link.sentHello = true
        link.connection.send(payload: packet.toBinaryData(padding: false) ?? Data())
    }

    private func sendHandshakeMessage(_ handshake: Data, to peerID: PeerID, link: Link) {
        let packet = BitchatPacket(
            type: MessageType.noiseHandshake.rawValue,
            senderID: localPeerIDData,
            recipientID: Data(hexString: peerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: handshake,
            signature: nil,
            ttl: 1
        )
        link.sentHandshake = true
        link.connection.send(payload: packet.toBinaryData(padding: false) ?? Data())
    }

    private func requestHandshake(_ peerID: PeerID) {
        let handler = handshakeRequiredHandler
        Task { @MainActor in
            handler?(peerID)
        }
    }

    private func startHandshake(with peerID: PeerID) {
        guard let link = links.values.first(where: { $0.peerID == peerID }) else {
            requestHandshake(peerID)
            return
        }
        guard !link.sentHandshake else { return }
        do {
            let initiation = try noiseService.initiateHandshake(with: peerID)
            sendHandshakeMessage(initiation, to: peerID, link: link)
        } catch {
            SecureLogger.error("LAN transport: could not start handshake: \(error)", category: .security)
        }
    }

    @discardableResult
    private func sendNoisePayload(_ payload: Data, to peerID: PeerID) -> Bool {
        guard noiseService.hasEstablishedSession(with: peerID) else {
            requestHandshake(peerID)
            startHandshake(with: peerID)
            return false
        }
        do {
            let encrypted = try noiseService.encrypt(payload, for: peerID)
            let packet = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: localPeerIDData,
                recipientID: Data(hexString: peerID.id),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: encrypted,
                signature: nil,
                ttl: 1
            )
            guard let link = links.values.first(where: { $0.peerID == peerID }),
                  link.connection.state == .ready,
                  let data = packet.toBinaryData(padding: false) else { return false }
            link.connection.send(payload: data)
            return true
        } catch {
            SecureLogger.error("LAN transport: encrypt failed: \(error)", category: .security)
            return false
        }
    }

    private func broadcast(_ packet: BitchatPacket) {
        let data = packet.toBinaryData(padding: false) ?? Data()
        for link in links.values {
            link.connection.send(payload: data)
        }
    }

    // MARK: - Authentication bookkeeping

    private func finishAuthentication(peerID: PeerID, link: Link) {
        // Bind the completed Noise session to the identity announced in the
        // signed hello. The handshake itself proves possession of the remote
        // static key; this check makes sure it is the key the peer claimed.
        guard let remoteKey = noiseService.getPeerPublicKeyData(peerID),
              let announcedKey = registry.peers[peerID]?.noisePublicKey,
              remoteKey == announcedKey,
              PeerID(publicKey: remoteKey) == peerID else {
            SecureLogger.error(
                "LAN transport: Noise session does not match the announced identity; dropping link",
                category: .security
            )
            dropLink(link, notify: false)
            return
        }
        let wasAuthenticated = link.isAuthenticated
        link.isAuthenticated = true
        registry.authenticate(
            peerID: peerID,
            nickname: nicknameForPeer(peerID),
            noisePublicKey: remoteKey,
            signingPublicKey: link.signingPublicKey,
            isVerified: true,
            now: Date()
        )
        publishPeerSnapshots()
        if !wasAuthenticated {
            deliverEvent(.peerConnected(peerID))
            let handler = peerAuthenticatedHandler
            let peerNickname = nicknameForPeer(peerID) ?? ""
            Task { @MainActor in
                handler?(peerID, peerNickname)
            }
        }
    }

    // MARK: - Maintenance

    private func startMaintenanceTimer() {
        maintenanceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + LANTransportConfig.keepaliveInterval,
            repeating: LANTransportConfig.keepaliveInterval
        )
        timer.setEventHandler { [weak self] in
            self?.runMaintenance()
        }
        timer.resume()
        maintenanceTimer = timer
    }

    private func runMaintenance() {
        let now = Date()
        let expired = registry.expireStalePeers(now: now)
        for peerID in expired {
            deliverEvent(.peerDisconnected(peerID))
        }
        if !expired.isEmpty {
            publishPeerSnapshots()
        }

        // A TCP connection that never completes a hello, or a hello that
        // never completes Noise, must not stay open forever. The peer
        // registry only knows peers that reached hello; this closes the
        // unauthenticated socket so a local attacker cannot hold slots.
        let expiredPeerIDs = Set(expired)
        let staleIdentifiers = links.compactMap { pair -> ObjectIdentifier? in
            let (identifier, link) = pair
            let age = now.timeIntervalSince(link.createdAt)
            let gaveUp = link.isAuthenticated
                ? false
                : (!link.receivedHello
                    ? age > LANTransportConfig.discoveryTimeout
                    : age > LANTransportConfig.discoveryTimeout + LANTransportConfig.handshakeTimeout)
            let peerExpired = link.peerID.map { expiredPeerIDs.contains($0) } ?? false
            return gaveUp || peerExpired ? identifier : nil
        }
        for identifier in staleIdentifiers {
            if let link = links[identifier] {
                link.isClosed = true
                link.connection.cancel()
            }
            links.removeValue(forKey: identifier)
        }
    }

    // MARK: - Events

    private func nicknameForPeer(_ peerID: PeerID) -> String? {
        guard let peer = registry.peers[peerID], !peer.nickname.isEmpty else { return nil }
        return peer.nickname
    }

    private func updatePermissionState(_ state: LANPermissionState) {
        guard permissionState != state else { return }
        permissionState = state
        SecureLogger.debug(
            "LAN transport: local-network permission state -> \(state.rawValue)",
            category: .session
        )
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .lanPermissionStateDidChange,
                object: nil,
                userInfo: ["state": state.rawValue]
            )
        }
    }

    private func publishPeerSnapshots() {
        let snapshots = registry.snapshots(now: Date())
        let delegate = peerEventsDelegate
        guard let delegate else { return }
        Task { @MainActor in
            delegate.didUpdatePeerSnapshots(snapshots)
        }
    }

    private func deliverEvent(_ event: TransportEvent) {
        let typedDelegate = eventDelegate
        let legacyDelegate = delegate
        Task { @MainActor in
            if let typedDelegate {
                typedDelegate.didReceiveTransportEvent(event)
            } else {
                legacyDelegate?.receiveTransportEvent(event)
            }
        }
    }

    private static func failureKind(for error: NWError) -> LANFailureKind {
        if case .posix(let code) = error {
            if code == .EACCES || code == .EPERM {
                return .permissionDenied
            }
        }
        return .transient
    }
}
