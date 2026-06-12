import BitLogger
import BitFoundation
import Foundation
import CoreBluetooth
import Combine
#if os(iOS)
import UIKit
#endif

/// BLEService — Bluetooth Mesh Transport
/// - Emits events exclusively via `BitchatDelegate` for UI.
/// - ChatViewModel must consume delegate callbacks (`didReceivePublicMessage`, `didReceiveNoisePayload`).
/// - A lightweight `peerSnapshotPublisher` is provided for non-UI services.
final class BLEService: NSObject {
    
    // MARK: - Constants
    
    #if DEBUG
    static let serviceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A") // testnet
    #else
    static let serviceUUID = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C") // mainnet
    #endif
    static let characteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    private static let centralRestorationID = "chat.bitchat.ble.central"
    private static let peripheralRestorationID = "chat.bitchat.ble.peripheral"
    
    // Default per-fragment chunk size when link limits are unknown
    private let defaultFragmentSize = TransportConfig.bleDefaultFragmentSize
    private let bleMaxMTU = 512
    private let maxMessageLength = InputValidator.Limits.maxMessageLength
    private let messageTTL: UInt8 = TransportConfig.messageTTLDefault
    // Flood/battery controls
    private let maxInFlightAssemblies = TransportConfig.bleMaxInFlightAssemblies // cap concurrent fragment assemblies
    private let highDegreeThreshold = TransportConfig.bleHighDegreeThreshold // for adaptive TTL/probabilistic relays
    
    // MARK: - Core State (5 Essential Collections)

    // 1. Consolidated BLE link tracking for both central and peripheral roles.
    private var linkStateStore = BLELinkStateStore()

    // BCH-01-004: Rate-limiting for subscription-triggered announces.
    private var subscriptionAnnounceLimiter = BLESubscriptionAnnounceLimiter()
    
    // 3. Peer Information (single source of truth)
    private var peerRegistry = BLEPeerRegistry()
    
    // 4. Efficient Message Deduplication
    private let messageDeduplicator = MessageDeduplicator()
    private var selfBroadcastTracker = BLESelfBroadcastTracker()
    private let meshTopology = MeshTopologyTracker()
    
    // 5. Fragment Reassembly (necessary for messages > MTU)
    private var fragmentAssemblyBuffer = BLEFragmentAssemblyBuffer()
    private var outboundFragmentTransfers = BLEOutboundFragmentTransferScheduler()
    private let incomingFileStore = BLEIncomingFileStore()
    
    // Simple announce throttling
    private var announceThrottle = BLEAnnounceThrottle()
    
    // Application state tracking (thread-safe)
    #if os(iOS)
    private var isAppActive: Bool = true  // Assume active initially
    #endif
    
    // MARK: - Core BLE Objects
    
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    
    // MARK: - Identity
    
    private var noiseService: NoiseEncryptionService
    private let identityManager: SecureIdentityStateManagerProtocol
    private let keychain: KeychainManagerProtocol
    private let idBridge: NostrIdentityBridge
    /// Binary form of `myPeerID`; same contract — mutated only inside a
    /// `messageQueue` barrier via `refreshPeerIdentity()`.
    private var myPeerIDData: Data = Data()

    // MARK: - Advertising Privacy
    // No Local Name by default for maximum privacy. No rotating alias.
    
    // MARK: - Queues
    
    private let messageQueue = DispatchQueue(label: "mesh.message", attributes: .concurrent)
    private let collectionsQueue = DispatchQueue(label: "mesh.collections", attributes: .concurrent)
    private let messageQueueKey = DispatchSpecificKey<Void>()
    private let bleQueue = DispatchQueue(label: "mesh.bluetooth", qos: .userInitiated)
    private let bleQueueKey = DispatchSpecificKey<Void>()
    
    // Noise messages and typed payloads pending handshake completion.
    private var pendingNoiseSessionQueues = BLENoiseSessionQueues()
    // Queue for notifications that failed due to full queue
    private var pendingNotifications = BLEOutboundNotificationBuffer<CBCentral>()
    // Backpressure logging fires per fragment during media transfers
    // (hundreds of lines per image); sampled via this counter, which is
    // only touched inside collectionsQueue barriers (no sync needed).
    var notificationBackpressureLogCount = 0

    // Accumulate long write chunks per central until a full frame decodes
    private var pendingWriteBuffers = BLEInboundWriteBuffer()
    // Relay jitter scheduling to reduce redundant floods
    private var scheduledRelays = BLEScheduledRelayStore()
    // Track short-lived traffic bursts to adapt announces/scanning under load
    private var recentTrafficTracker = BLERecentTrafficTracker()

    // Ingress link tracking for duplicate and last-hop suppression
    private var ingressLinks = BLEIngressLinkRegistry()
    private let logRateLimiter = BLELogRateLimiter(defaultMinimumInterval: 5)

    private var pendingPeripheralWrites = BLEOutboundWriteBuffer()
    // Debounce duplicate disconnect notifies
    private var disconnectNotifyDebouncer = BLEPeerEventDebouncer()
    // Store-and-forward for directed messages when we have no links
    private var pendingDirectedRelays = BLEDirectedRelaySpool()
    // Debounce for 'reconnected' logs
    private var reconnectLogDebouncer = BLEPeerEventDebouncer()
    // Announce-packet orchestration (queue hops stay in the environment closures)
    private lazy var announceHandler = BLEAnnounceHandler(environment: makeAnnounceHandlerEnvironment())
    // Public-message orchestration (queue hops stay in the environment closures)
    private lazy var publicMessageHandler = BLEPublicMessageHandler(environment: makePublicMessageHandlerEnvironment())
    // Noise handshake/encrypted orchestration (queue hops and crypto stay in the environment closures)
    private lazy var noisePacketHandler = BLENoisePacketHandler(environment: makeNoisePacketHandlerEnvironment())
    // Fragment-assembly orchestration (queue hops stay in the environment closures)
    private lazy var fragmentHandler = BLEFragmentHandler(environment: makeFragmentHandlerEnvironment())
    // File-transfer orchestration (queue hops stay in the environment closures)
    private lazy var fileTransferHandler = BLEFileTransferHandler(environment: makeFileTransferHandlerEnvironment())

    // MARK: - Gossip Sync
    private var gossipSyncManager: GossipSyncManager?
    private let requestSyncManager = RequestSyncManager()
    
    // MARK: - Maintenance Timer
    
    private var maintenanceTimer: DispatchSourceTimer?  // Single timer for all maintenance tasks
    private var maintenanceCounter = 0  // Track maintenance cycles
    /// Whether real CoreBluetooth managers were initialized. When false (unit
    /// tests), periodic mesh background work is not started — the maintenance
    /// timer and the gossip-sync timers only drain BLE writes/notifications,
    /// re-announce, and sign/broadcast sync packets, all meaningless without
    /// Bluetooth. Leaving them running in the test process is pure background
    /// churn that aggravates flaky exit hangs.
    private var meshBackgroundEnabled = false

    // MARK: - Connection budget & scheduling (central role)
    private var connectionScheduler = BLEConnectionScheduler<CBPeripheral>()

    // MARK: - Adaptive scanning duty-cycle
    private var scanDutyTimer: DispatchSourceTimer?
    private var dutyEnabled: Bool = true
    private var dutyOnDuration: TimeInterval = TransportConfig.bleDutyOnDuration
    private var dutyOffDuration: TimeInterval = TransportConfig.bleDutyOffDuration
    private var dutyActive: Bool = false
    
    // Debounced publish to coalesce rapid changes
    private var peerPublishCoalescer = BLEPeerPublishCoalescer()
    private func requestPeerDataPublish() {
        switch peerPublishCoalescer.requestPublish(now: Date()) {
        case .publishNow:
            publishFullPeerData()
        case .schedule(let delay):
            messageQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.peerPublishCoalescer.scheduledPublishFired(now: Date())
                self.publishFullPeerData()
            }
        case .skip:
            break
        }
    }
    
    // MARK: - Initialization
    
    init(
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        identityManager: SecureIdentityStateManagerProtocol,
        initializeBluetoothManagers: Bool = true
    ) {
        self.keychain = keychain
        self.idBridge = idBridge
        noiseService = NoiseEncryptionService(keychain: keychain)
        self.identityManager = identityManager
        super.init()
        
        configureNoiseServiceCallbacks(for: noiseService)
        refreshPeerIdentity()
        
        // Set queue key for identification
        messageQueue.setSpecific(key: messageQueueKey, value: ())
        
        // Set up application state tracking (iOS only)
        #if os(iOS)
        // Check initial state on main thread
        if Thread.isMainThread {
            isAppActive = UIApplication.shared.applicationState == .active
        } else {
            DispatchQueue.main.sync {
                isAppActive = UIApplication.shared.applicationState == .active
            }
        }
        
        // Observe application state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        #endif
        
        // Tag BLE queue for re-entrancy detection
        bleQueue.setSpecific(key: bleQueueKey, value: ())
        // Link state is owned exclusively by bleQueue; debug builds trap
        // any access from another queue (cross-queue reads use readLinkState).
        linkStateStore.assumeOwnership(of: bleQueue)

        if initializeBluetoothManagers {
            // Initialize BLE on background queue to prevent main thread blocking.
            #if os(iOS)
            let centralOptions: [String: Any] = [
                CBCentralManagerOptionRestoreIdentifierKey: BLEService.centralRestorationID
            ]
            centralManager = CBCentralManager(delegate: self, queue: bleQueue, options: centralOptions)

            let peripheralOptions: [String: Any] = [
                CBPeripheralManagerOptionRestoreIdentifierKey: BLEService.peripheralRestorationID
            ]
            peripheralManager = CBPeripheralManager(delegate: self, queue: bleQueue, options: peripheralOptions)
            #else
            centralManager = CBCentralManager(delegate: self, queue: bleQueue)
            peripheralManager = CBPeripheralManager(delegate: self, queue: bleQueue)
            #endif
        }
        
        // Single maintenance timer for all periodic tasks (dispatch-based for
        // determinism). Only run it when real Bluetooth managers exist.
        meshBackgroundEnabled = initializeBluetoothManagers
        startMaintenanceTimer()

        // Publish initial empty state
        requestPeerDataPublish()

        // Initialize gossip sync manager
        restartGossipManager()
    }
    
    private func restartGossipManager() {
        // Stop existing
        gossipSyncManager?.stop()
        
        let config = GossipSyncManager.Config(
            seenCapacity: TransportConfig.syncSeenCapacity,
            gcsMaxBytes: TransportConfig.syncGCSMaxBytes,
            gcsTargetFpr: TransportConfig.syncGCSTargetFpr,
            maxMessageAgeSeconds: TransportConfig.syncMaxMessageAgeSeconds,
            maintenanceIntervalSeconds: TransportConfig.syncMaintenanceIntervalSeconds,
            stalePeerCleanupIntervalSeconds: TransportConfig.syncStalePeerCleanupIntervalSeconds,
            stalePeerTimeoutSeconds: TransportConfig.syncStalePeerTimeoutSeconds,
            fragmentCapacity: TransportConfig.syncFragmentCapacity,
            fileTransferCapacity: TransportConfig.syncFileTransferCapacity,
            fragmentSyncIntervalSeconds: TransportConfig.syncFragmentIntervalSeconds,
            fileTransferSyncIntervalSeconds: TransportConfig.syncFileTransferIntervalSeconds,
            messageSyncIntervalSeconds: TransportConfig.syncMessageIntervalSeconds
        )
        
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
        manager.delegate = self
        // Only start the periodic sync timers when real Bluetooth exists. In unit
        // tests there is no mesh to sync with, and the periodic sign/broadcast
        // churn just keeps the process busy and aggravates flaky exit hangs.
        if meshBackgroundEnabled {
            manager.start()
        }
        gossipSyncManager = manager
    }

    // No advertising policy to set; we never include Local Name in adverts.
    
    deinit {
        maintenanceTimer?.cancel()
        scanDutyTimer?.cancel()
        scanDutyTimer = nil
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
        #if os(iOS)
        NotificationCenter.default.removeObserver(self)
        #endif
    }

    func resetIdentityForPanic(currentNickname: String) {
        messageQueue.sync(flags: .barrier) {
            pendingNoiseSessionQueues.removeAll()
        }

        let cancelledTransfers = collectionsQueue.sync(flags: .barrier) {
            pendingPeripheralWrites.removeAll()
            pendingNotifications.removeAll()
            let transfers = outboundFragmentTransfers.removeAll()
            fragmentAssemblyBuffer.removeAll()
            pendingDirectedRelays.removeAll()
            ingressLinks.removeAll()
            recentTrafficTracker.removeAll()
            scheduledRelays.cancelAll()
            return transfers
        }

        for entry in cancelledTransfers {
            entry.workItems.forEach { $0.cancel() }
            TransferProgressManager.shared.cancel(id: entry.id)
        }

        bleQueue.sync {
            pendingWriteBuffers.removeAll()
            connectionScheduler.reset()
        }
        disconnectNotifyDebouncer.removeAll()

        // The crypto-service replacement and the derived identity swap must be
        // one atomic unit with respect to messageQueue senders: a queued send
        // must never observe the new Noise service alongside the old peer ID
        // (it would sign with the new identity while carrying the old sender).
        // refreshPeerIdentity() executes inline here via its re-entrancy check.
        messageQueue.sync(flags: .barrier) {
            noiseService.clearEphemeralStateForPanic()
            noiseService.clearPersistentIdentity()

            let newNoise = NoiseEncryptionService(keychain: keychain)
            noiseService = newNoise
            configureNoiseServiceCallbacks(for: newNoise)
            refreshPeerIdentity()
        }
        restartGossipManager()

        setNickname(currentNickname)

        messageDeduplicator.reset()
        messageQueue.async(flags: .barrier) { [weak self] in
            self?.selfBroadcastTracker.removeAll()
        }
        requestPeerDataPublish()
        startServices()
    }
    
    // Ensure this runs on message queue to avoid main thread blocking
    func sendMessage(_ content: String, mentions: [String] = [], to recipientID: PeerID? = nil, messageID: String? = nil, timestamp: Date? = nil) {
        // Call directly if already on messageQueue, otherwise dispatch
        if DispatchQueue.getSpecific(key: messageQueueKey) == nil {
            messageQueue.async { [weak self] in
                self?.sendMessage(content, mentions: mentions, to: recipientID, messageID: messageID, timestamp: timestamp)
            }
            return
        }
        
        guard content.count <= maxMessageLength else {
            SecureLogger.error("Message too long: \(content.count) chars", category: .session)
            return
        }
        
        if let recipientID {
            sendPrivateMessage(content, to: recipientID, messageID: messageID ?? UUID().uuidString)
            return
        }
        
        // Public broadcast
        // Create packet with explicit fields so we can sign it
        let sendDate = timestamp ?? Date()
        let sendTimestampMs = UInt64(sendDate.timeIntervalSince1970 * 1000)
        let basePacket = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data(hexString: myPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: sendTimestampMs,
            payload: Data(content.utf8),
            signature: nil,
            ttl: messageTTL
        )
        guard let signedPacket = noiseService.signPacket(basePacket) else {
            SecureLogger.error("❌ Failed to sign public message", category: .security)
            return
        }
        // Pre-mark our own broadcast as processed to avoid handling relayed self copy
        let dedupID = BLESelfBroadcastTracker.dedupID(for: signedPacket)
        messageDeduplicator.markProcessed(dedupID)
        if let messageID {
            selfBroadcastTracker.record(messageID: messageID, packet: signedPacket, sentAt: sendDate)
        }
        // Call synchronously since we're already on background queue
        broadcastPacket(signedPacket)
        // Track our own broadcast for sync
        gossipSyncManager?.onPublicPacketSeen(signedPacket)
    }
    
    // MARK: - Transport Protocol Conformance

    // MARK: Delegates

    weak var delegate: BitchatDelegate?
    weak var eventDelegate: TransportEventDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?
    
    // MARK: Peer snapshots publisher (non-UI convenience)
    
    private let peerSnapshotSubject = PassthroughSubject<[TransportPeerSnapshot], Never>()
    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        peerSnapshotSubject.eraseToAnyPublisher()
    }

    func currentPeerSnapshots() -> [TransportPeerSnapshot] {
        collectionsQueue.sync {
            peerRegistry.transportSnapshots(selfNickname: myNickname)
        }
    }
    
    // MARK: Identity

    /// Derived from the Noise identity fingerprint; rotated only via
    /// `refreshPeerIdentity()` (e.g. panic reset), which performs the swap
    /// inside a `messageQueue` barrier so concurrent queue work never sees a
    /// half-updated identity. Externally read-only — no out-of-band mutation
    /// may bypass that derivation.
    private(set) var myPeerID = PeerID(str: "")
    /// Externally read-only; mutate via `setNickname(_:)`, which also
    /// broadcasts the change to peers.
    private(set) var myNickname: String = "anon"

    /// Sole mutator for `myNickname`: updates the stored value and force-sends
    /// an announce so peers learn the new name.
    func setNickname(_ nickname: String) {
        self.myNickname = nickname
        // Send announce to notify peers of nickname change (force send)
        sendAnnounce(forceSend: true)
    }
    
    // MARK: Lifecycle
    
    /// Creates and starts the periodic maintenance timer if it is not already
    /// running. Idempotent so it can be called from both `init` and
    /// `startServices()` — the latter matters after a panic reset, where
    /// `stopServices()` cancels and nils the timer.
    private func startMaintenanceTimer() {
        guard meshBackgroundEnabled, maintenanceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + TransportConfig.bleMaintenanceInterval,
                       repeating: TransportConfig.bleMaintenanceInterval,
                       leeway: .seconds(TransportConfig.bleMaintenanceLeewaySeconds))
        timer.setEventHandler { [weak self] in
            self?.performMaintenance()
        }
        timer.resume()
        maintenanceTimer = timer
    }

    func startServices() {
        // Restart the maintenance timer if a prior stopServices() cancelled it
        // (e.g. the panic flow), otherwise periodic announces, peer reconciliation
        // and cache cleanup would never resume until app restart.
        startMaintenanceTimer()

        // Start BLE services if not already running
        if centralManager?.state == .poweredOn {
            centralManager?.scanForPeripherals(
                withServices: [BLEService.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        
        // Send initial announce after services are ready
        // Use longer delay to avoid conflicts with other announces
        messageQueue.asyncAfter(deadline: .now() + TransportConfig.bleInitialAnnounceDelaySeconds) { [weak self] in
            self?.sendAnnounce(forceSend: true)
        }
    }
    
    func stopServices() {
        // Send leave message synchronously to ensure delivery
        var leavePacket = BitchatPacket(
            type: MessageType.leave.rawValue,
            senderID: myPeerIDData,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(),
            signature: nil,
            ttl: messageTTL
        )

        if let signed = noiseService.signPacket(leavePacket) {
            leavePacket = signed
        }

        // Send immediately to all connected peers (synchronized access to BLE state)
        if let data = leavePacket.toBinaryData(padding: false) {
            let leavePriority = BLEOutboundPacketPolicy.priority(for: leavePacket, data: data)

            // Snapshot BLE state under bleQueue to avoid races with delegate callbacks
            let (peripheralStates, centralsCount, char) = bleQueue.sync {
                (linkStateStore.peripheralStates, linkStateStore.subscribedCentralCount, characteristic)
            }

            // Send to peripherals we're connected to as central
            for state in peripheralStates where state.isConnected {
                if let characteristic = state.characteristic {
                    writeOrEnqueue(data, to: state.peripheral, characteristic: characteristic, priority: leavePriority)
                }
            }

            // Send to centrals subscribed to us as peripheral
            if centralsCount > 0, let ch = char {
                peripheralManager?.updateValue(data, for: ch, onSubscribedCentrals: nil)
            }
        }

        // Give leave message a moment to send (cooperative delay allows BLE callbacks to fire)
        let deadline = Date().addingTimeInterval(TransportConfig.bleThreadSleepWriteShortDelaySeconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        // Clear pending notifications
        collectionsQueue.sync(flags: .barrier) {
            pendingNotifications.removeAll()
        }

        // Stop timer
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        scanDutyTimer?.cancel()
        scanDutyTimer = nil

        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()

        // Disconnect all peripherals (synchronized access)
        let peripheralsToDisconnect = bleQueue.sync { linkStateStore.peripheralStates }
        for state in peripheralsToDisconnect {
            centralManager?.cancelPeripheralConnection(state.peripheral)
        }
    }
    
    func emergencyDisconnectAll() {
        stopServices()

        // Clear all sessions and peers
        let cancelledTransfers: [(id: String, items: [DispatchWorkItem])] = collectionsQueue.sync(flags: .barrier) {
            let entries = outboundFragmentTransfers.removeAll().map { ($0.id, $0.workItems) }
            peerRegistry.removeAll()
            fragmentAssemblyBuffer.removeAll()
            // Also clear pending message queues to avoid stale state across sessions
            pendingNoiseSessionQueues.removeAll()
            pendingDirectedRelays.removeAll()
            return entries
        }

        for entry in cancelledTransfers {
            entry.items.forEach { $0.cancel() }
            TransferProgressManager.shared.cancel(id: entry.id)
        }

        // Clear processed messages
        messageDeduplicator.reset()

        // Clear peripheral references (synchronized access to avoid races with BLE callbacks)
        bleQueue.sync {
            linkStateStore.clearAll()
            connectionScheduler.reset()
            subscriptionAnnounceLimiter.removeAll()
        }
        meshTopology.reset()
    }
    
    // MARK: Connectivity and peers
    
    func isPeerConnected(_ peerID: PeerID) -> Bool {
        // Accept both 16-hex short IDs and 64-hex Noise keys
        return collectionsQueue.sync { peerRegistry.isConnected(peerID) }
    }

    func isPeerReachable(_ peerID: PeerID) -> Bool {
        // Accept both 16-hex short IDs and 64-hex Noise keys
        return collectionsQueue.sync {
            peerRegistry.isReachable(peerID, now: Date())
        }
    }

    func peerNickname(peerID: PeerID) -> String? {
        collectionsQueue.sync {
            peerRegistry.nickname(for: peerID, connectedOnly: true)
        }
    }

    func getPeerNicknames() -> [PeerID: String] {
        return collectionsQueue.sync {
            peerRegistry.displayNicknames(selfNickname: myNickname)
        }
    }
    
    // MARK: Protocol utilities
    
    func getFingerprint(for peerID: PeerID) -> String? {
        return collectionsQueue.sync {
            peerRegistry.fingerprint(for: peerID)
        }
    }
    
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState {
        if noiseService.hasEstablishedSession(with: peerID) {
            return .established
        } else if noiseService.hasSession(with: peerID) {
            return .handshaking
        } else {
            return .none
        }
    }
    
    func triggerHandshake(with peerID: PeerID) {
        initiateNoiseHandshake(with: peerID)
    }
    
    // MARK: Noise identity/session access (narrow Transport wrappers)

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
        // `onPeerAuthenticated` is additive (the encryption service keeps an
        // array of handlers); `onHandshakeRequired` is a single slot.
        noiseService.onPeerAuthenticated = onPeerAuthenticated
        noiseService.onHandshakeRequired = onHandshakeRequired
    }

    func getCurrentBluetoothState() -> CBManagerState {
        return centralManager?.state ?? .unknown
    }

    // MARK: Messaging

    func cancelTransfer(_ transferId: String) {
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            switch self.outboundFragmentTransfers.cancelTransfer(transferId) {
            case let .active(id, workItems):
                workItems.forEach { $0.cancel() }
                TransferProgressManager.shared.cancel(id: transferId)
                SecureLogger.debug("🛑 Cancelled transfer \(id.prefix(8))…", category: .session)
                self.messageQueue.async { [weak self] in
                    self?.startNextPendingTransferIfNeeded()
                }

            case let .pending(id):
                TransferProgressManager.shared.cancel(id: transferId)
                SecureLogger.debug("🛑 Removed pending transfer \(id.prefix(8))… before start", category: .session)

            case .missing:
                break
            }
        }
    }
    
    // Transport protocol conformance helper: simplified public message send
    func sendMessage(_ content: String, mentions: [String]) {
        // Delegate to the full API with default routing
        sendMessage(content, mentions: mentions, to: nil, messageID: nil, timestamp: nil)
    }

    func sendMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        sendMessage(content, mentions: mentions, to: nil, messageID: messageID, timestamp: timestamp)
    }
    
    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        sendPrivateMessage(content, to: peerID, messageID: messageID)
    }

    func sendFileBroadcast(_ filePacket: BitchatFilePacket, transferId: String) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            guard let payload = filePacket.encode() else {
                SecureLogger.error("❌ Failed to encode file packet for broadcast", category: .session)
                return
            }

            var packet = BitchatPacket(
                type: MessageType.fileTransfer.rawValue,
                senderID: self.myPeerIDData,
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: self.messageTTL,
                version: 2
            )

            if let signed = self.noiseService.signPacket(packet) {
                packet = signed
            } else {
                SecureLogger.error("❌ Failed to sign file broadcast packet", category: .security)
                return
            }

            let senderHex = packet.senderID.hexEncodedString()
            let dedupID = "\(senderHex)-\(packet.timestamp)-\(packet.type)"
            self.messageDeduplicator.markProcessed(dedupID)

            SecureLogger.debug("📁 Broadcasting file transfer payload bytes=\(payload.count)", category: .session)
            self.broadcastPacket(packet, transferId: transferId)
            self.gossipSyncManager?.onPublicPacketSeen(packet)
        }
    }

    func sendFilePrivate(_ filePacket: BitchatFilePacket, to peerID: PeerID, transferId: String) {
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            guard let payload = filePacket.encode() else {
                SecureLogger.error("❌ Failed to encode file packet for private send", category: .session)
                return
            }
            // Normalize to short form (SHA256-derived 16-hex) for wire protocol compatibility
            // This ensures 64-hex Noise keys are converted to the canonical routing format
            let targetID = peerID.toShort()
            guard let recipientData = Data(hexString: targetID.id) else {
                SecureLogger.error("❌ Invalid recipient peer ID for file transfer: \(peerID.id.prefix(8))…", category: .session)
                return
            }

            var packet = BitchatPacket(
                type: MessageType.fileTransfer.rawValue,
                senderID: self.myPeerIDData,
                recipientID: recipientData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: self.messageTTL,
                version: 2
            )

            if let signed = self.noiseService.signPacket(packet) {
                packet = signed
            }

            SecureLogger.debug("📁 Sending private file transfer to \(peerID.id.prefix(8))… bytes=\(payload.count)", category: .session)
            self.broadcastPacket(packet, transferId: transferId)
        }
    }

    
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        let payload = BLENoisePayloadFactory.readReceipt(originalMessageID: receipt.originalMessageID)

        if noiseService.hasEstablishedSession(with: peerID) {
            SecureLogger.debug("📤 Sending READ receipt id=\(receipt.originalMessageID.prefix(8))… to \(peerID.id.prefix(8))…", category: .session)
            do {
                broadcastPacket(try makeEncryptedNoisePacket(payload, to: peerID))
            } catch {
                SecureLogger.error("Failed to send read receipt: \(error)")
            }
        } else {
            // Queue for after handshake and initiate if needed
            collectionsQueue.sync(flags: .barrier) {
                pendingNoiseSessionQueues.appendTypedPayload(payload, for: peerID)
            }
            if !noiseService.hasSession(with: peerID) { initiateNoiseHandshake(with: peerID) }
            SecureLogger.debug("🕒 Queued READ receipt for \(peerID.id.prefix(8))… until handshake completes", category: .session)
        }
    }
    
    private func acceptedIngressContext(
        for packet: BitchatPacket,
        claimedSenderID: PeerID,
        boundPeerID: PeerID?,
        linkDescription: String
    ) -> BLEIngressPacketContext? {
        switch BLEIngressPacketGuard.evaluate(
            packet: packet,
            claimedSenderID: claimedSenderID,
            boundPeerID: boundPeerID,
            localPeerID: myPeerID,
            directAnnounceTTL: messageTTL,
            isValidSyncResponse: { [requestSyncManager] peerID in
                requestSyncManager.isValidResponse(from: peerID, isRSR: true)
            }
        ) {
        case .success(let context):
            if packet.isRSR {
                logValidRSR(from: context.validationPeerID)
            }
            return context
        case .failure(.selfLoopback):
            logSelfLoopback(packetType: packet.type, linkDescription: linkDescription)
            return nil
        case .failure(.directSenderMismatch(let boundPeerID, let claimedSenderID)):
            SecureLogger.warning("🚫 SECURITY: Sender ID spoofing attempt detected! \(linkDescription) claimed to be \(claimedSenderID.id.prefix(8))… but is bound to \(boundPeerID.id.prefix(8))…", category: .security)
            return nil
        case .failure(.invalidRSR(let peerID)):
            SecureLogger.warning("Invalid or unsolicited RSR packet from \(peerID.id.prefix(8))… - rejecting", category: .security)
            return nil
        case .failure(.timestampSkew(let peerID, let skewMs, let maxSkewMs)):
            SecureLogger.warning("Packet timestamp skewed by \(skewMs)ms (max \(maxSkewMs)ms) from \(peerID.id.prefix(8))…", category: .security)
            return nil
        }
    }

    private func isAcceptedIngressPayload(_ packet: BitchatPacket, from peerID: PeerID) -> Bool {
        switch BLEIngressPacketGuard.validatePayload(
            packet,
            from: peerID,
            isValidSyncResponse: { [requestSyncManager] peerID in
                requestSyncManager.isValidResponse(from: peerID, isRSR: true)
            }
        ) {
        case .success:
            if packet.isRSR {
                logValidRSR(from: peerID)
            }
            return true
        case .failure(.invalidRSR(let peerID)):
            SecureLogger.warning("Invalid or unsolicited RSR packet from \(peerID.id.prefix(8))… - rejecting", category: .security)
            return false
        case .failure(.timestampSkew(let peerID, let skewMs, let maxSkewMs)):
            SecureLogger.warning("Packet timestamp skewed by \(skewMs)ms (max \(maxSkewMs)ms) from \(peerID.id.prefix(8))…", category: .security)
            return false
        case .failure(.selfLoopback), .failure(.directSenderMismatch):
            return false
        }
    }

    private func logValidRSR(from peerID: PeerID) {
        guard logRateLimiter.shouldLog(key: "valid-rsr:\(peerID.id)") else { return }
        SecureLogger.debug("Valid RSR packet from \(peerID.id.prefix(8))… - skipping timestamp check", category: .security)
    }

    private func logSelfLoopback(packetType: UInt8, linkDescription: String) {
        guard logRateLimiter.shouldLog(
            key: "self-loopback:\(packetType)",
            minimumInterval: 30
        ) else { return }
        SecureLogger.debug("↩️ Dropping BLE self-loopback packet type \(packetType) from \(linkDescription)", category: .session)
    }

    private func recordIngressIfNew(_ packet: BitchatPacket, link: BLEIngressLinkID, peerID: PeerID) -> Bool {
        return collectionsQueue.sync(flags: .barrier) {
            ingressLinks.recordIfNew(
                packet,
                link: link,
                peerID: peerID,
                lifetime: TransportConfig.bleIngressRecordLifetimeSeconds
            )
        }
    }

    // MARK: - Packet Broadcasting
    
    private func broadcastPacket(_ packet: BitchatPacket, transferId: String? = nil) {
        // Apply route if recipient exists (centralized route application)
        let packetToSend: BitchatPacket
        if let recipientPeerID = PeerID(hexData: packet.recipientID) {
            packetToSend = applyRouteIfAvailable(packet, to: recipientPeerID)
        } else {
            packetToSend = packet
        }
        
        // Encode once using a small per-type padding policy, then delegate by type
        let padForBLE = BLEOutboundPacketPolicy.padsBLEFrame(for: packetToSend.type)
        if packetToSend.type == MessageType.fileTransfer.rawValue {
            sendFragmentedPacket(packetToSend, pad: padForBLE, maxChunk: nil, directedOnlyPeer: nil, transferId: transferId)
            return
        }
        guard let data = packetToSend.toBinaryData(padding: padForBLE) else {
            SecureLogger.error("❌ Failed to convert packet to binary data", category: .session)
            return
        }
        if packetToSend.type == MessageType.noiseEncrypted.rawValue {
            sendEncrypted(packetToSend, data: data, pad: padForBLE)
            return
        }
        sendGenericBroadcast(packetToSend, data: data, pad: padForBLE)
    }

    private func sendEncrypted(_ packet: BitchatPacket, data: Data, pad: Bool) {
        guard let recipientPeerID = PeerID(hexData: packet.recipientID) else { return }
        var sentEncrypted = false

        let outboundPriority = BLEOutboundPacketPolicy.priority(for: packet, data: data)

        // Per-link limits for the specific peer
        let directPeripheralState = snapshotDirectPeripheralState(for: recipientPeerID)
        let recipientCentral = snapshotSubscribedCentrals().central(for: recipientPeerID)

        if let peripheralMaxLen = directPeripheralState?.peripheral.maximumWriteValueLength(for: .withoutResponse),
           data.count > peripheralMaxLen {
            let chunk = BLEOutboundPacketPolicy.fragmentChunkSize(forLinkLimit: peripheralMaxLen)
            sendFragmentedPacket(packet, pad: pad, maxChunk: chunk, directedOnlyPeer: recipientPeerID)
            return
        }
        if let centralMaxLen = recipientCentral?.maximumUpdateValueLength,
           data.count > centralMaxLen {
            let chunk = BLEOutboundPacketPolicy.fragmentChunkSize(forLinkLimit: centralMaxLen)
            sendFragmentedPacket(packet, pad: pad, maxChunk: chunk, directedOnlyPeer: recipientPeerID)
            return
        }

        // Direct write via peripheral link
        if let state = directPeripheralState,
           state.isConnected,
           let characteristic = state.characteristic {
            writeOrEnqueue(data, to: state.peripheral, characteristic: characteristic, priority: outboundPriority)
            sentEncrypted = true
        }

        // Notify via central link (dual-role)
        if let characteristic = characteristic, !sentEncrypted, let recipientCentral {
            let success = peripheralManager?.updateValue(data, for: characteristic, onSubscribedCentrals: [recipientCentral]) ?? false
            if success {
                sentEncrypted = true
            } else {
                enqueuePendingNotification(data: data, centrals: [recipientCentral], context: "encrypted")
            }
        }

        if !sentEncrypted {
            // Flood as last resort with recipient set; link aware
            sendOnAllLinks(packet: packet, data: data, pad: pad, directedOnlyPeer: recipientPeerID)
        }
    }

    private func sendGenericBroadcast(_ packet: BitchatPacket, data: Data, pad: Bool) {
        sendOnAllLinks(packet: packet, data: data, pad: pad, directedOnlyPeer: nil)
    }

    private func enqueuePendingNotification(data: Data, centrals: [CBCentral]?, context: String, attempt: Int = 0) {
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let result = self.pendingNotifications.enqueue(
                data: data,
                targets: centrals,
                capCount: TransportConfig.blePendingNotificationsCapCount
            )

            if case let .enqueued(count) = result {
                self.logBackpressureSampled("📋 Queued \(context) packet for retry (pending=\(count))")
                return
            }

            if attempt >= TransportConfig.bleNotificationRetryMaxAttempts {
                SecureLogger.error("❌ Dropping \(context) packet after exhausting retry window (pending=\(self.pendingNotifications.count))", category: .session)
                return
            }

            let backoff = TransportConfig.bleNotificationRetryDelayMs * max(1, attempt + 1)
            let deadline = DispatchTime.now() + .milliseconds(backoff)
            self.messageQueue.asyncAfter(deadline: deadline) { [weak self] in
                self?.enqueuePendingNotification(data: data, centrals: centrals, context: context, attempt: attempt + 1)
            }
        }
    }

    private func sendOnAllLinks(packet: BitchatPacket, data: Data, pad: Bool, directedOnlyPeer: PeerID?) {
        let ingressRecord = collectionsQueue.sync { ingressLinks.record(for: packet) }
        let excludedPeerLinks = links(to: ingressRecord?.peerID)
        let outboundPriority = BLEOutboundPacketPolicy.priority(for: packet, data: data)

        let states = snapshotPeripheralStates()
        let connectedStates = states.filter { $0.isConnected }
        let subscribedCentrals = characteristic == nil ? [] : snapshotSubscribedCentrals().centrals
        let connectedPeripheralIDs = connectedStates.map { $0.peripheral.identifier.uuidString }
        let centralIDs = subscribedCentrals.map { $0.identifier.uuidString }
        let peripheralPeerBindings = Dictionary(uniqueKeysWithValues: connectedStates.compactMap { state in
            state.peerID.map { (state.peripheral.identifier.uuidString, $0) }
        })
        let plan = BLEOutboundLinkPlanner.plan(
            packet: packet,
            dataCount: data.count,
            peripheralIDs: connectedPeripheralIDs,
            peripheralWriteLimits: connectedStates.map { $0.peripheral.maximumWriteValueLength(for: .withoutResponse) },
            centralIDs: centralIDs,
            centralNotifyLimits: subscribedCentrals.map { $0.maximumUpdateValueLength },
            ingressRecord: ingressRecord,
            excludedLinks: excludedPeerLinks,
            peripheralPeerBindings: peripheralPeerBindings,
            centralPeerBindings: snapshotSubscribedCentrals().peerIDsByCentralUUID,
            directedOnlyPeer: directedOnlyPeer
        )

        if let chunk = plan.fragmentChunkSize {
            sendFragmentedPacket(packet, pad: pad, maxChunk: chunk, directedOnlyPeer: directedOnlyPeer)
            return
        }

        // If directed and we currently have no links to forward on, spool for a short window
        if let only = plan.directedPeerHint,
           plan.shouldSpoolDirectedPacket {
            spoolDirectedPacket(packet, recipientPeerID: only)
        }

        // Writes to selected connected peripherals
        for s in connectedStates {
            let pid = s.peripheral.identifier.uuidString
            guard plan.selectedLinks.peripheralIDs.contains(pid) else { continue }
            if let ch = s.characteristic {
                writeOrEnqueue(data, to: s.peripheral, characteristic: ch, priority: outboundPriority)
            }
        }
        // Notify selected subscribed centrals
        if let ch = characteristic {
            let targets = subscribedCentrals.filter { plan.selectedLinks.centralIDs.contains($0.identifier.uuidString) }
            if !targets.isEmpty {
                let success = peripheralManager?.updateValue(data, for: ch, onSubscribedCentrals: targets) ?? false
                if !success {
                    // Notification queue full - queue for retry to prevent silent packet loss
                    // This is critical for fragment delivery reliability
                    let context = packet.type == MessageType.fragment.rawValue ? "fragment" : "broadcast"
                    enqueuePendingNotification(data: data, centrals: targets, context: context)
                }
            }
        }
    }

    // Directed send helper (unicast to a specific peerID) without altering packet contents
    private func sendPacketDirected(_ packet: BitchatPacket, to peerID: PeerID) {
        guard let data = packet.toBinaryData(padding: false) else { return }
        sendOnAllLinks(packet: packet, data: data, pad: false, directedOnlyPeer: peerID)
    }

    // MARK: - Directed store-and-forward
    private func spoolDirectedPacket(_ packet: BitchatPacket, recipientPeerID: PeerID) {
        let msgID = BLEOutboundPacketPolicy.messageID(for: packet)
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            if self.pendingDirectedRelays.enqueue(
                packet: packet,
                recipient: recipientPeerID,
                messageID: msgID,
                enqueuedAt: Date()
            ) {
                SecureLogger.debug("🧳 Spooling directed packet for \(recipientPeerID) mid=\(msgID.prefix(8))…", category: .session)
            }
        }
    }

    private func flushDirectedSpool() {
        // Move items out and attempt broadcast; if still no links, they'll be re-spooled
        let toSend = collectionsQueue.sync(flags: .barrier) {
            pendingDirectedRelays.drainUnexpired(
                now: Date(),
                window: TransportConfig.bleDirectedSpoolWindowSeconds
            )
        }
        guard !toSend.isEmpty else { return }
        for entry in toSend {
            messageQueue.async { [weak self] in self?.broadcastPacket(entry.packet) }
        }
    }

    private func signedSenderDisplayName(for packet: BitchatPacket, from peerID: PeerID) -> String? {
        guard let signature = packet.signature,
              let packetData = packet.toBinaryDataForSigning() else {
            return nil
        }

        let candidates = identityManager.getCryptoIdentitiesByPeerIDPrefix(peerID)
        for candidate in candidates {
            guard let signingKey = candidate.signingPublicKey,
                  noiseService.verifySignature(signature, for: packetData, publicKey: signingKey) else {
                continue
            }

            if let social = identityManager.getSocialIdentity(for: candidate.fingerprint) {
                return social.localPetname ?? social.claimedNickname
            }

            return BLEPeerSenderDisplayName.anonymousNickname(for: peerID)
        }

        return nil
    }

    private func handleFileTransfer(_ packet: BitchatPacket, from peerID: PeerID) {
        fileTransferHandler.handle(packet, from: peerID)
    }

    /// Builds the file-transfer handler environment. All queue hops stay here
    /// so `BLEFileTransferHandler` remains queue-agnostic and synchronously
    /// testable.
    private func makeFileTransferHandlerEnvironment() -> BLEFileTransferHandlerEnvironment {
        BLEFileTransferHandlerEnvironment(
            localPeerID: { [weak self] in
                self?.myPeerID ?? PeerID(str: "")
            },
            localNickname: { [weak self] in
                self?.myNickname ?? ""
            },
            peersSnapshot: { [weak self] in
                guard let self = self else { return [:] }
                return self.collectionsQueue.sync { self.peerRegistry.snapshotByID }
            },
            signedSenderDisplayName: { [weak self] packet, peerID in
                self?.signedSenderDisplayName(for: packet, from: peerID)
            },
            trackPacketSeen: { [weak self] packet in
                self?.gossipSyncManager?.onPublicPacketSeen(packet)
            },
            enforceStorageQuota: { [weak self] reservingBytes in
                self?.incomingFileStore.enforceQuota(reservingBytes: reservingBytes)
            },
            saveIncomingFile: { [weak self] data, preferredName, subdirectory, fallbackExtension, defaultPrefix in
                self?.incomingFileStore.save(
                    data: data,
                    preferredName: preferredName,
                    subdirectory: subdirectory,
                    fallbackExtension: fallbackExtension,
                    defaultPrefix: defaultPrefix
                )
            },
            updatePeerLastSeen: { [weak self] peerID in
                self?.updatePeerLastSeen(peerID)
            },
            deliverMessage: { [weak self] message in
                // Single main-actor hop delivering `.messageReceived`.
                self?.emitTransportEvent(.messageReceived(message))
            }
        )
    }
    
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        SecureLogger.debug("🔔 sendFavoriteNotification peer=\(peerID.id.prefix(8))… isFavorite=\(isFavorite)", category: .session)
        
        // Include Nostr public key in the notification
        var content = isFavorite ? "[FAVORITED]" : "[UNFAVORITED]"
        var includesNostrIdentity = false
        
        // Add our Nostr public key if available
        if let myNostrIdentity = try? idBridge.getCurrentNostrIdentity() {
            content += ":" + myNostrIdentity.npub
            includesNostrIdentity = true
            SecureLogger.debug("📝 Favorite notification includes Nostr npub=\(myNostrIdentity.npub.prefix(16))…", category: .session)
        }
        
        SecureLogger.debug("📤 Sending favorite notification to \(peerID.id.prefix(8))… isFavorite=\(isFavorite) includesNostrIdentity=\(includesNostrIdentity)", category: .session)
        sendPrivateMessage(content, to: peerID, messageID: UUID().uuidString)
    }
    
    func sendBroadcastAnnounce() {
        sendAnnounce()
    }
    
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {
        let payload = BLENoisePayloadFactory.delivered(messageID: messageID)

        if noiseService.hasEstablishedSession(with: peerID) {
            do {
                broadcastPacket(try makeEncryptedNoisePacket(payload, to: peerID))
            } catch {
                SecureLogger.error("Failed to send delivery ACK: \(error)")
            }
        } else {
            // Queue for after handshake and initiate if needed
            collectionsQueue.sync(flags: .barrier) {
                pendingNoiseSessionQueues.appendTypedPayload(payload, for: peerID)
            }
            if !noiseService.hasSession(with: peerID) { initiateNoiseHandshake(with: peerID) }
            SecureLogger.debug("🕒 Queued DELIVERED ack for \(peerID.id.prefix(8))… until handshake completes", category: .session)
        }
    }

    private func handleLeave(_ packet: BitchatPacket, from peerID: PeerID) {
        _ = collectionsQueue.sync(flags: .barrier) {
            // Remove the peer when they leave
            peerRegistry.remove(peerID)
        }
        // Remove any stored announcement for sync purposes
        gossipSyncManager?.removeAnnouncementForPeer(peerID)
        // Send on main thread
        notifyUI { [weak self] in
            guard let self = self else { return }
            
            // Get current peer list (after removal)
            let currentPeerIDs = self.collectionsQueue.sync { self.peerRegistry.peerIDs }
            
            self.deliverTransportEvent(.peerDisconnected(peerID))
            self.deliverTransportEvent(.peerListUpdated(currentPeerIDs))
        }
    }
    private func sendAnnounce(forceSend: Bool = false) {
        // Throttle announces to prevent flooding
        if !announceThrottle.shouldSend(force: forceSend, now: Date()) {
            return
        }

        // Reduced logging - only log errors, not every announce
        
        // Create announce payload with both noise and signing public keys
        let noisePub = noiseService.getStaticPublicKeyData()  // For noise handshakes and peer identification
        let signingPub = noiseService.getSigningPublicKeyData()  // For signature verification
        
        let connectedPeerIDs: [Data] = collectionsQueue.sync {
            peerRegistry.connectedRoutingData
        }
        
        let announcement = AnnouncementPacket(
            nickname: myNickname,
            noisePublicKey: noisePub,
            signingPublicKey: signingPub,
            directNeighbors: connectedPeerIDs
        )
        
        guard let payload = announcement.encode() else {
            SecureLogger.error("❌ Failed to encode announce packet", category: .session)
            return
        }
        
        // Create packet with signature using the noise private key
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: myPeerIDData,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil, // Will be set by signPacket below
            ttl: messageTTL
        )
        
        // Sign the packet using the noise private key
        guard let signedPacket = noiseService.signPacket(packet) else {
            SecureLogger.error("❌ Failed to sign announce packet", category: .security)
            return
        }
        
        // Call directly if on messageQueue, otherwise dispatch
        if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
            broadcastPacket(signedPacket)
        } else {
            messageQueue.async { [weak self] in
                self?.broadcastPacket(signedPacket)
            }
        }
        // Ensure our own announce is included in sync state
        gossipSyncManager?.onPublicPacketSeen(signedPacket)
    }

    // MARK: QR Verification over Noise
    
    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        let payload = VerificationService.shared.buildVerifyChallenge(noiseKeyHex: noiseKeyHex, nonceA: nonceA)
        sendNoisePayload(payload, to: peerID)
    }

    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        guard let payload = VerificationService.shared.buildVerifyResponse(noiseKeyHex: noiseKeyHex, nonceA: nonceA) else { return }
        sendNoisePayload(payload, to: peerID)
    }
}

// MARK: - GossipSyncManager Delegate
extension BLEService: GossipSyncManager.Delegate {
    func sendPacket(_ packet: BitchatPacket) {
        broadcastPacket(packet)
    }

    func sendPacket(to peerID: PeerID, packet: BitchatPacket) {
        sendPacketDirected(packet, to: peerID)
    }

    func signPacketForBroadcast(_ packet: BitchatPacket) -> BitchatPacket {
        return noiseService.signPacket(packet) ?? packet
    }
    
    func getConnectedPeers() -> [PeerID] {
        return collectionsQueue.sync {
            peerRegistry.connectedPeerIDs
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEService: CBCentralManagerDelegate {
    #if os(iOS)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        let restoredPeripherals = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        let restoredServices = (dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID]) ?? []
        let restoredOptions = (dict[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any]) ?? [:]
        let allowDuplicates = restoredOptions[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool

        SecureLogger.info(
            "♻️ Central restore: peripherals=\(restoredPeripherals.count) services=\(restoredServices.count) allowDuplicates=\(String(describing: allowDuplicates))",
            category: .session
        )

        for peripheral in restoredPeripherals {
            let identifier = peripheral.identifier.uuidString
            peripheral.delegate = self
            let existing = linkStateStore.state(forPeripheralID: identifier)
            let assembler = existing?.assembler ?? NotificationStreamAssembler()
            let characteristic = existing?.characteristic
            let peerID = existing?.peerID
            let wasConnecting = existing?.isConnecting ?? false
            let wasConnected = existing?.isConnected ?? false

            let restoredState = BLEPeripheralLinkState(
                peripheral: peripheral,
                characteristic: characteristic,
                peerID: peerID,
                isConnecting: wasConnecting || peripheral.state == .connecting,
                isConnected: wasConnected || peripheral.state == .connected,
                lastConnectionAttempt: existing?.lastConnectionAttempt,
                assembler: assembler
            )
            linkStateStore.setPeripheralState(restoredState, for: identifier)
        }

        captureBluetoothStatus(context: "central-restore")

        if central.state == .poweredOn {
            startScanning()
        }
    }
    #endif

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emitTransportEvent(.bluetoothStateUpdated(central.state))

        switch central.state {
        case .poweredOn:
            // Start scanning - use allow duplicates for faster discovery when active
            startScanning()

        case .poweredOff:
            // Bluetooth was turned off - stop scanning and clean up connection state
            SecureLogger.info("📴 Bluetooth powered off - cleaning up central state", category: .session)
            central.stopScan()
            // Mark all peripheral connections as disconnected (they are now invalid)
            let peripheralStates = linkStateStore.peripheralStates
            let peerIDs: [PeerID] = peripheralStates.compactMap(\.peerID)
            for state in peripheralStates {
                central.cancelPeripheralConnection(state.peripheral)
            }
            _ = linkStateStore.clearPeripherals()
            // Notify UI of disconnections
            for peerID in peerIDs {
                notifyUI { [weak self] in
                    self?.notifyPeerDisconnectedDebounced(peerID)
                }
            }

        case .unauthorized:
            // User denied Bluetooth permission
            SecureLogger.warning("🚫 Bluetooth unauthorized - user denied permission", category: .session)
            central.stopScan()
            _ = linkStateStore.clearPeripherals()

        case .unsupported:
            // Device doesn't support BLE
            SecureLogger.error("❌ Bluetooth LE not supported on this device", category: .session)

        case .resetting:
            // Bluetooth stack is resetting - will get another state update when done
            SecureLogger.info("🔄 Bluetooth stack resetting...", category: .session)

        case .unknown:
            // Initial state before we know the actual state
            SecureLogger.debug("❓ Bluetooth state unknown (initializing)", category: .session)

        @unknown default:
            SecureLogger.warning("⚠️ Unknown Bluetooth state: \(central.state.rawValue)", category: .session)
        }
    }
    
    private func startScanning() {
        guard let central = centralManager,
              central.state == .poweredOn,
              !central.isScanning else { return }
        
        // Use allow duplicates = true for faster discovery in foreground
        // This gives us discovery events immediately instead of coalesced
        #if os(iOS)
        let allowDuplicates = isAppActive  // Use our tracked state (thread-safe)
        #else
        let allowDuplicates = true  // macOS doesn't have background restrictions
        #endif
        
        central.scanForPeripherals(
                withServices: [BLEService.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
        
        // Started BLE scanning
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let peripheralID = peripheral.identifier.uuidString
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? (peripheralID.prefix(6) + "…")
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let rssiValue = RSSI.intValue

        let candidate = BLEConnectionCandidate(
            peripheral: peripheral,
            peripheralID: peripheralID,
            rssi: rssiValue,
            name: String(advertisedName),
            isConnectable: isConnectable,
            discoveredAt: Date()
        )
        let existingState = linkStateStore.state(forPeripheralID: peripheralID).map(BLEExistingConnectionState.init)

        switch connectionScheduler.handleDiscovery(
            candidate,
            connectedOrConnectingCount: linkStateStore.connectedOrConnectingPeripheralCount,
            existingState: existingState,
            peripheralState: peripheral.state.connectionSchedulerState,
            now: candidate.discoveredAt
        ) {
        case .ignore, .queued:
            return
        case .scheduleRetry(let delay):
            bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tryConnectFromQueue()
            }
            return
        case .cancelStaleConnection:
            central.cancelPeripheralConnection(peripheral)
            return
        case .connectNow:
            beginCentralConnection(candidate, using: central, logPrefix: "📱 Connect")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let peripheralID = peripheral.identifier.uuidString
        
        // Update state to connected
        linkStateStore.markConnected(peripheral)
        
        // Reset backoff state on success
        connectionScheduler.recordConnectionSuccess(peripheralID: peripheralID)

        SecureLogger.debug("✅ Connected: \(peripheral.name ?? "Unknown") [\(peripheralID)]", category: .session)
        
        // Discover services
        peripheral.discoverServices([BLEService.serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peripheralID = peripheral.identifier.uuidString
        
        // Find the peer ID if we have it
        let peerID = linkStateStore.peerID(forPeripheralID: peripheralID)
        
        SecureLogger.debug("📱 Disconnect: \(peerID?.id ?? peripheralID)\(error != nil ? " (\(error!.localizedDescription))" : "")", category: .session)

        // If disconnect carried an error (often timeout), apply short backoff to avoid thrash
        if error != nil {
            connectionScheduler.recordDisconnectError(peripheralID: peripheralID, at: Date())
        }
        
        // Clean up references and peer mappings
        _ = linkStateStore.removePeripheral(peripheralID)
        if let peerID {
            // Do not remove peer; mark as not connected but retain for reachability
            collectionsQueue.sync(flags: .barrier) {
                peerRegistry.markDisconnected(peerID)
            }
            refreshLocalTopology()
        }

        
        // Restart scanning with allow duplicates for faster rediscovery
        if centralManager?.state == .poweredOn {
            // Stop and restart scanning to ensure we get fresh discovery events
            centralManager?.stopScan()
            bleQueue.asyncAfter(deadline: .now() + TransportConfig.bleRestartScanDelaySeconds) { [weak self] in
                self?.startScanning()
            }
        }
        // Attempt to fill freed slot from queue
        bleQueue.async { [weak self] in self?.tryConnectFromQueue() }
        
        // Notify delegate about disconnection on main thread (direct link dropped)
        notifyUI { [weak self] in
            guard let self = self else { return }
            
            // Get current peer list (after removal)
            let currentPeerIDs = self.collectionsQueue.sync { self.peerRegistry.peerIDs }
            
            if let peerID {
                self.notifyPeerDisconnectedDebounced(peerID)
            }
            self.requestPeerDataPublish()
            self.deliverTransportEvent(.peerListUpdated(currentPeerIDs))
        }
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let peripheralID = peripheral.identifier.uuidString
        
        // Clean up the references
        _ = linkStateStore.removePeripheral(peripheralID)
        
        SecureLogger.error("❌ Failed to connect to peripheral: \(peripheral.name ?? "Unknown") [\(peripheralID)] - Error: \(error?.localizedDescription ?? "Unknown")", category: .session)
        connectionScheduler.recordConnectionFailure(peripheralID: peripheralID)
        // Try next candidate
        bleQueue.async { [weak self] in self?.tryConnectFromQueue() }
    }
}

// MARK: - Connection scheduling helpers
private extension BLEExistingConnectionState {
    init(_ state: BLEPeripheralLinkState) {
        self.init(
            isConnecting: state.isConnecting,
            isConnected: state.isConnected,
            lastConnectionAttempt: state.lastConnectionAttempt
        )
    }
}

private extension CBPeripheralState {
    var connectionSchedulerState: BLEPeripheralConnectionState {
        switch self {
        case .connected:
            return .connected
        case .connecting:
            return .connecting
        case .disconnected, .disconnecting:
            return .disconnected
        @unknown default:
            return .disconnected
        }
    }
}

extension BLEService {
    private func tryConnectFromQueue() {
        guard let central = centralManager, central.state == .poweredOn else { return }

        let decision = connectionScheduler.nextCandidate(
            connectedOrConnectingCount: linkStateStore.connectedOrConnectingPeripheralCount,
            isAlreadyConnectingOrConnected: { [linkStateStore] peripheralID in
                let state = linkStateStore.state(forPeripheralID: peripheralID)
                return state?.isConnected == true || state?.isConnecting == true
            },
            now: Date()
        )

        switch decision {
        case .none:
            return
        case .retryAfter(let delay):
            bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tryConnectFromQueue() }
        case .connect(let candidate):
            beginCentralConnection(candidate, using: central, logPrefix: "⏩ Queue connect")
        }
    }

    private func beginCentralConnection(
        _ candidate: BLEConnectionCandidate<CBPeripheral>,
        using central: CBCentralManager,
        logPrefix: String
    ) {
        let peripheral = candidate.peripheral
        let peripheralID = candidate.peripheralID
        linkStateStore.beginConnecting(to: peripheral, at: Date())
        peripheral.delegate = self
        let options: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ]
        central.connect(peripheral, options: options)
        connectionScheduler.recordConnectionAttempt(at: Date())
        SecureLogger.debug("\(logPrefix): \(candidate.name) [RSSI:\(candidate.rssi)]", category: .session)

        bleQueue.asyncAfter(deadline: .now() + TransportConfig.bleConnectTimeoutSeconds) { [weak self] in
            guard let self = self,
                  let state = self.linkStateStore.state(forPeripheralID: peripheralID),
                  state.isConnecting && !state.isConnected else { return }

            guard peripheral.state != .connected else {
                SecureLogger.debug("⏱️ Timeout fired but peripheral already connected: \(candidate.name)", category: .session)
                return
            }

            SecureLogger.debug("⏱️ Timeout: \(candidate.name)", category: .session)
            central.cancelPeripheralConnection(peripheral)
            _ = self.linkStateStore.removePeripheral(peripheralID)
            self.connectionScheduler.recordConnectionTimeout(peripheralID: peripheralID, at: Date())
            self.tryConnectFromQueue()
        }
    }
}

private extension BLEService {
    static func shouldRediscoverBitChatService(
        invalidatedServiceUUIDs: [CBUUID],
        cachedServiceUUIDs: [CBUUID]?
    ) -> Bool {
        invalidatedServiceUUIDs.contains(serviceUUID) || cachedServiceUUIDs?.contains(serviceUUID) != true
    }
}

#if DEBUG
// Test-only helper to inject packets into the receive pipeline
extension BLEService {
    func _test_handlePacket(_ packet: BitchatPacket, fromPeerID: PeerID, preseedPeer: Bool = true, signingPublicKey: Data? = nil) {
        if preseedPeer {
            // Ensure the synthetic peer is known and marked verified for public-message tests
            let normalizedID = PeerID(hexData: packet.senderID)
            collectionsQueue.sync(flags: .barrier) {
                if var existing = peerRegistry.info(for: normalizedID) {
                    existing.isConnected = true
                    existing.isVerifiedNickname = true
                    if let signingPublicKey { existing.signingPublicKey = signingPublicKey }
                    existing.lastSeen = Date()
                    peerRegistry.upsert(existing)
                } else {
                    peerRegistry.upsert(BLEPeerInfo(
                        peerID: normalizedID,
                        nickname: "TestPeer_\(fromPeerID.id.prefix(4))",
                        isConnected: true,
                        noisePublicKey: packet.senderID,
                        signingPublicKey: signingPublicKey,
                        isVerifiedNickname: true,
                        lastSeen: Date()
                    ))
                }
            }
        }
        handleReceivedPacket(packet, from: fromPeerID)
    }

    func _test_acceptsIngress(packet: BitchatPacket, boundPeerID: PeerID?) -> Bool {
        let claimedSenderID = PeerID(hexData: packet.senderID)
        guard case .success = BLEIngressLinkRegistry.packetContext(
            for: packet,
            claimedSenderID: claimedSenderID,
            boundPeerID: boundPeerID,
            localPeerID: myPeerID,
            directAnnounceTTL: messageTTL
        ) else {
            return false
        }
        return true
    }

    func _test_recordIngressIfNew(packet: BitchatPacket, linkID: String) -> Bool {
        recordIngressIfNew(packet, link: .central(linkID), peerID: PeerID(hexData: packet.senderID))
    }

    static func _test_shouldRediscoverBitChatService(
        invalidatedServiceUUIDs: [CBUUID],
        cachedServiceUUIDs: [CBUUID]?
    ) -> Bool {
        shouldRediscoverBitChatService(
            invalidatedServiceUUIDs: invalidatedServiceUUIDs,
            cachedServiceUUIDs: cachedServiceUUIDs
        )
    }
}
#endif

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            SecureLogger.error("❌ Error discovering services for \(peripheral.name ?? "Unknown"): \(error.localizedDescription)", category: .session)
            // Retry service discovery after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard peripheral.state == .connected else { return }
                peripheral.discoverServices([BLEService.serviceUUID])
            }
            return
        }
        
        guard let services = peripheral.services else {
            SecureLogger.warning("⚠️ No services discovered for \(peripheral.name ?? "Unknown")", category: .session)
            return
        }
        
        guard let service = services.first(where: { $0.uuid == BLEService.serviceUUID }) else {
            // Not a BitChat peer - disconnect
            centralManager?.cancelPeripheralConnection(peripheral)
            return
        }
        
        // Discovering BLE characteristics
        peripheral.discoverCharacteristics([BLEService.characteristicUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            SecureLogger.error("❌ Error discovering characteristics for \(peripheral.name ?? "Unknown"): \(error.localizedDescription)", category: .session)
            return
        }
        
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == BLEService.characteristicUUID }) else {
            SecureLogger.warning("⚠️ No matching characteristic found for \(peripheral.name ?? "Unknown")", category: .session)
            return
        }
        
        // Found characteristic
        
        // Log characteristic properties for debugging
        var properties: [String] = []
        if characteristic.properties.contains(.read) { properties.append("read") }
        if characteristic.properties.contains(.write) { properties.append("write") }
        if characteristic.properties.contains(.writeWithoutResponse) { properties.append("writeWithoutResponse") }
        if characteristic.properties.contains(.notify) { properties.append("notify") }
        if characteristic.properties.contains(.indicate) { properties.append("indicate") }
        // Characteristic properties: \(properties.joined(separator: ", "))
        
        // Verify characteristic supports reliable writes
        if !characteristic.properties.contains(.write) {
            SecureLogger.warning("⚠️ Characteristic doesn't support reliable writes (withResponse)!", category: .session)
        }
        
        // Store characteristic in our consolidated structure
        let peripheralID = peripheral.identifier.uuidString
        linkStateStore.updateCharacteristic(characteristic, forPeripheralID: peripheralID)
        
        // Subscribe for notifications
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
            SecureLogger.debug("🔔 Subscribed to notifications from \(peripheral.name ?? "Unknown")", category: .session)
            
            // Send announce after subscription is confirmed (force send for new connection)
            messageQueue.asyncAfter(deadline: .now() + TransportConfig.blePostSubscribeAnnounceDelaySeconds) { [weak self] in
                self?.sendAnnounce(forceSend: true)
                // Try flushing any spooled directed packets now that we have a link
                self?.flushDirectedSpool()
            }
        } else {
            SecureLogger.warning("⚠️ Characteristic does not support notifications", category: .session)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            SecureLogger.error("❌ Error receiving notification: \(error.localizedDescription)", category: .session)
            return
        }
        
        guard let data = characteristic.value, !data.isEmpty else {
            SecureLogger.warning("⚠️ No data in notification", category: .session)
            return
        }

        bufferNotificationChunk(data, from: peripheral)
    }

    private func bufferNotificationChunk(_ chunk: Data, from peripheral: CBPeripheral) {
        let peripheralUUID = peripheral.identifier.uuidString

        var state = linkStateStore.state(forPeripheralID: peripheralUUID) ?? BLEPeripheralLinkState(
            peripheral: peripheral,
            characteristic: nil,
            peerID: nil,
            isConnecting: false,
            isConnected: peripheral.state == .connected,
            lastConnectionAttempt: nil,
            assembler: NotificationStreamAssembler()
        )

        var assembler = state.assembler
        let result = assembler.append(chunk)
        state.assembler = assembler
        linkStateStore.setPeripheralState(state, for: peripheralUUID)

        for byte in result.droppedPrefixes {
            SecureLogger.warning("⚠️ Dropping byte from BLE stream (unexpected prefix \(String(format: "%02x", byte)))", category: .session)
        }

        if result.reset {
            SecureLogger.error("❌ Invalid BLE frame length; reset notification stream", category: .session)
        }
        
        // Codex review identified TOCTOU in this patch.
        // Enforce per-link sender binding immediately within the same notification batch.
        // NOTE: `processNotificationPacket` may bind the stored peer ID when an announce
        // is processed, but `state` above is a snapshot. Track a local binding that we update as soon as
        // we see a binding-eligible announce so subsequent frames can't spoof a different sender.
        var boundPeerID: PeerID? = state.peerID

        for frame in result.frames {
            guard let packet = BinaryProtocol.decode(frame) else {
                let prefix = frame.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                SecureLogger.error("❌ Failed to decode assembled notification frame (len=\(frame.count), prefix=\(prefix))", category: .session)
                continue
            }

            let claimedSenderID = PeerID(hexData: packet.senderID)
            let context = acceptedIngressContext(
                for: packet,
                claimedSenderID: claimedSenderID,
                boundPeerID: boundPeerID,
                linkDescription: "Peripheral \(peripheralUUID.prefix(8))…"
            )

            guard let context else { continue }

            // If this is a direct-link announce, bind immediately for the remainder of this batch.
            if boundPeerID == nil,
               packet.type == MessageType.announce.rawValue,
               packet.ttl == messageTTL {
                boundPeerID = claimedSenderID
                state.peerID = claimedSenderID
                linkStateStore.bindPeripheral(peripheralUUID, to: claimedSenderID)
            }

            if !recordIngressIfNew(packet, link: .peripheral(peripheralUUID), peerID: context.receivedFromPeerID) {
                continue
            }
            processNotificationPacket(
                packet,
                from: peripheral,
                peripheralUUID: peripheralUUID,
                receivedFrom: context.receivedFromPeerID
            )
        }
    }

    private func processNotificationPacket(_ packet: BitchatPacket, from peripheral: CBPeripheral, peripheralUUID: String, receivedFrom peerID: PeerID) {
        let senderID = PeerID(hexData: packet.senderID)

        if packet.type != MessageType.announce.rawValue {
            SecureLogger.debug("📦 Decoded notification packet type: \(packet.type) from sender: \(senderID.id.prefix(8))…", category: .session)
        }

        if packet.type == MessageType.announce.rawValue {
            if packet.ttl == messageTTL {
                linkStateStore.bindPeripheral(peripheralUUID, to: senderID)
                refreshLocalTopology()
            }

            handleReceivedPacket(packet, from: peerID)
        } else {
            handleReceivedPacket(packet, from: peerID)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            SecureLogger.error("❌ Write failed to \(peripheral.name ?? peripheral.identifier.uuidString): \(error.localizedDescription)", category: .session)
            // Don't retry - just log the error
        } else {
            SecureLogger.debug("✅ Write confirmed to \(peripheral.name ?? peripheral.identifier.uuidString)", category: .session)
        }
    }
    
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Resume queued writes for this peripheral - called when canSendWriteWithoutResponse becomes true again
        if logRateLimiter.shouldLog(key: "peripheral-ready:\(peripheral.identifier.uuidString)") {
            SecureLogger.debug("📤 Peripheral \(peripheral.name ?? peripheral.identifier.uuidString.prefix(8).description) ready for more writes", category: .session)
        }
        drainPendingWrites(for: peripheral)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        SecureLogger.warning("⚠️ Services modified for \(peripheral.name ?? peripheral.identifier.uuidString)", category: .session)

        let shouldRediscover = BLEService.shouldRediscoverBitChatService(
            invalidatedServiceUUIDs: invalidatedServices.map(\.uuid),
            cachedServiceUUIDs: peripheral.services?.map(\.uuid)
        )

        guard shouldRediscover else { return }

        let peripheralID = peripheral.identifier.uuidString
        linkStateStore.updatePeripheral(peripheralID) {
            $0.characteristic = nil
            $0.assembler = NotificationStreamAssembler()
        }

        SecureLogger.debug("🔄 BitChat service changed for \(peripheral.name ?? peripheral.identifier.uuidString), rediscovering", category: .session)
        peripheral.discoverServices([BLEService.serviceUUID])
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            SecureLogger.error("❌ Error updating notification state: \(error.localizedDescription)", category: .session)
        } else {
            SecureLogger.debug("🔔 Notification state updated for \(peripheral.name ?? peripheral.identifier.uuidString): \(characteristic.isNotifying ? "ON" : "OFF")", category: .session)
            
            // If notifications are now on, send an announce to ensure this peer knows about us
            if characteristic.isNotifying {
                // Sending announce after subscription
                self.sendAnnounce(forceSend: true)
            }
        }
    }

}

// MARK: - CBPeripheralManagerDelegate

extension BLEService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        SecureLogger.debug("📡 Peripheral manager state: \(peripheral.state.rawValue)", category: .session)

        switch peripheral.state {
        case .poweredOn:
            // Remove all services first to ensure clean state
            peripheral.removeAllServices()

            // Create characteristic
            characteristic = CBMutableCharacteristic(
                type: BLEService.characteristicUUID,
                properties: [.notify, .write, .writeWithoutResponse, .read],
                value: nil,
                permissions: [.readable, .writeable]
            )

            // Create service
            let service = CBMutableService(type: BLEService.serviceUUID, primary: true)
            service.characteristics = [characteristic!]

            // Add service (advertising will start in didAdd delegate)
            SecureLogger.debug("🔧 Adding BLE service...", category: .session)
            peripheral.add(service)

        case .poweredOff:
            // Bluetooth was turned off - clean up peripheral state
            SecureLogger.info("📴 Bluetooth powered off - cleaning up peripheral state", category: .session)
            peripheral.stopAdvertising()
            // Clear subscribed centrals (they are now invalid)
            let centralPeerIDs = linkStateStore.clearCentrals()
            subscriptionAnnounceLimiter.removeAll()
            characteristic = nil
            // Notify UI of disconnections
            for peerID in centralPeerIDs {
                notifyUI { [weak self] in
                    self?.notifyPeerDisconnectedDebounced(peerID)
                }
            }

        case .unauthorized:
            // User denied Bluetooth permission
            SecureLogger.warning("🚫 Bluetooth unauthorized for peripheral role", category: .session)
            peripheral.stopAdvertising()
            _ = linkStateStore.clearCentrals()
            subscriptionAnnounceLimiter.removeAll()
            characteristic = nil

        case .unsupported:
            // Device doesn't support BLE peripheral role
            SecureLogger.error("❌ Bluetooth LE peripheral role not supported", category: .session)

        case .resetting:
            // Bluetooth stack is resetting
            SecureLogger.info("🔄 Bluetooth peripheral stack resetting...", category: .session)

        case .unknown:
            SecureLogger.debug("❓ Peripheral Bluetooth state unknown (initializing)", category: .session)

        @unknown default:
            SecureLogger.warning("⚠️ Unknown peripheral Bluetooth state: \(peripheral.state.rawValue)", category: .session)
        }
    }
    
    #if os(iOS)
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
        let restoredServices = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        let restoredAdvertisement = (dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any]) ?? [:]

        SecureLogger.info(
            "♻️ Peripheral restore: services=\(restoredServices.count) advertisingDataKeys=\(Array(restoredAdvertisement.keys))",
            category: .session
        )

        // Attempt to recover characteristic from restored services
        if characteristic == nil {
            if let service = restoredServices.first(where: { $0.uuid == BLEService.serviceUUID }),
               let restoredCharacteristic = service.characteristics?.first(where: { $0.uuid == BLEService.characteristicUUID }) as? CBMutableCharacteristic {
                characteristic = restoredCharacteristic
            }
        }

        captureBluetoothStatus(context: "peripheral-restore")

        if peripheral.state == .poweredOn && !peripheral.isAdvertising {
            peripheral.startAdvertising(buildAdvertisementData())
        }
    }
    #endif
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            SecureLogger.error("❌ Failed to add service: \(error.localizedDescription)", category: .session)
            return
        }
        
        SecureLogger.debug("✅ Service added successfully, starting advertising", category: .session)
        
        // Start advertising after service is confirmed added
        let adData = buildAdvertisementData()
        peripheral.startAdvertising(adData)
        
        SecureLogger.debug("📡 Started advertising (LocalName: \((adData[CBAdvertisementDataLocalNameKey] as? String) != nil ? "on" : "off"), ID: \(myPeerID.id.prefix(8))…)", category: .session)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        let centralUUID = central.identifier.uuidString
        SecureLogger.debug("📥 Central subscribed: \(centralUUID.prefix(8))…", category: .session)
        linkStateStore.addSubscribedCentral(central)

        // BCH-01-004: Rate-limit subscription-triggered announces to prevent enumeration attacks
        let now = Date()
        switch subscriptionAnnounceLimiter.decision(for: centralUUID, now: now) {
        case .allowed:
            break
        case let .rateLimited(backoffSeconds, attemptCount, suppressAnnounce):
            SecureLogger.warning("🛡️ BCH-01-004: Rate-limited announce for central \(centralUUID.prefix(8))... (backoff: \(Int(backoffSeconds))s, attempts: \(attemptCount))", category: .security)
            if suppressAnnounce {
                SecureLogger.warning("🚨 BCH-01-004: Possible enumeration attack from central \(centralUUID.prefix(8))... - suppressing announce", category: .security)
                return
            }

            // Still flush directed packets for legitimate mesh operation
            messageQueue.asyncAfter(deadline: .now() + TransportConfig.blePostAnnounceDelaySeconds) { [weak self] in
                self?.flushDirectedSpool()
            }
            return
        }

        // Send announce to the newly subscribed central after a small delay
        messageQueue.asyncAfter(deadline: .now() + TransportConfig.blePostAnnounceDelaySeconds) { [weak self] in
            self?.sendAnnounce(forceSend: true)
            // Flush any spooled directed packets now that we have a central subscribed
            self?.flushDirectedSpool()
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        SecureLogger.debug("📤 Central unsubscribed: \(central.identifier.uuidString.prefix(8))…", category: .session)
        let removedPeerID = linkStateStore.removeSubscribedCentral(central)
        
        // Ensure we're still advertising for other devices to find us
        if peripheral.isAdvertising == false {
            SecureLogger.debug("📡 Restarting advertising after central unsubscribed", category: .session)
            peripheral.startAdvertising(buildAdvertisementData())
        }
        
        // Find and disconnect the peer associated with this central
        if let peerID = removedPeerID {
            // Mark peer as not connected; retain for reachability
            collectionsQueue.sync(flags: .barrier) {
                peerRegistry.markDisconnected(peerID)
            }
            
            refreshLocalTopology()
            
            // Update UI immediately
            notifyUI { [weak self] in
                guard let self = self else { return }
                
                // Get current peer list (after removal)
                let currentPeerIDs = self.collectionsQueue.sync { self.peerRegistry.peerIDs }
                
                self.notifyPeerDisconnectedDebounced(peerID)
                // Publish snapshots so UnifiedPeerService can refresh icons promptly
                self.requestPeerDataPublish()
                self.deliverTransportEvent(.peerListUpdated(currentPeerIDs))
            }
        }
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drainPendingNotifications(logPrefix: "✅ Sent")
    }

    private func logBackpressureSampled(_ message: @autoclosure () -> String) {
        notificationBackpressureLogCount += 1
        if notificationBackpressureLogCount == 1 ||
            notificationBackpressureLogCount.isMultiple(of: TransportConfig.bleBackpressureLogInterval) {
            SecureLogger.debug("\(message()) [backpressure event #\(notificationBackpressureLogCount)]", category: .session)
        }
    }

    private func drainPendingNotifications(logPrefix: String) {
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self,
                  let characteristic = self.characteristic,
                  !self.pendingNotifications.isEmpty else { return }

            let pending = self.pendingNotifications.takeAll()
            let sentCount = self.sendPendingNotifications(pending, characteristic: characteristic)

            if sentCount > 0 {
                self.logBackpressureSampled("\(logPrefix) \(sentCount) pending notifications from retry queue (\(self.pendingNotifications.count) still pending)")
            }
        }
    }

    private func sendPendingNotifications(_ pending: [BLEPendingNotification<CBCentral>], characteristic: CBMutableCharacteristic) -> Int {
        var sentCount = 0

        for (index, notification) in pending.enumerated() {
            let success = peripheralManager?.updateValue(
                notification.data,
                for: characteristic,
                onSubscribedCentrals: notification.targets
            ) ?? false

            guard success else {
                let remaining = Array(pending.dropFirst(index))
                pendingNotifications.prepend(remaining)
                logBackpressureSampled("⚠️ Notification queue still full after \(sentCount) sent, re-queuing \(remaining.count) items")
                break
            }

            sentCount += 1
        }

        return sentCount
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Suppress logs for single write requests to reduce noise
        if requests.count > 1 {
            SecureLogger.debug("📥 Received \(requests.count) write requests from central", category: .session)
        }
        
        // IMPORTANT: Respond immediately to prevent timeouts!
        // We must respond within a few milliseconds or the central will timeout
        for request in requests {
            peripheral.respond(to: request, withResult: .success)
        }
        
        // Process writes. For long writes, CoreBluetooth may deliver multiple CBATTRequest values with offsets.
        // Combine per-central request values by offset before decoding.
        // Process directly on our message queue to match transport context
        let grouped = Dictionary(grouping: requests, by: { $0.central.identifier.uuidString })
        for (centralUUID, group) in grouped {
            // Sort by offset ascending
            let sorted = group.sorted { $0.offset < $1.offset }
            let hasMultiple = sorted.count > 1 || (sorted.first?.offset ?? 0) > 0
            let chunks = sorted.compactMap { request -> BLEInboundWriteChunk? in
                guard let data = request.value, !data.isEmpty else { return nil }
                return BLEInboundWriteChunk(offset: request.offset, data: data)
            }

            let result = pendingWriteBuffers.append(
                chunks: chunks,
                for: centralUUID,
                capBytes: TransportConfig.blePendingWriteBufferCapBytes
            )

            switch result {
            case let .decoded(packet, metadata):
                logAccumulatedCentralWrite(metadata, centralUUID: centralUUID)
                processDecodedCentralWrite(packet, centralUUID: centralUUID, central: sorted[0].central)

            case let .waiting(metadata):
                logAccumulatedCentralWrite(metadata, centralUUID: centralUUID)
                logFailedSingleWriteIfNeeded(hasMultiple: hasMultiple, sortedRequests: sorted)

            case let .oversized(metadata):
                logAccumulatedCentralWrite(metadata, centralUUID: centralUUID)
                SecureLogger.warning("⚠️ Dropping oversized pending write buffer (\(metadata.accumulatedBytes) bytes) for central \(centralUUID.prefix(8))…", category: .session)
                logFailedSingleWriteIfNeeded(hasMultiple: hasMultiple, sortedRequests: sorted)
            }
        }
    }

    private func logAccumulatedCentralWrite(_ metadata: BLEInboundWriteAppendMetadata, centralUUID: String) {
        guard let packetType = metadata.packetType,
              packetType != MessageType.announce.rawValue else { return }

        SecureLogger.debug(
            "📥 Accumulated write from central \(centralUUID.prefix(8))…: size=\(metadata.accumulatedBytes) (+\(metadata.appendedBytes)) bytes (type=\(packetType)), offsets=\(metadata.offsets)",
            category: .session
        )
    }

    private func logFailedSingleWriteIfNeeded(hasMultiple: Bool, sortedRequests: [CBATTRequest]) {
        guard !hasMultiple, let raw = sortedRequests.first?.value else { return }

        let prefix = raw.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
        SecureLogger.error("❌ Failed to decode packet from central (len=\(raw.count), prefix=\(prefix))", category: .session)
    }

    private func processDecodedCentralWrite(_ packet: BitchatPacket, centralUUID: String, central: CBCentral) {
        let claimedSenderID = PeerID(hexData: packet.senderID)
        let context = acceptedIngressContext(
            for: packet,
            claimedSenderID: claimedSenderID,
            boundPeerID: linkStateStore.peerID(forCentralUUID: centralUUID),
            linkDescription: "Central \(centralUUID.prefix(8))…"
        )
        guard let context else { return }

        if packet.type != MessageType.announce.rawValue {
            SecureLogger.debug("📦 Decoded (combined) packet type: \(packet.type) from sender: \(claimedSenderID.id.prefix(8))…", category: .session)
        }

        linkStateStore.addSubscribedCentral(central)

        if packet.type == MessageType.announce.rawValue,
           packet.ttl == messageTTL {
            linkStateStore.bindCentral(centralUUID, to: claimedSenderID)
            refreshLocalTopology()
        }

        guard recordIngressIfNew(packet, link: .central(centralUUID), peerID: context.receivedFromPeerID) else {
            return
        }

        handleReceivedPacket(packet, from: context.receivedFromPeerID)
    }
}

// MARK: - Advertising Builders & Alias Rotation

extension BLEService {
    private func buildAdvertisementData() -> [String: Any] {
        let data: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [BLEService.serviceUUID]
        ]
        // No Local Name for privacy
        return data
    }
    
    // No alias rotation or advertising restarts required.
}

// MARK: - Private Helpers

extension BLEService {
    
    /// Notify UI on the MainActor to satisfy Swift concurrency isolation
    private func notifyUI(_ block: @escaping @MainActor () -> Void) {
        // Always hop onto the MainActor so calls to @MainActor delegates are safe
        Task { @MainActor in
            block()
        }
    }

    private func emitTransportEvent(_ event: TransportEvent) {
        notifyUI { [weak self] in
            self?.deliverTransportEvent(event)
        }
    }

    @MainActor
    private func deliverTransportEvent(_ event: TransportEvent) {
        if let eventDelegate {
            eventDelegate.didReceiveTransportEvent(event)
        } else {
            delegate?.receiveTransportEvent(event)
        }
    }

    private func logBluetoothStatus(_ context: String) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureBluetoothStatus(context: context)
        }
    }

    private func scheduleBluetoothStatusSample(after delay: TimeInterval, context: String) {
        bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.captureBluetoothStatus(context: context)
        }
    }

    private func captureBluetoothStatus(context: String) {
        assert(DispatchQueue.getSpecific(key: bleQueueKey) != nil, "captureBluetoothStatus must run on bleQueue")

        let centralState = centralManager?.state ?? .unknown
        let isScanning = centralManager?.isScanning ?? false
        let peripheralState = peripheralManager?.state ?? .unknown
        let isAdvertising = peripheralManager?.isAdvertising ?? false

        let peerSummary = collectionsQueue.sync {
            (
                connected: peerRegistry.connectedCount,
                known: peerRegistry.count,
                candidates: connectionScheduler.candidateCount
            )
        }

        #if os(iOS)
        var backgroundDescriptor = ""
        var backgroundSeconds: TimeInterval = 0
        DispatchQueue.main.sync {
            backgroundSeconds = UIApplication.shared.backgroundTimeRemaining
        }
        if backgroundSeconds == .greatestFiniteMagnitude {
            backgroundDescriptor = " bgRemaining=∞"
        } else {
            backgroundDescriptor = String(format: " bgRemaining=%.1fs", backgroundSeconds)
        }
        let appPhase = isAppActive ? "foreground" : "background"
        #else
        let backgroundDescriptor = ""
        let appPhase = "foreground"
        #endif

        SecureLogger.info(
            "📊 BLE status [\(context)]: phase=\(appPhase) central=\(centralState) scanning=\(isScanning) peripheral=\(peripheralState) advertising=\(isAdvertising) connected=\(peerSummary.connected) known=\(peerSummary.known) candidates=\(peerSummary.candidates)\(backgroundDescriptor)",
            category: .session
        )
    }

    private func routingData(for peerID: PeerID) -> Data? {
        peerID.toShort().routingData
    }

    private func refreshLocalTopology() {
        let neighbors: [Data] = collectionsQueue.sync {
            peerRegistry.connectedRoutingData
        }
        meshTopology.updateNeighbors(for: myPeerIDData, neighbors: neighbors)
    }

    private func computeRoute(to peerID: PeerID) -> [Data]? {
        meshTopology.computeRoute(from: myPeerIDData, to: routingData(for: peerID))
    }

    private func applyRouteIfAvailable(_ packet: BitchatPacket, to recipient: PeerID) -> BitchatPacket {
        guard let route = computeRoute(to: recipient), route.count >= 1 else {
            return packet
        }
        // Create new packet with route applied and version upgraded to 2
        let routedPacket = BitchatPacket(
            type: packet.type,
            senderID: packet.senderID,
            recipientID: packet.recipientID,
            timestamp: packet.timestamp,
            payload: packet.payload,
            signature: nil, // Will be re-signed below
            ttl: packet.ttl,
            version: 2,
            route: route
        )
        // Re-sign the packet since route and version changed
        guard let signedPacket = noiseService.signPacket(routedPacket) else {
            SecureLogger.error("❌ Failed to re-sign packet with route", category: .security)
            return packet // Return original packet if signing fails
        }
        return signedPacket
    }

    private func routingPeer(from data: Data) -> PeerID? {
        PeerID(routingData: data)
    }

    private func forwardAlongRouteIfNeeded(_ packet: BitchatPacket) -> Bool {
        let myRoutingData = routingData(for: myPeerID) ?? (myPeerIDData.isEmpty ? nil : myPeerIDData)
        let plan = BLERouteForwardingPolicy.plan(
            for: packet,
            localPeerID: myPeerID,
            localRoutingData: myRoutingData,
            routingPeer: routingPeer(from:),
            isPeerConnected: isPeerConnected(_:)
        )

        if let forwardPacket = plan.forwardPacket, let nextHop = plan.nextHop {
            sendPacketDirected(forwardPacket, to: nextHop)
        }

        return plan.shouldSuppressFloodRelay
    }

    /// Safely fetch the current direct-link state for a peer using the BLE queue.
    private func linkState(for peerID: PeerID) -> (hasPeripheral: Bool, hasCentral: Bool) {
        let state = readLinkState { $0.directLinkState(for: peerID) }
        return (state.hasPeripheral, state.hasCentral)
    }

    private func links(to peerID: PeerID?) -> Set<BLEIngressLinkID> {
        readLinkState { $0.links(to: peerID) }
    }
    
    private func configureNoiseServiceCallbacks(for service: NoiseEncryptionService) {
        service.onPeerAuthenticated = { [weak self] peerID, fingerprint in
            SecureLogger.debug("🔐 Noise session authenticated with \(peerID.id.prefix(8))…, fingerprint: \(fingerprint.prefix(16))…")
            self?.messageQueue.async { [weak self] in
                self?.sendPendingMessagesAfterHandshake(for: peerID)
                self?.sendPendingNoisePayloadsAfterHandshake(for: peerID)
            }
            self?.messageQueue.async { [weak self] in
                self?.sendAnnounce(forceSend: true)
            }
        }
    }

    /// Swaps `myPeerID`/`myPeerIDData` to match the current Noise identity.
    /// The swap runs as a `messageQueue` barrier so in-flight work items that
    /// read the identity (e.g. `sendMessage` building packets) complete
    /// against the old value and everything after sees the new one atomically.
    /// Callers (init, panic reset on the main thread) are never on
    /// `messageQueue`; the re-entrancy check keeps any future on-queue caller
    /// from deadlocking.
    private func refreshPeerIdentity() {
        let swap = {
            let fingerprint = self.noiseService.getIdentityFingerprint()
            self.myPeerID = PeerID(str: fingerprint.prefix(16))
            self.myPeerIDData = Data(hexString: self.myPeerID.id) ?? Data()
            self.meshTopology.reset()
        }
        if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
            swap()
        } else {
            messageQueue.sync(flags: .barrier, execute: swap)
        }
    }


    
    private func sendNoisePayload(_ typedPayload: Data, to peerID: PeerID) {
        guard noiseService.hasSession(with: peerID) else {
            // No session yet - queue the payload SYNCHRONOUSLY before initiating handshake
            // to prevent race where fast handshake completion drains empty queue
            collectionsQueue.sync(flags: .barrier) {
                self.pendingNoiseSessionQueues.appendTypedPayload(typedPayload, for: peerID)
                SecureLogger.debug("📥 Queued noise payload for \(peerID.id.prefix(8))… pending handshake", category: .session)
            }
            initiateNoiseHandshake(with: peerID)
            return
        }
        do {
            broadcastPacket(try makeEncryptedNoisePacket(typedPayload, to: peerID))
        } catch {
            SecureLogger.error("Failed to send verification payload: \(error)")
        }
    }

    private func makeEncryptedNoisePacket(_ typedPayload: Data, to peerID: PeerID) throws -> BitchatPacket {
        let encrypted = try noiseService.encrypt(typedPayload, for: peerID)
        return BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: myPeerIDData,
            recipientID: Data(hexString: peerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: encrypted,
            signature: nil,
            ttl: messageTTL
        )
    }
    
    // MARK: Link capability snapshots (thread-safe via bleQueue)

    private func readLinkState<T>(_ body: (BLELinkStateStore) -> T) -> T {
        if DispatchQueue.getSpecific(key: bleQueueKey) != nil {
            return body(linkStateStore)
        } else {
            return bleQueue.sync { body(linkStateStore) }
        }
    }

    private func snapshotDirectPeripheralState(for peerID: PeerID) -> BLEPeripheralLinkState? {
        readLinkState { $0.directPeripheralState(for: peerID) }
    }

    private func snapshotPeripheralStates() -> [BLEPeripheralLinkState] {
        readLinkState(\.peripheralStates)
    }

    private func snapshotSubscribedCentrals() -> BLESubscribedCentralSnapshot {
        readLinkState(\.subscribedCentralSnapshot)
    }
    
    // MARK: Helpers: IDs, selection, and write backpressure
    
    private func writeOrEnqueue(_ data: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic, priority: BLEOutboundWritePriority) {
        // BLE operations run on bleQueue; keep queue affinity
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            let uuid = peripheral.identifier.uuidString
            if peripheral.canSendWriteWithoutResponse {
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            } else {
                self.collectionsQueue.async(flags: .barrier) {
                    let result = self.pendingPeripheralWrites.enqueue(
                        data: data,
                        for: uuid,
                        priority: priority,
                        capBytes: TransportConfig.blePendingWriteBufferCapBytes
                    )

                    switch result {
                    case .oversized(let bytes):
                        SecureLogger.warning("⚠️ Dropping oversized write chunk (\(bytes)B) for peripheral \(uuid)", category: .session)
                    case let .enqueued(trimmedBytes, remainingBytes) where trimmedBytes > 0:
                        SecureLogger.warning("📉 Trimmed pending write buffer for \(uuid) by \(trimmedBytes)B to \(remainingBytes)B", category: .session)
                    case .enqueued:
                        break
                    }
                }
            }
        }
    }

    private func drainPendingWrites(for peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard let state = self.linkStateStore.state(forPeripheralID: uuid), let ch = state.characteristic else { return }

            // Atomically take all pending items from the queue to avoid race conditions
            // where new items could be enqueued between read and update
            let itemsToSend: [BLEPendingWrite] = self.collectionsQueue.sync(flags: .barrier) {
                self.pendingPeripheralWrites.takeAll(for: uuid)
            }
            guard !itemsToSend.isEmpty else { return }

            // Send as many as possible
            var sent = 0
            for item in itemsToSend {
                if peripheral.canSendWriteWithoutResponse {
                    peripheral.writeValue(item.data, for: ch, type: .withoutResponse)
                    sent += 1
                } else {
                    break
                }
            }

            // Re-enqueue any items that couldn't be sent (maintaining order)
            let unsent = Array(itemsToSend.dropFirst(sent))
            if !unsent.isEmpty {
                self.collectionsQueue.async(flags: .barrier) {
                    self.pendingPeripheralWrites.prepend(unsent, for: uuid)
                }
            }
        }
    }

    /// Periodically try to drain pending notifications as a backup mechanism
    private func drainPendingNotificationsIfPossible() {
        drainPendingNotifications(logPrefix: "🔄 Periodic drain: sent")
    }

    /// Periodically try to drain pending writes for all connected peripherals
    private func drainAllPendingWrites() {
        let uuids = collectionsQueue.sync { pendingPeripheralWrites.peripheralIDs }
        for uuid in uuids {
            guard let state = linkStateStore.state(forPeripheralID: uuid), state.isConnected else { continue }
            drainPendingWrites(for: state.peripheral)
        }
    }

    // MARK: Application State Handlers (iOS)

    #if os(iOS)
    @objc private func appDidBecomeActive() {
        isAppActive = true
        // Restart scanning with allow duplicates when app becomes active
        if centralManager?.state == .poweredOn {
            centralManager?.stopScan()
            startScanning()
        }
        logBluetoothStatus("became-active")
        scheduleBluetoothStatusSample(after: 5.0, context: "active-5s")
        // No Local Name; nothing to refresh for advertising policy
    }
    
    @objc private func appDidEnterBackground() {
        isAppActive = false
        // Restart scanning without allow duplicates in background
        if centralManager?.state == .poweredOn {
            centralManager?.stopScan()
            startScanning()
        }
        logBluetoothStatus("entered-background")
        scheduleBluetoothStatusSample(after: 15.0, context: "background-15s")
        // No Local Name; nothing to refresh for advertising policy
    }
    #endif
    
    // MARK: Private Message Handling
    
    private func sendPrivateMessage(_ content: String, to recipientID: PeerID, messageID: String) {
        SecureLogger.debug("📨 Sending PM to \(recipientID.id.prefix(8))… id=\(messageID.prefix(8))… chars=\(content.count) bytes=\(content.utf8.count)", category: .session)
        
        // Check if we have an established Noise session
        if noiseService.hasEstablishedSession(with: recipientID) {
            // Encrypt and send
            do {
                guard let messagePayload = BLENoisePayloadFactory.privateMessage(content: content, messageID: messageID) else {
                    SecureLogger.error("Failed to encode private message with TLV")
                    return
                }
                
                broadcastPacket(try makeEncryptedNoisePacket(messagePayload, to: recipientID))
                
                // Notify delegate that message was sent
                notifyUI { [weak self] in
                    self?.deliverTransportEvent(.messageDeliveryStatusUpdated(messageID: messageID, status: .sent))
                }
            } catch {
                SecureLogger.error("Failed to encrypt message: \(error)")
            }
        } else {
            // Queue message for sending after handshake completes
            SecureLogger.debug("🤝 No session with \(recipientID.id.prefix(8))…, initiating handshake and queueing message", category: .session)
            
            // Queue the message (especially important for favorite notifications)
            collectionsQueue.sync(flags: .barrier) {
                pendingNoiseSessionQueues.appendPrivateMessage(content: content, messageID: messageID, for: recipientID)
            }
            
            initiateNoiseHandshake(with: recipientID)
            
            // Notify delegate that message is pending
            notifyUI { [weak self] in
                self?.deliverTransportEvent(.messageDeliveryStatusUpdated(messageID: messageID, status: .sending))
            }
        }
    }
    
    private func initiateNoiseHandshake(with peerID: PeerID) {
        // Use NoiseEncryptionService for handshake
        guard !noiseService.hasSession(with: peerID) else { return }
        
        do {
            let handshakeData = try noiseService.initiateHandshake(with: peerID)
            
            // Send handshake init
            let packet = BitchatPacket(
                type: MessageType.noiseHandshake.rawValue,
                senderID: myPeerIDData,
                recipientID: Data(hexString: peerID.id),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: handshakeData,
                signature: nil,
                ttl: messageTTL
            )
            broadcastPacket(packet)
        } catch {
            SecureLogger.error("Failed to initiate handshake: \(error)")
        }
    }
    
    private func sendPendingMessagesAfterHandshake(for peerID: PeerID) {
        // Atomically take all pending messages to process (prevents concurrent modification)
        let pendingMessages = collectionsQueue.sync(flags: .barrier) { () -> [BLEPendingPrivateMessage] in
            pendingNoiseSessionQueues.takePrivateMessages(for: peerID)
        }

        guard !pendingMessages.isEmpty else { return }

        SecureLogger.debug("📤 Sending \(pendingMessages.count) pending messages after handshake to \(peerID.id.prefix(8))…", category: .session)

        // Track failed messages for re-queuing
        var failedMessages: [BLEPendingPrivateMessage] = []

        // Send each pending message directly (we know session is established)
        for message in pendingMessages {
            do {
                // Use the same TLV format as normal sends to keep receiver decoding consistent
                guard let messagePayload = BLENoisePayloadFactory.privateMessage(content: message.content, messageID: message.messageID) else {
                    SecureLogger.error("Failed to encode pending private message TLV")
                    failedMessages.append(message)
                    continue
                }

                // We're already on messageQueue from the callback
                broadcastPacket(try makeEncryptedNoisePacket(messagePayload, to: peerID))

                // Notify delegate that message was sent
                notifyUI { [weak self] in
                    self?.deliverTransportEvent(.messageDeliveryStatusUpdated(messageID: message.messageID, status: .sent))
                }

                SecureLogger.debug("✅ Sent pending message id=\(message.messageID.prefix(8))… to \(peerID.id.prefix(8))… after handshake", category: .session)
            } catch {
                SecureLogger.error("Failed to send pending message after handshake: \(error)")
                failedMessages.append(message)

                // Notify delegate of failure
                notifyUI { [weak self] in
                    self?.deliverTransportEvent(.messageDeliveryStatusUpdated(messageID: message.messageID, status: .failed(reason: "Encryption failed")))
                }
            }
        }

        // Re-queue any failed messages for retry on next handshake
        if !failedMessages.isEmpty {
            collectionsQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                // Prepend failed messages to maintain order
                self.pendingNoiseSessionQueues.prependPrivateMessages(failedMessages, for: peerID)
                SecureLogger.warning("⚠️ Re-queued \(failedMessages.count) failed messages for \(peerID.id.prefix(8))…", category: .session)
            }
        }
    }
    
    // MARK: Fragmentation (Required for messages > BLE MTU)
    
    private func sendFragmentedPacket(_ packet: BitchatPacket, pad: Bool, maxChunk: Int? = nil, directedOnlyPeer: PeerID? = nil, transferId: String? = nil) {
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: pad,
            maxChunk: maxChunk,
            directedPeer: directedOnlyPeer,
            transferId: transferId
        )

        let result = collectionsQueue.sync(flags: .barrier) {
            outboundFragmentTransfers.submit(request, maxConcurrentTransfers: TransportConfig.bleMaxConcurrentTransfers)
        }
        handleFragmentTransferSubmitResult(result)
    }

    private func handleFragmentTransferSubmitResult(_ result: BLEOutboundFragmentTransferScheduler.SubmitResult) {
        switch result {
        case let .start(request, reservedTransferId):
            startFragmentedPacket(request, reservedTransferId: reservedTransferId)

        case let .queued(_, transferId, _):
            if let transferId {
                SecureLogger.debug("🚦 Queued media transfer \(transferId.prefix(8))… waiting for slot", category: .session)
            } else {
                SecureLogger.debug("🚦 Queued fragment transfer waiting for slot", category: .session)
            }
        }
    }

    private func startFragmentedPacket(_ request: BLEOutboundFragmentTransferRequest, reservedTransferId: String?) {
        let releaseReservedSlot: (String) -> Void = { [weak self] id in
            guard let self = self else { return }
            TransferProgressManager.shared.cancel(id: id)
            self.collectionsQueue.async(flags: .barrier) { [weak self] in
                _ = self?.outboundFragmentTransfers.releaseReservation(id)
            }
            self.messageQueue.async { [weak self] in
                self?.startNextPendingTransferIfNeeded()
            }
        }

        guard let plan = BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: defaultFragmentSize,
            bleMaxMTU: bleMaxMTU
        ) else {
            if let id = reservedTransferId {
                releaseReservedSlot(id)
            }
            return
        }

        // Lightweight pacing to reduce floods and allow BLE buffers to drain
        // Also briefly pause scanning during long fragment trains to save battery
        if plan.shouldPauseScanning {
            bleQueue.async { [weak self] in
                guard let self = self, let c = self.centralManager, c.state == .poweredOn else { return }
                if c.isScanning { c.stopScan() }
                let totalFragments = plan.totalFragments
                let expectedMs = min(TransportConfig.bleExpectedWriteMaxMs, totalFragments * TransportConfig.bleExpectedWritePerFragmentMs)
                self.bleQueue.asyncAfter(deadline: .now() + .milliseconds(expectedMs)) { [weak self] in
                    self?.startScanning()
                }
            }
        }

        let transferIdentifier: String? = {
            guard let id = reservedTransferId else { return nil }
            collectionsQueue.sync(flags: .barrier) {
                _ = self.outboundFragmentTransfers.activateReservedTransfer(id: id, totalFragments: plan.totalFragments, workItems: [])
            }
            TransferProgressManager.shared.start(id: id, totalFragments: plan.totalFragments)
            return id
        }()

        var scheduledItems: [(item: DispatchWorkItem, index: Int)] = []

        for (index, fragmentPacket) in plan.fragmentPackets.enumerated() {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if let transferId = transferIdentifier {
                    let isActive = self.collectionsQueue.sync { self.outboundFragmentTransfers.isActive(transferId) }
                    guard isActive else { return }
                }
                if fragmentPacket.recipientID == nil || fragmentPacket.recipientID?.allSatisfy({ $0 == 0xFF }) == true {
                    self.gossipSyncManager?.onPublicPacketSeen(fragmentPacket)
                }
                self.broadcastPacket(fragmentPacket)
                if let transferId = transferIdentifier {
                    self.markFragmentSent(transferId: transferId)
                }
            }

            scheduledItems.append((item: workItem, index: index))
        }

        if let transferId = transferIdentifier {
            let workItems = scheduledItems.map { $0.item }
            collectionsQueue.async(flags: .barrier) { [weak self] in
                _ = self?.outboundFragmentTransfers.updateWorkItems(workItems, for: transferId)
            }
        }

        for (workItem, index) in scheduledItems {
            let delayMs = index * plan.spacingMs
            messageQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: workItem)
        }
    }
    
    // MARK: - Fragmentation (Required for messages > BLE MTU)

    private func markFragmentSent(transferId: String) {
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            switch self.outboundFragmentTransfers.markFragmentSent(transferId: transferId) {
            case .progress, .complete:
                TransferProgressManager.shared.recordFragmentSent(id: transferId)

            case .missing:
                return
            }

            if !self.outboundFragmentTransfers.isActive(transferId) {
                self.messageQueue.async { [weak self] in
                    self?.startNextPendingTransferIfNeeded()
                }
            }
        }
    }

    private func startNextPendingTransferIfNeeded() {
        let results = collectionsQueue.sync(flags: .barrier) {
            outboundFragmentTransfers.reservePendingStarts(maxConcurrentTransfers: TransportConfig.bleMaxConcurrentTransfers)
        }

        for result in results {
            messageQueue.async { [weak self] in
                self?.handleFragmentTransferSubmitResult(result)
            }
        }
    }
    
    private func handleFragment(_ packet: BitchatPacket, from peerID: PeerID) {
        if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
            fragmentHandler.handle(packet, from: peerID)
        } else {
            messageQueue.async(flags: .barrier) { [weak self] in
                self?.fragmentHandler.handle(packet, from: peerID)
            }
        }
    }

    /// Builds the fragment handler environment. All queue hops stay here so
    /// `BLEFragmentHandler` remains queue-agnostic and synchronously testable.
    private func makeFragmentHandlerEnvironment() -> BLEFragmentHandlerEnvironment {
        BLEFragmentHandlerEnvironment(
            localPeerID: { [weak self] in
                self?.myPeerID ?? PeerID(str: "")
            },
            trackPacketSeen: { [weak self] packet in
                self?.gossipSyncManager?.onPublicPacketSeen(packet)
            },
            appendFragment: { [weak self] header in
                guard let self = self else {
                    return .stored(header: header, started: false)
                }
                return self.collectionsQueue.sync(flags: .barrier) {
                    self.fragmentAssemblyBuffer.append(header, maxInFlightAssemblies: self.maxInFlightAssemblies)
                }
            },
            isAcceptedIngressPayload: { [weak self] packet, innerSender in
                self?.isAcceptedIngressPayload(packet, from: innerSender) ?? false
            },
            processReassembledPacket: { [weak self] packet, peerID in
                self?.handleReceivedPacket(packet, from: peerID)
            }
        )
    }
    
    // MARK: Packet Reception
    
    private func handleReceivedPacket(_ packet: BitchatPacket, from peerID: PeerID) {
        // Call directly if already on messageQueue, otherwise dispatch
        if DispatchQueue.getSpecific(key: messageQueueKey) == nil {
            messageQueue.async { [weak self] in
                self?.handleReceivedPacket(packet, from: peerID)
            }
            return
        }

        let context = BLEReceivePipeline.context(for: packet, localPeerID: myPeerID)
        let senderID = context.senderID
        let messageID = context.messageID
        
        // Only log non-announce packets to reduce noise
        if context.logsHandlingDetails {
            // Log packet details for debugging
            SecureLogger.debug("📦 Handling packet type \(packet.type) from \(senderID.id.prefix(8))…, messageID: \(messageID.prefix(24))…", category: .session)
        }
        
        if dropDuplicatePacketIfNeeded(context: context, messageID: messageID) { return }
        
        // Update peer info without verbose logging - update the peer we received from, not the original sender
        updatePeerLastSeen(peerID)

        // Track recent traffic timestamps for adaptive behavior
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.recentTrafficTracker.recordPacket(at: Date())
        }

        
        // Process by type
        switch context.messageType {
        case .announce:
            handleAnnounce(packet, from: senderID)
            
        case .message:
            handleMessage(packet, from: senderID)
            
        case .requestSync:
            handleRequestSync(packet, from: senderID)
            
        case .noiseHandshake:
            handleNoiseHandshake(packet, from: senderID)
            
        case .noiseEncrypted:
            handleNoiseEncrypted(packet, from: senderID)
            
        case .fragment:
            handleFragment(packet, from: senderID)
            
        case .fileTransfer:
            handleFileTransfer(packet, from: senderID)
            
        case .leave:
            handleLeave(packet, from: senderID)
            
        case .none:
            SecureLogger.warning("⚠️ Unknown message type: \(packet.type)", category: .session)
            break
        }
        
        if forwardAlongRouteIfNeeded(packet) {
            return
        }
        
        scheduleRelayIfNeeded(packet, senderID: senderID, messageID: messageID)
    }

    private func dropDuplicatePacketIfNeeded(context: BLEReceivedPacketContext, messageID: String) -> Bool {
        guard context.shouldDeduplicate, messageDeduplicator.isDuplicate(messageID) else {
            return false
        }

        if context.logsHandlingDetails {
            SecureLogger.debug("⚠️ Duplicate packet ignored: \(messageID.prefix(24))…", category: .session)
        }

        let connectedCount = collectionsQueue.sync { peerRegistry.connectedCount }
        if BLEReceivePipeline.shouldCancelScheduledRelayForDuplicate(connectedPeerCount: connectedCount) {
            collectionsQueue.async(flags: .barrier) { [weak self] in
                self?.scheduledRelays.cancel(messageID: messageID)
            }
        }

        return true
    }

    private func scheduleRelayIfNeeded(_ packet: BitchatPacket, senderID: PeerID, messageID: String) {
        let degree = collectionsQueue.sync { peerRegistry.connectedCount }
        let decision = BLEReceivePipeline.relayDecision(
            for: packet,
            senderID: senderID,
            localPeerID: myPeerID,
            degree: degree,
            highDegreeThreshold: highDegreeThreshold
        )
        guard decision.shouldRelay else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.collectionsQueue.async(flags: .barrier) { [weak self] in
                self?.scheduledRelays.remove(messageID: messageID)
            }
            var relayPacket = packet
            relayPacket.ttl = decision.newTTL
            self.broadcastPacket(relayPacket)
        }

        collectionsQueue.async(flags: .barrier) { [weak self] in
            self?.scheduledRelays.schedule(work, messageID: messageID)
        }
        messageQueue.asyncAfter(deadline: .now() + .milliseconds(decision.delayMs), execute: work)
    }
    
    private func handleAnnounce(_ packet: BitchatPacket, from peerID: PeerID) {
        announceHandler.handle(packet, from: peerID)
    }

    /// Builds the announce handler environment. All queue hops stay here so
    /// `BLEAnnounceHandler` remains queue-agnostic and synchronously testable.
    private func makeAnnounceHandlerEnvironment() -> BLEAnnounceHandlerEnvironment {
        BLEAnnounceHandlerEnvironment(
            localPeerID: { [weak self] in
                self?.myPeerID ?? PeerID(str: "")
            },
            messageTTL: messageTTL,
            now: { Date() },
            existingNoisePublicKey: { [weak self] peerID in
                guard let self = self else { return nil }
                return self.collectionsQueue.sync { self.peerRegistry.info(for: peerID)?.noisePublicKey }
            },
            verifySignature: { [weak self] packet, signingPublicKey in
                self?.noiseService.verifyPacketSignature(packet, publicKey: signingPublicKey) ?? false
            },
            linkState: { [weak self] peerID in
                self?.linkState(for: peerID) ?? (hasPeripheral: false, hasCentral: false)
            },
            withRegistryBarrier: { [weak self] body in
                self?.collectionsQueue.sync(flags: .barrier) { body() }
            },
            upsertVerifiedAnnounce: { [weak self] peerID, announcement, isConnected, now in
                // Called from inside withRegistryBarrier; access registry directly.
                self?.peerRegistry.upsertVerifiedAnnounce(
                    peerID: peerID,
                    nickname: announcement.nickname,
                    noisePublicKey: announcement.noisePublicKey,
                    signingPublicKey: announcement.signingPublicKey,
                    isConnected: isConnected,
                    now: now
                ) ?? BLEPeerAnnounceUpdate(isNewPeer: false, wasDisconnected: false, previousNickname: nil)
            },
            shouldEmitReconnectLog: { [weak self] peerID, now in
                // Called from inside withRegistryBarrier; access debouncer directly.
                self?.reconnectLogDebouncer.shouldEmit(
                    peerID: peerID,
                    now: now,
                    minimumInterval: TransportConfig.bleReconnectLogDebounceSeconds
                ) ?? false
            },
            updateTopology: { [weak self] peerID, neighbors in
                self?.meshTopology.updateNeighbors(for: peerID.routingData, neighbors: neighbors)
            },
            persistIdentity: { [weak self] announcement in
                self?.identityManager.upsertCryptographicIdentity(
                    fingerprint: announcement.noisePublicKey.sha256Fingerprint(),
                    noisePublicKey: announcement.noisePublicKey,
                    signingPublicKey: announcement.signingPublicKey,
                    claimedNickname: announcement.nickname
                )
            },
            dedupContains: { [weak self] id in
                self?.messageDeduplicator.contains(id) ?? true
            },
            dedupMarkProcessed: { [weak self] id in
                self?.messageDeduplicator.markProcessed(id)
            },
            deliverAnnounceUIEvents: { [weak self] peerID, notifyPeerConnected, scheduleInitialSync in
                // Single main-actor hop so event order is guaranteed:
                // .peerConnected → initial sync scheduling → .peerListUpdated.
                self?.notifyUI { [weak self] in
                    guard let self = self else { return }
                    if notifyPeerConnected {
                        self.deliverTransportEvent(.peerConnected(peerID))
                    }
                    if scheduleInitialSync {
                        self.gossipSyncManager?.scheduleInitialSyncToPeer(peerID, delaySeconds: 1.0)
                    }
                    // Get current peer list (after addition)
                    let currentPeerIDs = self.collectionsQueue.sync { self.peerRegistry.peerIDs }
                    self.requestPeerDataPublish()
                    self.deliverTransportEvent(.peerListUpdated(currentPeerIDs))
                }
            },
            trackPacketSeen: { [weak self] packet in
                self?.gossipSyncManager?.onPublicPacketSeen(packet)
            },
            sendAnnounceBack: { [weak self] in
                self?.sendAnnounce(forceSend: true)
            },
            scheduleAfterglow: { [weak self] delay in
                self?.messageQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.sendAnnounce(forceSend: true)
                }
            }
        )
    }

    // Handle REQUEST_SYNC: decode payload and respond with missing packets via sync manager
    private func handleRequestSync(_ packet: BitchatPacket, from peerID: PeerID) {
        guard let req = RequestSyncPacket.decode(from: packet.payload) else {
            SecureLogger.warning("⚠️ Malformed REQUEST_SYNC from \(peerID.id.prefix(8))…", category: .session)
            return
        }
        gossipSyncManager?.handleRequestSync(from: peerID, request: req)
    }
    
    // Mention parsing moved to ChatViewModel
    
    private func handleMessage(_ packet: BitchatPacket, from peerID: PeerID) {
        publicMessageHandler.handle(packet, from: peerID)
    }

    /// Builds the public-message handler environment. All queue hops stay here
    /// so `BLEPublicMessageHandler` remains queue-agnostic and synchronously
    /// testable.
    private func makePublicMessageHandlerEnvironment() -> BLEPublicMessageHandlerEnvironment {
        BLEPublicMessageHandlerEnvironment(
            localPeerID: { [weak self] in
                self?.myPeerID ?? PeerID(str: "")
            },
            localNickname: { [weak self] in
                self?.myNickname ?? ""
            },
            now: { Date() },
            peersSnapshot: { [weak self] in
                guard let self = self else { return [:] }
                return self.collectionsQueue.sync { self.peerRegistry.snapshotByID }
            },
            verifyPacketSignature: { [weak self] packet, signingPublicKey in
                self?.noiseService.verifyPacketSignature(packet, publicKey: signingPublicKey) ?? false
            },
            signedSenderDisplayName: { [weak self] packet, peerID in
                self?.signedSenderDisplayName(for: packet, from: peerID)
            },
            trackPacketSeen: { [weak self] packet in
                self?.gossipSyncManager?.onPublicPacketSeen(packet)
            },
            linkState: { [weak self] peerID in
                self?.linkState(for: peerID) ?? (hasPeripheral: false, hasCentral: false)
            },
            takeSelfBroadcastMessageID: { [weak self] packet in
                // Caller is on messageQueue, where the tracker is owned.
                self?.selfBroadcastTracker.takeMessageID(for: packet)
            },
            deliverPublicMessage: { [weak self] peerID, nickname, content, timestamp, messageID in
                // Single main-actor hop delivering `.publicMessageReceived`.
                self?.notifyUI { [weak self] in
                    self?.deliverTransportEvent(
                        .publicMessageReceived(
                            peerID: peerID,
                            nickname: nickname,
                            content: content,
                            timestamp: timestamp,
                            messageID: messageID
                        )
                    )
                }
            }
        )
    }

    private func handleNoiseHandshake(_ packet: BitchatPacket, from peerID: PeerID) {
        noisePacketHandler.handleHandshake(packet, from: peerID)
    }

    private func handleNoiseEncrypted(_ packet: BitchatPacket, from peerID: PeerID) {
        noisePacketHandler.handleEncrypted(packet, from: peerID)
    }

    /// Builds the Noise packet handler environment. All queue hops and
    /// `noiseService` crypto calls stay here so `BLENoisePacketHandler`
    /// remains queue-agnostic and synchronously testable.
    private func makeNoisePacketHandlerEnvironment() -> BLENoisePacketHandlerEnvironment {
        BLENoisePacketHandlerEnvironment(
            localPeerID: { [weak self] in
                self?.myPeerID ?? PeerID(str: "")
            },
            localPeerIDData: { [weak self] in
                self?.myPeerIDData ?? Data()
            },
            messageTTL: messageTTL,
            now: { Date() },
            processHandshakeMessage: { [weak self] peerID, message in
                try self?.noiseService.processHandshakeMessage(from: peerID, message: message)
            },
            hasNoiseSession: { [weak self] peerID in
                self?.noiseService.hasSession(with: peerID) ?? false
            },
            initiateHandshake: { [weak self] peerID in
                self?.initiateNoiseHandshake(with: peerID)
            },
            broadcastPacket: { [weak self] packet in
                self?.broadcastPacket(packet)
            },
            updatePeerLastSeen: { [weak self] peerID in
                self?.updatePeerLastSeen(peerID)
            },
            decrypt: { [weak self] payload, peerID in
                guard let self = self else { throw NoiseEncryptionError.sessionNotEstablished }
                return try self.noiseService.decrypt(payload, from: peerID)
            },
            clearSession: { [weak self] peerID in
                self?.noiseService.clearSession(for: peerID)
            },
            deliverNoisePayload: { [weak self] peerID, type, payload, timestamp in
                // Single main-actor hop delivering `.noisePayloadReceived`.
                self?.notifyUI { [weak self] in
                    self?.deliverTransportEvent(.noisePayloadReceived(
                        peerID: peerID,
                        type: type,
                        payload: payload,
                        timestamp: timestamp
                    ))
                }
            }
        )
    }

    // MARK: Helper Functions
    
    private func sendPendingNoisePayloadsAfterHandshake(for peerID: PeerID) {
        let payloads = collectionsQueue.sync(flags: .barrier) { () -> [Data] in
            pendingNoiseSessionQueues.takeTypedPayloads(for: peerID)
        }
        guard !payloads.isEmpty else { return }
        SecureLogger.debug("📤 Sending \(payloads.count) pending noise payloads to \(peerID.id.prefix(8))… after handshake", category: .session)
        for payload in payloads {
            do {
                broadcastPacket(try makeEncryptedNoisePacket(payload, to: peerID))
            } catch {
                SecureLogger.error("❌ Failed to send pending noise payload to \(peerID.id.prefix(8))…: \(error)")
            }
        }
    }
    
    private func updatePeerLastSeen(_ peerID: PeerID) {
        // Use async to avoid deadlock - we don't need immediate consistency for last seen updates
        collectionsQueue.async(flags: .barrier) {
            self.peerRegistry.updateLastSeen(peerID, at: Date())
        }
    }

    // Debounced disconnect notifier to avoid duplicate disconnect callbacks within a short window
    @MainActor
    private func notifyPeerDisconnectedDebounced(_ peerID: PeerID) {
        if disconnectNotifyDebouncer.shouldEmit(
            peerID: peerID,
            now: Date(),
            minimumInterval: TransportConfig.bleDisconnectNotifyDebounceSeconds
        ) {
            deliverTransportEvent(.peerDisconnected(peerID))
        }
    }
    
    // NEW: Publish peer snapshots to subscribers and notify Transport delegates
    private func publishFullPeerData() {
        let transportPeers: [TransportPeerSnapshot] = collectionsQueue.sync {
            peerRegistry.transportSnapshots(selfNickname: myNickname)
        }
        // Notify non-UI listeners
        peerSnapshotSubject.send(transportPeers)
        // Notify UI on MainActor via delegate
        Task { @MainActor [weak self] in
            self?.peerEventsDelegate?.didUpdatePeerSnapshots(transportPeers)
        }
    }
    
    // MARK: Consolidated Maintenance
    
    private func performMaintenance() {
        maintenanceCounter += 1

        let now = Date()
        let connectedCount = collectionsQueue.sync { peerRegistry.connectedCount }
        let elapsed = announceThrottle.elapsed(since: now)
        let recentSeen = collectionsQueue.sync { () -> Bool in
            recentTrafficTracker.hasTraffic(within: 5.0, now: now)
        }
        let hasNoPeers = collectionsQueue.sync { peerRegistry.isEmpty }
        let plan = BLEMaintenancePolicy.plan(
            cycle: maintenanceCounter,
            connectedCount: connectedCount,
            peerRegistryIsEmpty: hasNoPeers,
            elapsedSinceLastAnnounce: elapsed,
            hasRecentTraffic: recentSeen
        )

        if plan.shouldSendAnnounce {
            sendAnnounce(forceSend: true)
        }

        if plan.shouldEnsureAdvertising {
            // Ensure we're advertising as peripheral
            if let pm = peripheralManager, pm.state == .poweredOn && !pm.isAdvertising {
                pm.startAdvertising(buildAdvertisementData())
            }
        }
        
        // Update scanning duty-cycle based on connectivity
        updateScanningDutyCycle(connectedCount: connectedCount)
        updateRSSIThreshold(connectedCount: connectedCount)

        // Drain the connection candidate queue. Weak-RSSI discoveries are
        // enqueued rather than connected immediately, and the event-driven
        // drains (disconnect/failure/timeout) never fire when we're idle —
        // without this, an isolated node surrounded only by weak (distant)
        // peers would queue them all and never connect to anyone.
        tryConnectFromQueue()
        
        // Check peer connectivity every cycle for snappier UI updates
        checkPeerConnectivity()
        
        // Every 30 seconds (3 cycles): Cleanup
        if plan.shouldRunCleanup {
            performCleanup()
        }

        // Attempt to flush any spooled directed messages periodically (~every 5 seconds)
        if plan.shouldFlushDirectedSpool {
            flushDirectedSpool()
        }

        // Periodically attempt to drain pending notifications and writes as backup
        // in case callbacks are missed or delayed (every maintenance cycle = 5 seconds)
        drainPendingNotificationsIfPossible()
        drainAllPendingWrites()

        // No rotating alias: nothing to refresh
        
        // Reset counter to prevent overflow (every 60 seconds)
        if plan.shouldResetCounter {
            maintenanceCounter = 0
        }
    }
    
    private func checkPeerConnectivity() {
        let now = Date()
        let peerIDsForLinkState: [PeerID] = collectionsQueue.sync { peerRegistry.peerIDs }
        var cachedLinkStates: [PeerID: BLEPeerLinkPresence] = [:]
        for peerID in peerIDsForLinkState {
            let state = linkState(for: peerID)
            cachedLinkStates[peerID] = BLEPeerLinkPresence(
                hasPeripheral: state.hasPeripheral,
                hasCentral: state.hasCentral
            )
        }
        
        let changes = collectionsQueue.sync(flags: .barrier) {
            peerRegistry.reconcileConnectivity(now: now, linkStates: cachedLinkStates)
        }
        for removedPeer in changes.removedPeers {
            SecureLogger.debug("🗑️ Removing stale peer after reachability window: \(removedPeer.peerID.id.prefix(8))… (\(removedPeer.nickname))", category: .session)
            gossipSyncManager?.removeAnnouncementForPeer(removedPeer.peerID)
        }
        
        // Update UI if there were direct disconnections or offline removals
        if !changes.disconnectedPeerIDs.isEmpty || !changes.removedPeers.isEmpty {
            notifyUI { [weak self] in
                guard let self else { return }
                
                // Get current peer list (after removal)
                let currentPeerIDs = self.collectionsQueue.sync { self.peerRegistry.peerIDs }
                
                for peerID in changes.disconnectedPeerIDs {
                    self.deliverTransportEvent(.peerDisconnected(peerID))
                }
                // Publish snapshots so UnifiedPeerService updates connection/reachability icons
                self.requestPeerDataPublish()
                self.deliverTransportEvent(.peerListUpdated(currentPeerIDs))
            }
        }
        
        // Refresh local topology to keep our own entry fresh and sync any changes
        refreshLocalTopology()
        // Prune stale topology nodes (using safe retention window)
        meshTopology.prune(olderThan: 60.0)
    }
    
    private func performCleanup() {
        let now = Date()
        
        // Clean old processed messages efficiently
        messageDeduplicator.cleanup()
        
        // Clean old fragments (> configured seconds old)
        collectionsQueue.sync(flags: .barrier) {
            let cutoff = now.addingTimeInterval(-TransportConfig.bleFragmentLifetimeSeconds)
            fragmentAssemblyBuffer.removeExpired(before: cutoff)
        }

        // Clean old connection timeout backoff entries (> window)
        let timeoutCutoff = now.addingTimeInterval(-TransportConfig.bleConnectTimeoutBackoffWindowSeconds)
        connectionScheduler.pruneConnectionTimeouts(before: timeoutCutoff)

        // Clean up stale scheduled relays that somehow persisted (> 2s)
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            // Nothing to compare times to; just cap the size defensively
            self.scheduledRelays.removeAllIfOverCapacity(512)
        }

        // Clean ingress link records older than configured seconds
        collectionsQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let cutoff = now.addingTimeInterval(-TransportConfig.bleIngressRecordLifetimeSeconds)
            if !self.ingressLinks.isEmpty {
                self.ingressLinks.prune(before: cutoff)
            }
            // Clean expired directed spooled items
            self.pendingDirectedRelays.pruneExpired(
                now: now,
                window: TransportConfig.bleDirectedSpoolWindowSeconds
            )
        }

        messageQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            guard !self.selfBroadcastTracker.isEmpty else { return }
            let cutoff = now.addingTimeInterval(-TransportConfig.messageDedupMaxAgeSeconds)
            self.selfBroadcastTracker.prune(before: cutoff)
        }
    }

    private func updateScanningDutyCycle(connectedCount: Int) {
        guard let central = centralManager, central.state == .poweredOn else { return }
        // Duty cycle only when app is active and at least one peer connected
        #if os(iOS)
        let active = isAppActive
        #else
        let active = true
        #endif
        // Force full-time scanning if we have very few neighbors or very recent traffic
        let hasRecentTraffic: Bool = collectionsQueue.sync {
            recentTrafficTracker.hasTraffic(
                within: TransportConfig.bleRecentTrafficForceScanSeconds,
                now: Date()
            )
        }
        let scanPlan = BLEScanDutyPolicy.plan(
            dutyEnabled: dutyEnabled,
            appIsActive: active,
            connectedCount: connectedCount,
            hasRecentTraffic: hasRecentTraffic
        )

        switch scanPlan {
        case .dutyCycle(let onDuration, let offDuration):
            let durationsChanged = dutyOnDuration != onDuration || dutyOffDuration != offDuration
            dutyOnDuration = onDuration
            dutyOffDuration = offDuration

            if scanDutyTimer == nil {
                // Start timer to toggle scanning on/off
                let t = DispatchSource.makeTimerSource(queue: bleQueue)
                // Start with scanning ON; we'll turn OFF after onDuration
                if !central.isScanning { startScanning() }
                dutyActive = true
                t.schedule(deadline: .now() + dutyOnDuration, repeating: dutyOnDuration + dutyOffDuration)
                t.setEventHandler { [weak self] in
                    guard let self = self, let c = self.centralManager else { return }
                    if self.dutyActive {
                        // Turn OFF scanning for offDuration
                        if c.isScanning { c.stopScan() }
                        self.dutyActive = false
                        // Schedule turning back ON after offDuration
                        self.bleQueue.asyncAfter(deadline: .now() + self.dutyOffDuration) {
                            if self.centralManager?.state == .poweredOn { self.startScanning() }
                            self.dutyActive = true
                        }
                    }
                }
                t.resume()
                scanDutyTimer = t
            } else if durationsChanged {
                scanDutyTimer?.schedule(deadline: .now() + dutyOnDuration, repeating: dutyOnDuration + dutyOffDuration)
                if !central.isScanning { startScanning() }
                dutyActive = true
            }
        case .continuous:
            // Cancel duty cycle and ensure scanning is ON for discovery
            scanDutyTimer?.cancel()
            scanDutyTimer = nil
            if !central.isScanning { startScanning() }
        }
    }

    private func updateRSSIThreshold(connectedCount: Int) {
        connectionScheduler.updateRSSIThreshold(
            connectedCount: connectedCount,
            connectedOrConnectingLinkCount: linkStateStore.connectedOrConnectingPeripheralCount,
            now: Date()
        )
    }
}
