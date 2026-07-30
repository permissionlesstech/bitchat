import BitLogger
import BitFoundation
import Foundation
import CoreBluetooth
import Combine
#if os(iOS)
import UIKit
#endif

/// Linearizes app-private-media admission against cancellation before work is
/// handed to the fragment scheduler. A transfer starts here synchronously,
/// before its `messageQueue` work item is enqueued; cancel/delete can therefore
/// leave a tombstone that the deferred work must observe.
///
/// Active admissions and cancellation tombstones have independent count
/// bounds. Tombstones may age out or evict older tombstones; active entries
/// are never evicted under pressure. A one-hour active timeout is reported as
/// an explicit transfer failure and removes any handshake-queued payload.
private final class BLEPrivateMediaTransferAdmissionRegistry {
    enum BeginResult: Equatable {
        case admitted
        case alreadyKnown
        case capacityExhausted
    }

    private enum State: Equatable {
        case active
        case cancelled
    }

    private struct Entry {
        var state: State
        var updatedAt: Date
    }

    private let lock = NSLock()
    private let maxActiveEntries = 512
    private let maxCancelledTombstones = 512
    private let lifetime: TimeInterval = 60 * 60
    private let onActiveExpired: (String) -> Void
    private var entries: [String: Entry] = [:]

    init(onActiveExpired: @escaping (String) -> Void) {
        self.onActiveExpired = onActiveExpired
    }

    func begin(_ transferId: String, now: Date = Date()) -> BeginResult {
        guard !transferId.isEmpty else { return .alreadyKnown }
        lock.lock()
        let expiredActive = pruneLocked(now: now)
        // Transfer IDs are invocation-unique. Never revive a cancellation or
        // admit a duplicate invocation that reused an in-flight identifier.
        let result: BeginResult
        if entries[transferId] != nil {
            result = .alreadyKnown
        } else if activeCountLocked >= maxActiveEntries {
            // Never evict an admitted transfer: doing so strands its UI
            // placeholder with no completion event. Reject the newcomer and
            // let the caller surface the bounded-pressure failure instead.
            result = .capacityExhausted
        } else {
            entries[transferId] = Entry(state: .active, updatedAt: now)
            result = .admitted
        }
        lock.unlock()
        notifyExpired(expiredActive)
        return result
    }

    func cancel(_ transferId: String, now: Date = Date()) {
        guard !transferId.isEmpty else { return }
        lock.lock()
        // Cancel the requested active entry before expiry pruning so a user
        // cancellation wins over a simultaneous timeout notification.
        entries[transferId] = Entry(state: .cancelled, updatedAt: now)
        let expiredActive = pruneLocked(now: now)
        trimCancelledTombstonesLocked()
        lock.unlock()
        notifyExpired(expiredActive)
    }

    func isActive(_ transferId: String, now: Date = Date()) -> Bool {
        lock.lock()
        let expiredActive = pruneLocked(now: now)
        let active = entries[transferId]?.state == .active
        if active {
            entries[transferId]?.updatedAt = now
        }
        lock.unlock()
        notifyExpired(expiredActive)
        return active
    }

    /// Runs `body` while holding the admission lock. Callers use this at the
    /// collections-queue append/submit boundary so cancellation and admission
    /// have one deterministic order: whichever acquires this lock first wins.
    func withActive<Result>(
        _ transferId: String,
        now: Date = Date(),
        _ body: () -> Result
    ) -> Result? {
        lock.lock()
        let expiredActive = pruneLocked(now: now)
        guard entries[transferId]?.state == .active else {
            lock.unlock()
            notifyExpired(expiredActive)
            return nil
        }
        entries[transferId]?.updatedAt = now
        let result = body()
        lock.unlock()
        notifyExpired(expiredActive)
        return result
    }

    func finish(_ transferId: String) {
        lock.lock()
        entries.removeValue(forKey: transferId)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        let expiredActive = pruneLocked(now: Date())
        let result = entries.count
        lock.unlock()
        notifyExpired(expiredActive)
        return result
    }

    func prune(now: Date = Date()) {
        lock.lock()
        let expiredActive = pruneLocked(now: now)
        lock.unlock()
        notifyExpired(expiredActive)
    }

    private var activeCountLocked: Int {
        entries.values.reduce(into: 0) { count, entry in
            if entry.state == .active { count += 1 }
        }
    }

    /// Removes stale tombstones silently and stale active admissions with a
    /// caller-visible timeout notification. Must be called with `lock` held;
    /// notifications are delivered only after the lock is released.
    private func pruneLocked(now: Date) -> [String] {
        var expiredActive: [String] = []
        let expiredEntries = entries.filter {
            now.timeIntervalSince($0.value.updatedAt) > lifetime
        }
        for (transferId, entry) in expiredEntries {
            if entry.state == .active {
                expiredActive.append(transferId)
            }
            entries.removeValue(forKey: transferId)
        }
        trimCancelledTombstonesLocked()
        return expiredActive
    }

    private func trimCancelledTombstonesLocked() {
        let cancelled = entries
            .filter { $0.value.state == .cancelled }
            .sorted { $0.value.updatedAt < $1.value.updatedAt }
        let overflow = max(0, cancelled.count - maxCancelledTombstones)
        for victim in cancelled.prefix(overflow) {
            entries.removeValue(forKey: victim.key)
        }
    }

    private func notifyExpired(_ transferIds: [String]) {
        for transferId in transferIds {
            onActiveExpired(transferId)
        }
    }
}

/// BLEService — Bluetooth Mesh Transport
/// - Emits events exclusively via `BitchatDelegate` for UI.
/// - ChatViewModel must consume delegate callbacks (`didReceivePublicMessage`, `didReceiveNoisePayload`).
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
    var linkStateStore = BLELinkStateStore()

    // The engine-owned identity domain: per-link Noise authentication +
    // rebind containment (courier handover needs the stronger fact that a
    // session was established *on this current ingress link*, not merely
    // that some session exists for the claimed ID), and the identity↔link
    // bindings that qualify every attribution decision.
    //
    // Owned by the engine queue since the option-B flip: bleQueue hands
    // decoded packets up as (packet, linkID) and the engine attributes
    // them; bleQueue never touches these. A binding can therefore briefly
    // outlive its physical link (the delegate's retirement hop is async) —
    // every query that needs liveness joins against the physical store,
    // which the engine may sync-read via `readLinkState`.
    private var _linkAuth = BLELinkAuthState()
    private var _linkBindings = BLELinkBindings()
    private var linkAuth: BLELinkAuthState {
        get { assertLinkIdentityEngineOwned(); return _linkAuth }
        set { assertLinkIdentityEngineOwned(); _linkAuth = newValue }
    }
    private var linkBindings: BLELinkBindings {
        get { assertLinkIdentityEngineOwned(); return _linkBindings }
        set { assertLinkIdentityEngineOwned(); _linkBindings = newValue }
    }
    /// Debug-traps any identity-domain access off the engine queue — the
    /// mechanical form of the option-B ownership contract.
    private func assertLinkIdentityEngineOwned() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(messageQueue))
        #endif
    }

    // BCH-01-004: Rate-limiting for subscription-triggered announces.
    var subscriptionAnnounceLimiter = BLESubscriptionAnnounceLimiter()
    
    // 3. Peer Information (single source of truth). Lock-backed so the main
    // actor reads it directly instead of blocking on the engine queue.
    // Mutations come only from the transport's own serial queues — the
    // engine, plus the two bleQueue link-drop paths (didDisconnectPeripheral
    // / didUnsubscribeFrom) that mark a peer disconnected the moment its
    // last physical link goes; the store's lock serializes them.
    private let peerRegistry = BLEPeerRegistryStore()
    
    // 4. Efficient Message Deduplication
    private let messageDeduplicator = MessageDeduplicator()

    // Courier store-and-forward: envelopes this device carries for offline
    // third parties, and the trust gate for accepting deposits. The policy
    // maps (depositor key, announce-verified?) to a quota tier, or nil to
    // reject. Injectable for tests; main-actor policy because favorites live
    // on the main actor.
    var courierStore: CourierStore = .shared
    // Bulletin-board posts this device carries; injectable for tests.
    var boardStore: BoardStore = .shared
    var courierDepositPolicy: @MainActor (Data, Bool) -> CourierDepositTier? = { depositorNoiseKey, isVerifiedPeer in
        if FavoritesPersistenceService.shared.isMutualFavorite(depositorNoiseKey) { return .favorite }
        return isVerifiedPeer ? .verified : nil
    }
    // Local-only store-and-forward counters; nil in unit tests.
    var sfMetrics: StoreAndForwardMetrics?

    // Verified one-time prekey bundles gossiped by other peers, used to seal
    // courier mail forward-secretly. Injectable for tests.
    var prekeyBundleStore: PrekeyBundleStore = .shared
    // Throttle for re-broadcasting our own (unchanged) bundle
    // (engine-confined).
    private var lastPrekeyBundleSentAt: Date?
    // Prekey bundles that arrived before their owner's verified announce bound
    // a signing key. Over the air a bundle can still arrive before the
    // announce it depends on; we retain the latest such bundle per owner
    // (bounded) and re-attempt attribution when the announce lands.
    // Engine-confined.
    private var pendingPrekeyBundles: [PeerID: BitchatPacket] = [:]
    private static let pendingPrekeyBundleCap = 64
    // Gateway mode: sink for received nostrCarrier packets (set by app
    // wiring, called on the main actor after transport-level checks) and the
    // runtime-toggled capability bits ORed into `PeerCapabilities.localSupported`
    // for every announce. `directedToUs` distinguishes an uplink deposit
    // addressed to this device from a downlink broadcast.
    var onNostrCarrierPacket: (@MainActor (_ payload: Data, _ from: PeerID, _ directedToUs: Bool) -> Void)?
    /// Fired (off-main) when a signature-verified announce is processed —
    /// the bridge courier watch refreshes its tag set on new arrivals.
    var onVerifiedPeerAnnounce: ((_ peerID: PeerID) -> Void)?

    #if DEBUG
    // Test-only tap on the outbound pipeline so multi-node tests can ferry
    // packets between in-process service instances.
    var _test_onOutboundPacket: ((BitchatPacket) -> Void)?
    /// May block a synthetic CoreBluetooth receive callback immediately
    /// before it hands a packet to `messageQueue`.
    var _test_beforeReceivePacketHandoff: (() -> Void)?
    var _test_onReceivePacketHandoff: (() -> Void)?
    var _test_onPrivateMediaSessionReconciled: ((PeerID) -> Void)?
    /// May block in tests to hold the serial message queue immediately before
    /// the deferred private-media admission check.
    var _test_beforePrivateMediaDeferredSend: ((String) -> Void)?
    /// May block the convergence-recovery callback on its global-queue thread
    /// before it enqueues onto `messageQueue`. Tests use this boundary to
    /// force the quarantine-restore handler to win the dispatch race.
    var _test_beforeHandshakeRecoveryEnqueued: ((PeerID) -> Void)?
    #endif
    private var selfBroadcastTracker = BLESelfBroadcastTracker()
    private let meshTopology = MeshTopologyTracker()
    // Route health for originated source routes (engine-confined).
    private var sourceRouteFailures = BLESourceRouteFailureCache()

    // Mesh diagnostics (/ping): engine-confined probe and budget state.
    private var meshPings = BLEMeshPingTracker()

    // 5. Fragment Reassembly (necessary for messages > MTU)
    private var fragmentAssemblyBuffer = BLEFragmentAssemblyBuffer()
    private var outboundFragmentTransfers = BLEOutboundFragmentTransferScheduler()
    private lazy var privateMediaTransferAdmissions = BLEPrivateMediaTransferAdmissionRegistry { [weak self] transferId in
        self?.handlePrivateMediaAdmissionExpiry(transferId)
    }
    // Generation-bound private-media session state (lock-backed store: the
    // main actor answers the send policy from it synchronously, and noise
    // critical sections mutate it without re-entering the engine).
    private let privateMediaSessions = BLEPrivateMediaSessionStore()
    private let incomingFileStore: BLEIncomingFileStore
    
    // Simple announce throttling
    private let announceThrottle = BLEAnnounceThrottle()
    
    // Application state tracking (thread-safe)
    #if os(iOS)
    var isAppActive: Bool = true  // Assume active initially
    /// Last `UIApplication.shared.backgroundTimeRemaining` sampled on the
    /// main thread, cached so bleQueue status logs can read it without ever
    /// dispatching to main (see `captureBluetoothStatus` for the invariant).
    private let backgroundTimeLock = NSLock()
    private var _cachedBackgroundTimeRemaining: TimeInterval = .greatestFiniteMagnitude
    private var cachedBackgroundTimeRemaining: TimeInterval {
        backgroundTimeLock.lock(); defer { backgroundTimeLock.unlock() }
        return _cachedBackgroundTimeRemaining
    }
    #endif
    
    // MARK: - Core BLE Objects
    
    var centralManager: CBCentralManager?
    var peripheralManager: CBPeripheralManager?
    var characteristic: CBMutableCharacteristic?
    private let shouldInitializeBluetoothManagers: Bool
    private let panicLifecycleLock = NSLock()
    private var _isPanicSuspended: Bool
    private var panicLifecycleGeneration: UInt64 = 0
    
    // MARK: - Identity
    
    private var noiseService: NoiseEncryptionService
    /// Injected so tests can compress the quarantine/rollback window;
    /// production always passes the security-constant default.
    private let noiseResponderHandshakeTimeout: TimeInterval
    private let identityManager: SecureIdentityStateManagerProtocol
    private let keychain: KeychainManagerProtocol
    private let idBridge: NostrIdentityBridge
    private let localIdentityState = BLELocalIdentityStateStore()

    // MARK: - Advertising Privacy
    // No Local Name by default for maximum privacy. No rotating alias.
    
    // MARK: - Queues
    
    /// The engine queue: one serial domain that owns every piece of mesh
    /// protocol state (the former concurrent message queue and the separate
    /// collections queue it guarded state with). BLE throughput is far below
    /// what one queue serializes comfortably, and a single writer makes the
    /// old per-field ownership comments and barrier discipline structural.
    private let messageQueue = DispatchQueue(label: "mesh.message")
    private let messageQueueKey = DispatchSpecificKey<Void>()
    /// The only source of deferred engine work (see BLEEngineScheduling);
    /// injectable so tests drive protocol deadlines with a manual clock.
    let engineScheduler: BLEEngineScheduling
    let bleQueue = DispatchQueue(label: "mesh.bluetooth", qos: .userInitiated)
    private let bleQueueKey = DispatchSpecificKey<Void>()

    /// Runs `body` exclusively with respect to all engine-owned state.
    /// Executes inline when already on the engine queue; otherwise blocks
    /// until the engine drains the work ahead of it.
    ///
    /// Sync-edge order (deadlock freedom): main, test threads, and the
    /// gossip manager's mesh.sync queue may sync-wait on the engine; the
    /// engine sync-waits on bleQueue (`readLinkState`) and on the
    /// crypto/identity services' internal queues. None of those may ever
    /// sync-wait back on the engine — bleQueue callers hop with
    /// `messageQueue.async` instead, and debug builds trap any violation
    /// here. (The engine only ever async-dispatches into mesh.sync; its
    /// queue.sync helpers are DEBUG test entry points on test threads.)
    private func onEngine<T>(_ body: () -> T) -> T {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(bleQueue))
        #endif
        if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
            return body()
        }
        // queue-contract-ok: this is the single sanctioned sync entry — the
        // trap above is exactly what BLEQueueContractTests exists to protect.
        return messageQueue.sync(execute: body)
    }
    
    // Noise messages and typed payloads pending handshake completion.
    private var pendingNoiseSessionQueues = BLENoiseSessionQueues()
    // Queue for notifications that failed due to full queue (bleQueue-owned,
    // like the link state store: every producer and drain runs there).
    var pendingNotifications = BLEOutboundNotificationBuffer<CBCentral>()
    // Backpressure logging fires per fragment during media transfers
    // (hundreds of lines per image); sampled via this counter, which is
    // only touched on bleQueue (no sync needed).
    var notificationBackpressureLogCount = 0

    // Accumulate long write chunks per central until a full frame decodes
    // (bleQueue-owned)
    var pendingWriteBuffers = BLEInboundWriteBuffer()
    // Relay jitter scheduling to reduce redundant floods
    private var scheduledRelays = BLEScheduledRelayStore()
    // Track short-lived traffic bursts to adapt announces/scanning under load
    // (lock-backed: written by the receive pipeline, read on bleQueue)
    private let recentTrafficTracker = BLERecentTrafficMonitor()

    // Ingress link tracking for duplicate and last-hop suppression
    // (lock-backed: recorded on bleQueue the moment a frame decodes, read
    // by engine relay/routing decisions)
    private let ingressLinks = BLEIngressLinkStore()
    // Inner message IDs of recently opened courier envelopes. Redundant
    // copies of one message ride different envelopes (each seal uses a fresh
    // ephemeral key, and bridge drops multiply across relays/couriers), so
    // envelope-level dedup can't catch them; dedup on the inner ID before
    // delivery so a duplicate costs one decrypt instead of a delivery + ack
    // + handshake each. Engine-confined.
    private var openedCourierMessageIDs = BoundedIDSet(capacity: TransportConfig.courierOpenedMessageIDCap)
    let logRateLimiter = BLELogRateLimiter(defaultMinimumInterval: 5)

    // Per-peripheral write backpressure (bleQueue-owned)
    var pendingPeripheralWrites = BLEOutboundWriteBuffer()
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
    private var lastMaintenanceAt = Date.distantPast  // bleQueue-confined; drives background-wake catch-up passes
    /// Whether real CoreBluetooth managers were initialized. When false (unit
    /// tests), periodic mesh background work is not started — the maintenance
    /// timer and the gossip-sync timers only drain BLE writes/notifications,
    /// re-announce, and sign/broadcast sync packets, all meaningless without
    /// Bluetooth. Leaving them running in the test process is pure background
    /// churn that aggravates flaky exit hangs.
    private var meshBackgroundEnabled = false

    // MARK: - Radio (central-role policy: discovery admission, connection
    // budget, connect timeouts, background connects, scan duty, advertising)
    lazy var radio = BLERadioController(
        queue: bleQueue,
        linkStateStore: linkStateStore,
        recentTraffic: recentTrafficTracker
    )
    
    // Debounced publish to coalesce rapid changes
    private var peerPublishCoalescer = BLEPeerPublishCoalescer()
    private func requestPeerDataPublish() {
        switch peerPublishCoalescer.requestPublish(now: Date()) {
        case .publishNow:
            publishFullPeerData()
        case .schedule(let delay):
            engineScheduler.schedule(after: delay) { [weak self] in
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
        initializeBluetoothManagers: Bool = true,
        incomingFileStore: BLEIncomingFileStore = BLEIncomingFileStore(),
        startSuspendedForPanicRecovery: Bool = false,
        noiseResponderHandshakeTimeout: TimeInterval =
            NoiseSecurityConstants.ordinaryResponderHandshakeTimeout,
        engineScheduler: BLEEngineScheduling = BLEEngineDispatchScheduler()
    ) {
        self.engineScheduler = engineScheduler
        self.keychain = keychain
        self.idBridge = idBridge
        self.incomingFileStore = incomingFileStore
        self.shouldInitializeBluetoothManagers = initializeBluetoothManagers
        self._isPanicSuspended = startSuspendedForPanicRecovery
        self.noiseResponderHandshakeTimeout = noiseResponderHandshakeTimeout
        noiseService = NoiseEncryptionService(
            keychain: keychain,
            ordinaryResponderHandshakeTimeout: noiseResponderHandshakeTimeout
        )
        self.identityManager = identityManager
        super.init()
        
        configureNoiseServiceCallbacks(for: noiseService)
        refreshPeerIdentity()
        
        // Set queue key for identification
        messageQueue.setSpecific(key: messageQueueKey, value: ())
        engineScheduler.activate(engineQueue: messageQueue)
        radio.delegate = self
        radio.peripheralDelegate = self
        
        // Set up application state tracking (iOS only)
        #if os(iOS)
        // Check initial state on main thread. The background-budget cache is
        // seeded here too: a background-restore launch captures Bluetooth
        // status before any lifecycle notification fires, and the init-time
        // sentinel would log a meaningless bgRemaining=∞ for exactly the
        // wake window that matters.
        if Thread.isMainThread {
            isAppActive = UIApplication.shared.applicationState == .active
            refreshCachedBackgroundTimeRemaining()
        } else {
            // queue-contract-ok: init-time only — no engine or bleQueue work
            // exists yet that main could be sync-waiting on, so this cannot
            // pair into a cycle. Everything after init caches main-actor
            // state instead (see scheduleBluetoothStatusSample).
            DispatchQueue.main.sync {
                isAppActive = UIApplication.shared.applicationState == .active
                refreshCachedBackgroundTimeRemaining()
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

        if !startSuspendedForPanicRecovery {
            initializeBluetoothManagersIfNeeded()
        }
        
        // Single maintenance timer for all periodic tasks (dispatch-based for
        // determinism). Only run it when real Bluetooth managers exist.
        meshBackgroundEnabled = initializeBluetoothManagers
        if !startSuspendedForPanicRecovery {
            startMaintenanceTimer()
        }

        // Publish initial empty state
        requestPeerDataPublish()

        // Initialize gossip sync manager
        if !startSuspendedForPanicRecovery {
            restartGossipManager()
        }
    }

    var isPanicSuspended: Bool {
        panicLifecycleLock.lock()
        defer { panicLifecycleLock.unlock() }
        return _isPanicSuspended
    }

    private func setPanicSuspended(_ suspended: Bool) {
        panicLifecycleLock.lock()
        if suspended {
            panicLifecycleGeneration &+= 1
        }
        _isPanicSuspended = suspended
        panicLifecycleLock.unlock()
    }

    private func capturePanicLifecycleGeneration() -> UInt64? {
        panicLifecycleLock.lock()
        defer { panicLifecycleLock.unlock() }
        return _isPanicSuspended ? nil : panicLifecycleGeneration
    }

    private func isCurrentPanicLifecycleGeneration(_ generation: UInt64) -> Bool {
        panicLifecycleLock.lock()
        defer { panicLifecycleLock.unlock() }
        return !_isPanicSuspended && panicLifecycleGeneration == generation
    }

    private func initializeBluetoothManagersIfNeeded() {
        guard shouldInitializeBluetoothManagers,
              centralManager == nil,
              peripheralManager == nil,
              !isPanicSuspended else { return }

        // Initialize BLE on its dedicated delegate queue. On iOS, retain the
        // restoration identifiers even when construction was deferred by a
        // pending panic-recovery latch.
        #if os(iOS)
        let centralOptions: [String: Any] = [
            CBCentralManagerOptionRestoreIdentifierKey:
                BLEService.centralRestorationID
        ]
        centralManager = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: centralOptions
        )

        let peripheralOptions: [String: Any] = [
            CBPeripheralManagerOptionRestoreIdentifierKey:
                BLEService.peripheralRestorationID
        ]
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: bleQueue,
            options: peripheralOptions
        )
        #else
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
        peripheralManager = CBPeripheralManager(delegate: self, queue: bleQueue)
        #endif
        radio.central = centralManager
    }
    
    private func restartGossipManager() {
        guard !isPanicSuspended else { return }
        // Stop existing
        gossipSyncManager?.stop()
        
        let config = GossipSyncManager.Config(
            seenCapacity: TransportConfig.syncSeenCapacity,
            gcsMaxBytes: TransportConfig.syncGCSMaxBytes,
            gcsTargetFpr: TransportConfig.syncGCSTargetFpr,
            maxMessageAgeSeconds: TransportConfig.syncMaxMessageAgeSeconds,
            publicMessageMaxAgeSeconds: TransportConfig.syncPublicMessageMaxAgeSeconds,
            maintenanceIntervalSeconds: TransportConfig.syncMaintenanceIntervalSeconds,
            stalePeerCleanupIntervalSeconds: TransportConfig.syncStalePeerCleanupIntervalSeconds,
            stalePeerTimeoutSeconds: TransportConfig.syncStalePeerTimeoutSeconds,
            fragmentCapacity: TransportConfig.syncFragmentCapacity,
            fileTransferCapacity: TransportConfig.syncFileTransferCapacity,
            fragmentSyncIntervalSeconds: TransportConfig.syncFragmentIntervalSeconds,
            fileTransferSyncIntervalSeconds: TransportConfig.syncFileTransferIntervalSeconds,
            messageSyncIntervalSeconds: TransportConfig.syncMessageIntervalSeconds,
            responseRateLimitMaxResponses: TransportConfig.syncResponseRateLimitMaxResponses,
            responseRateLimitWindowSeconds: TransportConfig.syncResponseRateLimitWindowSeconds,
            prekeyBundleCapacity: TransportConfig.syncPrekeyBundleCapacity,
            prekeyBundleSyncIntervalSeconds: TransportConfig.syncPrekeyBundleIntervalSeconds,
            prekeyBundleMaxAgeSeconds: TransportConfig.syncPrekeyBundleMaxAgeSeconds
        )

        // Only real Bluetooth sessions archive to disk; unit tests stay hermetic.
        let archive = meshBackgroundEnabled ? GossipMessageArchive() : nil
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager, archive: archive)
        manager.delegate = self
        // Board posts sync from the board store (their retention owner) so
        // deleted/expired posts drop out of rounds immediately. Real sessions
        // only, matching the archive: unit tests stay hermetic.
        if meshBackgroundEnabled {
            manager.boardPacketsProvider = { [weak self] in
                self?.boardStore.syncCandidates() ?? []
            }
        }
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
        radio.stopDutyCycle()
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
        #if os(iOS)
        NotificationCenter.default.removeObserver(self)
        #endif
    }

    /// Close radio admission before application state starts disappearing.
    /// CoreBluetooth callbacks consult the same gate and cannot restart scan
    /// or advertising while the full panic transaction is incomplete.
    func suspendForPanicReset() {
        setPanicSuspended(true)
        noisePacketHandler.resetForPanic()
        gossipSyncManager?.stop()
        gossipSyncManager = nil
        // Stop the radio and drain CoreBluetooth's delegate queue first. A
        // callback may already have passed its initial suspension check; the
        // bleQueue drain forces its final messageQueue handoff to happen
        // before the receive barrier below.
        stopServicesImmediatelyForPanic()
        // Drain every receive/send submitted by callbacks that finished ahead
        // of the radio stop. Later callbacks observe the closed lifecycle, and
        // generation-bound handoffs that raced this barrier reject themselves.
        // Clear the old identity's bounded early-ciphertext queue again after
        // those callbacks drain so none can repopulate it after the first wipe.
        onEngine {
            noisePacketHandler.resetForPanic()
        }
        clearEmergencySessionState()
    }

    /// Reopen the radio only after media deletion and recovery-marker commit.
    func completePanicReset(restartServices: Bool) {
        // The media wipe ran on the recovery operations' own file store; this
        // service's store still caches pre-panic receipt decisions (and a
        // callback drained during suspension may have re-read the pre-wipe
        // ledger). Drop the cache before admission reopens so the next lookup
        // rebuilds from the wiped directory.
        incomingFileStore.resetPrivateMediaReceiptsForPanic()
        setPanicSuspended(false)
        guard restartServices else { return }
        startServices()
        sendAnnounce(forceSend: true)
    }

    func resetIdentityForPanic(
        currentNickname: String,
        restartServices: Bool = true
    ) {
        gossipSyncManager?.stop()
        gossipSyncManager = nil
        // Discard deferred pre-panic ciphertext behind any in-flight receive
        // handlers so none can repopulate the handler's bounded queue.
        onEngine {
            noisePacketHandler.resetForPanic()
        }
        onEngine {
            pendingNoiseSessionQueues.removeAll()
        }

        let panicReset = onEngine {
            let transfers = outboundFragmentTransfers.removeAll()
            fragmentAssemblyBuffer.removeAll()
            pendingDirectedRelays.removeAll()
            ingressLinks.removeAll()
            recentTrafficTracker.removeAll()
            scheduledRelays.cancelAll()
            // Proofs and revalidation epochs die with the identity; the
            // rebind/retirement cooldowns deliberately survive (see
            // BLELinkAuthState.removeAll).
            linkAuth.removeAll()
            // The new identity owes no announce-throttle debt: without this,
            // a panic within the forced minimum interval of the last
            // announce swallows the rotation announce and the new identity
            // stays invisible until the next maintenance cycle.
            announceThrottle.reset()
            // These callbacks belong to pre-panic transfer state. Invoking
            // them would let queued UI work recreate or resend wiped media.
            privateMediaSessions.panicReset()
            // Let the post-panic identity publish its fresh bundle promptly.
            lastPrekeyBundleSentAt = nil
            return transfers
        }

        for entry in panicReset {
            entry.workItems.forEach { $0.cancel() }
            TransferProgressManager.shared.cancel(id: entry.id)
        }

        bleQueue.sync {
            pendingPeripheralWrites.removeAll()
            pendingNotifications.removeAll()
            pendingWriteBuffers.removeAll()
            radio.reset()
        }
        disconnectNotifyDebouncer.removeAll()

        // The crypto-service replacement and the derived identity swap must be
        // one atomic unit with respect to messageQueue senders: a queued send
        // must never observe the new Noise service alongside the old peer ID
        // (it would sign with the new identity while carrying the old sender).
        // refreshPeerIdentity() executes inline here via its re-entrancy check.
        onEngine {
            noiseService.clearEphemeralStateForPanic()
            noiseService.clearPersistentIdentity()

            let newNoise = NoiseEncryptionService(
                keychain: keychain,
                ordinaryResponderHandshakeTimeout: noiseResponderHandshakeTimeout
            )
            noiseService = newNoise
            configureNoiseServiceCallbacks(for: newNoise)
            refreshPeerIdentity()
        }
        // Keep the transport silent until the application-level transaction
        // has also removed its media and committed both recovery markers.
        // Set through the identity store directly (not setNickname(_:), which
        // would force-send an announce and break that silence).
        localIdentityState.setNickname(currentNickname)
        messageDeduplicator.reset()
        messageQueue.async { [weak self] in
            self?.selfBroadcastTracker.removeAll()
        }
        requestPeerDataPublish()
        if restartServices {
            restartGossipManager()
            startServices()
            sendAnnounce(forceSend: true)
        }
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
        guard !isPanicSuspended else { return }
        
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

    func currentPeerSnapshots() -> [TransportPeerSnapshot] {
        peerRegistry.transportSnapshots(selfNickname: myNickname)
    }
    
    // MARK: Identity

    /// Derived from the Noise identity fingerprint. Reads can originate from
    /// the main actor, message queue, Bluetooth queue, and maintenance timer,
    /// so all three local identity fields live in one lock-backed snapshot.
    var myPeerID: PeerID { localIdentityState.snapshot().peerID }
    var myNickname: String { localIdentityState.snapshot().nickname }
    private var myPeerIDData: Data { localIdentityState.snapshot().peerIDData }

    /// Sole mutator for `myNickname`: updates the stored value and force-sends
    /// an announce so peers learn the new name.
    func setNickname(_ nickname: String) {
        localIdentityState.setNickname(nickname)
        // Send announce to notify peers of nickname change (force send)
        sendAnnounce(forceSend: true)
    }
    
    // MARK: Lifecycle
    
    /// Creates and starts the periodic maintenance timer if it is not already
    /// running. Idempotent so it can be called from both `init` and
    /// `startServices()` — the latter matters after a panic reset, where
    /// `stopServices()` cancels and nils the timer.
    private func startMaintenanceTimer() {
        guard !isPanicSuspended,
              meshBackgroundEnabled,
              maintenanceTimer == nil else { return }
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
        guard let lifecycleGeneration =
                capturePanicLifecycleGeneration() else { return }
        initializeBluetoothManagersIfNeeded()
        if gossipSyncManager == nil {
            restartGossipManager()
        }
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
        engineScheduler.schedule(after: TransportConfig.bleInitialAnnounceDelaySeconds) { [weak self] in
            guard let self,
                  self.isCurrentPanicLifecycleGeneration(
                    lifecycleGeneration
                  ) else { return }
            self.sendAnnounce(forceSend: true)
        }
    }
    
    func stopServices() {
        let localIdentity = localIdentityState.snapshot()
        // Send leave message synchronously to ensure delivery
        var leavePacket = BitchatPacket(
            type: MessageType.leave.rawValue,
            senderID: localIdentity.peerIDData,
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
        bleQueue.sync {
            pendingNotifications.removeAll()
        }

        // Stop timer
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        radio.stopDutyCycle()

        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()

        // Disconnect all peripherals (synchronized access)
        let peripheralsToDisconnect = bleQueue.sync { linkStateStore.peripheralStates }
        for state in peripheralsToDisconnect {
            centralManager?.cancelPeripheralConnection(state.peripheral)
        }
    }

    /// Panic cannot spend its security boundary sending a signed LEAVE or
    /// pumping the main run loop. Close the radio and timers immediately;
    /// the identity/session cleanup follows synchronously.
    private func stopServicesImmediatelyForPanic() {
        bleQueue.sync {
            pendingNotifications.removeAll()
        }

        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        radio.stopDutyCycle()

        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()

        let peripheralsToDisconnect = bleQueue.sync {
            linkStateStore.peripheralStates
        }
        for state in peripheralsToDisconnect {
            centralManager?.cancelPeripheralConnection(state.peripheral)
        }
    }
    
    func emergencyDisconnectAll() {
        stopServices()
        clearEmergencySessionState()
    }

    private func clearEmergencySessionState() {
        // Clear all sessions and peers
        let cancelled = onEngine {
            let entries = outboundFragmentTransfers.removeAll().map {
                (id: $0.id, items: $0.workItems)
            }
            let pingTimeouts = meshPings.reset()
            peerRegistry.mutate { $0.removeAll() }
            fragmentAssemblyBuffer.removeAll()
            sourceRouteFailures = BLESourceRouteFailureCache()
            // Also clear pending message queues to avoid stale state across sessions
            pendingNoiseSessionQueues.removeAll()
            pendingDirectedRelays.removeAll()
            // Identity domain is engine-owned: bindings and link proofs
            // clear here, physical link state clears on bleQueue below.
            linkBindings.removeAll()
            linkAuth.removeAll()
            return (transfers: entries, pingTimeouts: pingTimeouts)
        }

        for entry in cancelled.transfers {
            entry.items.forEach { $0.cancel() }
            TransferProgressManager.shared.cancel(id: entry.id)
        }
        cancelled.pingTimeouts.forEach { $0.cancel() }

        // Clear processed messages
        messageDeduplicator.reset()

        // Clear peripheral references (synchronized access to avoid races with BLE callbacks)
        bleQueue.sync {
            linkStateStore.clearAll()
            radio.reset()
            subscriptionAnnounceLimiter.removeAll()
        }
        meshTopology.reset()
    }
    
    // MARK: Connectivity and peers
    
    func isPeerConnected(_ peerID: PeerID) -> Bool {
        // Accept both 16-hex short IDs and 64-hex Noise keys
        return peerRegistry.isConnected(peerID)
    }

    func isPeerReachable(_ peerID: PeerID) -> Bool {
        // Accept both 16-hex short IDs and 64-hex Noise keys
        peerRegistry.isReachable(peerID, now: Date())
    }

    func canDeliverSecurely(to peerID: PeerID) -> Bool {
        // A live link binding alone is forgeable: the rotation heal rebinds a
        // link on a signature-verified "direct" announce, but directness rides
        // on the unsigned TTL, so a replayed announce can bind an absent
        // peer's ID to the replayer's link. An established Noise session
        // proves the other end of the link holds the peer's private key.
        //
        // Sessions are keyed by the short wire ID, so normalize like
        // isPeerConnected does — a send keyed by the full 64-hex Noise key
        // must not misread an established session as insecure.
        noiseService.hasEstablishedSession(with: peerID.toShort())
    }

    func peerNickname(peerID: PeerID) -> String? {
        peerRegistry.nickname(for: peerID, connectedOnly: true)
    }

    /// Capabilities the peer advertised in its last verified announce.
    /// Empty for peers that predate the capabilities TLV.
    func peerCapabilities(_ peerID: PeerID) -> PeerCapabilities {
        peerRegistry.capabilities(for: peerID)
    }

    func authenticatedPrivateMediaReceiptSessionGeneration(
        to peerID: PeerID
    ) -> UUID? {
        let normalizedPeerID = peerID.toShort()
        let currentNoiseGeneration =
            noiseService.sessionGeneration(for: normalizedPeerID)
        return privateMediaSessions.receiptSessionGeneration(
            for: normalizedPeerID,
            currentNoiseGeneration: currentNoiseGeneration
        )
    }

    private func privateMediaPolicyFingerprint(
        for peerID: PeerID,
        expectedSessionGeneration: UUID?
    ) -> String? {
        let normalizedPeerID = peerID.toShort()
        if let expectedSessionGeneration,
           noiseService.sessionGeneration(for: normalizedPeerID)
                == expectedSessionGeneration,
           let fingerprint = noiseService.getPeerFingerprint(normalizedPeerID),
           noiseService.sessionGeneration(for: normalizedPeerID)
                == expectedSessionGeneration {
            // The exact authenticated Noise static key is stronger than a
            // registry entry populated by a public announce.
            return fingerprint
        }
        return peerRegistry.info(for: normalizedPeerID)?
            .noisePublicKey?
            .sha256Fingerprint()
    }

    func privateMediaSendPolicy(to peerID: PeerID) -> PrivateMediaSendPolicy {
        let normalizedPeerID = peerID.toShort()
        let state: (
            capabilities: PeerCapabilities,
            fingerprint: String?,
            sessionGeneration: UUID?,
            authenticatedState: BLEAuthenticatedPeerStateObservation?,
            timedOut: BLEPrivateMediaProofTimeoutMarker?
        ) = {
            let info = peerRegistry.info(for: normalizedPeerID)
            let session = privateMediaSessions.policyInputs(for: normalizedPeerID)
            return (
                info?.capabilities ?? [],
                info?.noisePublicKey?.sha256Fingerprint(),
                session.sessionGeneration,
                session.authenticatedState,
                session.timedOut
            )
        }()
        let currentNoiseGeneration = noiseService.sessionGeneration(for: normalizedPeerID)

        // A session replacement can happen before its authentication callback
        // reaches messageQueue. Never reuse an observation from the previous
        // transport generation during that window.
        if state.sessionGeneration != currentNoiseGeneration {
            return .awaitingCapabilityProof
        }

        guard let fingerprint = privateMediaPolicyFingerprint(
            for: normalizedPeerID,
            expectedSessionGeneration: state.sessionGeneration
        ) ?? state.fingerprint else {
            // A raw fallback must be bound to the stable Noise key from a
            // verified registry entry; a routing ID alone can rotate or be
            // spoofed. Without that key neither proof nor safe migration state
            // can be attributed.
            return .blockedDowngrade
        }

        let wasPreviouslyCapable = identityManager.hasObservedPrivateMediaCapability(
            fingerprint: fingerprint
        )

        if let authenticated = state.authenticatedState,
           authenticated.fingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame,
           authenticated.sessionGeneration == state.sessionGeneration {
            if authenticated.capabilities.contains(.privateMedia) {
                return .encrypted
            }
            return wasPreviouslyCapable ? .blockedDowngrade : .legacyRequiresConsent
        }

        if let timedOut = state.timedOut,
           timedOut.fingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame,
           timedOut.sessionGeneration == state.sessionGeneration {
            return wasPreviouslyCapable ? .blockedDowngrade : .legacyRequiresConsent
        }

        // The announce bit is a discovery hint only. It can trigger a Noise
        // handshake, but it cannot select encrypted media or create a durable
        // pin because anyone can copy a public Noise key into a self-signed
        // announce. A prior pin also re-confirms on each replacement session
        // so an authenticated no-bit response becomes a visible downgrade.
        if state.capabilities.contains(.privateMedia) || wasPreviouslyCapable {
            return .awaitingCapabilityProof
        }

        // Old clients that never advertised the bit remain eligible only for
        // the explicit, invocation-scoped legacy consent path.
        return .legacyRequiresConsent
    }

    func resolvePrivateMediaSendPolicy(
        to peerID: PeerID,
        completion: @escaping @MainActor (PrivateMediaSendPolicy) -> Void
    ) {
        let normalizedPeerID = peerID.toShort()
        messageQueue.async { [weak self] in
            guard let self else { return }
            let immediate = self.privateMediaSendPolicy(to: normalizedPeerID)
            guard immediate == .awaitingCapabilityProof else {
                self.completePrivateMediaPolicyResolution([completion], with: immediate)
                return
            }

            let generation = self.privateMediaSessions.currentGeneration(for: normalizedPeerID)
            let fingerprint = self.privateMediaPolicyFingerprint(
                for: normalizedPeerID,
                expectedSessionGeneration: generation
            )
            guard let fingerprint else {
                self.completePrivateMediaPolicyResolution([completion], with: .blockedDowngrade)
                return
            }

            let requestID = UUID()
            let registration = self.privateMediaSessions.registerPolicyResolution(
                for: normalizedPeerID,
                fingerprint: fingerprint,
                requestID: requestID,
                completion: completion
            )

            guard registration.registered else {
                self.completePrivateMediaPolicyResolution([completion], with: .blockedDowngrade)
                return
            }
            if registration.shouldSchedule {
                self.schedulePrivateMediaProofTimeout(
                    for: normalizedPeerID,
                    fingerprint: fingerprint,
                    sessionGeneration: registration.generation,
                    nonce: registration.nonce
                )
            }

            if !self.noiseService.hasEstablishedSession(with: normalizedPeerID) {
                self.initiateNoiseHandshake(with: normalizedPeerID)
            }
        }
    }

    private func completePrivateMediaPolicyResolution(
        _ completions: [@MainActor (PrivateMediaSendPolicy) -> Void],
        with policy: PrivateMediaSendPolicy
    ) {
        guard !completions.isEmpty else { return }
        notifyUI {
            completions.forEach { $0(policy) }
        }
    }

    private func schedulePrivateMediaProofTimeout(
        for peerID: PeerID,
        fingerprint: String,
        sessionGeneration: UUID?,
        nonce: UUID
    ) {
        engineScheduler.schedule(after: TransportConfig.privateMediaCapabilityProofTimeoutSeconds) { [weak self] in
            self?.handlePrivateMediaProofTimeout(
                for: peerID,
                fingerprint: fingerprint,
                sessionGeneration: sessionGeneration,
                nonce: nonce
            )
        }
    }

    private func handlePrivateMediaProofTimeout(
        for peerID: PeerID,
        fingerprint: String,
        sessionGeneration: UUID?,
        nonce: UUID
    ) {
        let expiration = privateMediaSessions.expireProofDeadline(
            for: peerID,
            fingerprint: fingerprint,
            sessionGeneration: sessionGeneration,
            nonce: nonce
        )
        guard expiration.expired else { return }
        let policy = privateMediaSendPolicy(to: peerID)
        if !expiration.deferredOutbound {
            sendPendingNoisePayloadsAfterHandshake(for: peerID)
        }
        completePrivateMediaPolicyResolution(expiration.completions, with: policy)
    }

    /// Enables or disables a runtime-advertised capability bit (e.g. the
    /// internet-gateway toggle) and re-announces so peers learn promptly.
    /// Build-time bits stay in `PeerCapabilities.localSupported`.
    func setLocalCapability(_ capability: PeerCapabilities, enabled: Bool) {
        guard localIdentityState.setCapability(capability, enabled: enabled) else { return }
        sendAnnounce(forceSend: true)
    }

    /// Reachable peers currently advertising the `.gateway` capability.
    func reachableGatewayPeers() -> [PeerID] {
        peerRegistry.reachablePeers(advertising: .gateway, now: Date())
    }

    /// Reachable peers currently advertising the `.bridge` capability.
    func reachableBridgePeers() -> [PeerID] {
        peerRegistry.reachablePeers(advertising: .bridge, now: Date())
    }

    /// A rendezvous cell advertised by a bridge-capable peer's announce.
    func advertisedBridgeGeohash() -> String? {
        peerRegistry.advertisedBridgeGeohash()
    }

    /// The rendezvous cell this device advertises in its own announces while
    /// bridging with the gateway toggle on. Set from the main actor; the
    /// value rides the next (forced) announce.
    func setLocalBridgeGeohash(_ cell: String?) {
        guard localIdentityState.setBridgeGeohash(cell) else { return }
        sendAnnounce(forceSend: true)
    }

    func getPeerNicknames() -> [PeerID: String] {
        peerRegistry.displayNicknames(selfNickname: myNickname)
    }
    
    // MARK: Protocol utilities
    
    func getFingerprint(for peerID: PeerID) -> String? {
        peerRegistry.fingerprint(for: peerID)
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
        // Callers are on the main actor; the handshake broadcast sync-waits
        // on bleQueue for link state, so hop off main first.
        messageQueue.async { [weak self] in
            self?.initiateNoiseHandshake(with: peerID)
        }
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

    private func handlePrivateMediaAdmissionExpiry(_ transferId: String) {
        // Expiry can be discovered from the BLE maintenance queue or from an
        // engine slot. Cleanup is therefore fire-and-forget; never
        // synchronously re-enter the engine.
        messageQueue.async { [weak self] in
            _ = self?.pendingNoiseSessionQueues.removeTypedPayload(transferId: transferId)
        }
        TransferProgressManager.shared.rejectBeforeStart(
            id: transferId,
            reason: String(
                localized: "content.delivery.reason.private_media_admission_expired",
                defaultValue: "Media transfer timed out before it could start",
                comment: "Failure reason when private-media admission expires before fragment scheduling"
            )
        )
    }

    func cancelTransfer(_ transferId: String) {
        // Cancellation must become visible synchronously. Scheduler/pending-
        // Noise cleanup remains asynchronous, but deferred private-media work
        // cannot pass another admission boundary after this returns.
        privateMediaTransferAdmissions.cancel(transferId)
        messageQueue.async { [weak self] in
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
                if self.pendingNoiseSessionQueues.removeTypedPayload(transferId: transferId) {
                    SecureLogger.debug("🛑 Removed handshake-queued transfer \(transferId.prefix(8))…", category: .session)
                }
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
            guard !self.isPanicSuspended else { return }
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

    func sendFilePrivate(
        _ filePacket: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String,
        allowLegacyFallback: Bool
    ) {
        sendFilePrivate(
            filePacket,
            to: peerID,
            transferId: transferId,
            allowLegacyFallback: allowLegacyFallback,
            requiresAuthenticatedPrivateMediaReceipts: false
        )
    }

    func sendFilePrivateReceiptRetry(
        _ filePacket: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String
    ) {
        sendFilePrivate(
            filePacket,
            to: peerID,
            transferId: transferId,
            allowLegacyFallback: false,
            requiresAuthenticatedPrivateMediaReceipts: true
        )
    }

    private func sendFilePrivate(
        _ filePacket: BitchatFilePacket,
        to peerID: PeerID,
        transferId: String,
        allowLegacyFallback: Bool,
        requiresAuthenticatedPrivateMediaReceipts: Bool
    ) {
        // Register before enqueueing onto messageQueue. This closes the window
        // where cancel/delete could run first, observe no scheduler state, and
        // then be followed by a deferred clear-media send.
        switch privateMediaTransferAdmissions.begin(transferId) {
        case .admitted:
            break

        case .alreadyKnown:
            SecureLogger.debug(
                "Private media admission already cancelled or duplicated for \(transferId.prefix(8))…",
                category: .security
            )
            return

        case .capacityExhausted:
            SecureLogger.warning(
                "Private media admission capacity exhausted for \(transferId.prefix(8))…",
                category: .security
            )
            TransferProgressManager.shared.rejectBeforeStart(
                id: transferId,
                reason: String(
                    localized: "content.delivery.reason.private_media_admission_full",
                    defaultValue: "Too many media transfers are waiting; try again shortly",
                    comment: "Failure reason when too many private-media transfers are awaiting admission"
                )
            )
            return
        }
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            #if DEBUG
            self._test_beforePrivateMediaDeferredSend?(transferId)
            #endif
            guard !self.isPanicSuspended else {
                self.privateMediaTransferAdmissions.finish(transferId)
                return
            }
            guard self.privateMediaTransferAdmissions.isActive(transferId) else {
                self.privateMediaTransferAdmissions.finish(transferId)
                return
            }
            let targetID = peerID.toShort()
            switch self.privateMediaSendPolicy(to: targetID) {
            case .encrypted:
                break

            case .awaitingCapabilityProof:
                // The UI coordinator resolves this state before calling the
                // transport. Keep the transport guard fail-closed for direct
                // callers and for a session replacement that races the call.
                SecureLogger.warning(
                    "Private media held pending authenticated capability proof for \(targetID.id.prefix(8))…",
                    category: .security
                )
                TransferProgressManager.shared.rejectBeforeStart(
                    id: transferId,
                    reason: String(
                        localized: "content.delivery.reason.private_media_capability_unresolved",
                        defaultValue: "Could not confirm encrypted media support",
                        comment: "Failure reason when private-media capability negotiation did not resolve"
                    )
                )
                self.privateMediaTransferAdmissions.finish(transferId)
                return

            case .legacyRequiresConsent:
                guard allowLegacyFallback else {
                    SecureLogger.warning(
                        "Private media blocked pending explicit legacy-clear consent for \(targetID.id.prefix(8))…",
                        category: .security
                    )
                    TransferProgressManager.shared.rejectBeforeStart(
                        id: transferId,
                        reason: String(
                            localized: "content.delivery.reason.legacy_media_consent_required",
                            defaultValue: "Confirmation required before sending without end-to-end encryption",
                            comment: "Failure reason when a legacy private-media send lacks per-send consent"
                        )
                    )
                    self.privateMediaTransferAdmissions.finish(transferId)
                    return
                }
                // Migration path accepted by current Android and used by older
                // iOS releases: preserve the directed raw file-transfer wire
                // shape, but require the signature the receive path verifies.
                // The allow flag belongs to this invocation only and is
                // consumed here; a retry must obtain fresh user consent.
                self.sendSignedLegacyPrivateFile(
                    filePacket,
                    to: targetID,
                    transferId: transferId
                )
                return

            case .blockedDowngrade:
                SecureLogger.warning(
                    "Private media downgrade blocked for \(targetID.id.prefix(8))…",
                    category: .security
                )
                TransferProgressManager.shared.rejectBeforeStart(
                    id: transferId,
                    reason: String(
                        localized: "content.delivery.reason.private_media_downgrade_blocked",
                        defaultValue: "Encrypted media required; ask this contact to upgrade",
                        comment: "Failure reason when a peer that previously supported encrypted media appears to downgrade"
                    )
                )
                self.privateMediaTransferAdmissions.finish(transferId)
                return
            }
            if requiresAuthenticatedPrivateMediaReceipts,
               self.authenticatedPrivateMediaReceiptSessionGeneration(
                    to: targetID
               ) == nil {
                SecureLogger.warning(
                    "Private media retry blocked without current authenticated receipt support for \(targetID.id.prefix(8))…",
                    category: .security
                )
                TransferProgressManager.shared.rejectBeforeStart(
                    id: transferId,
                    reason: String(
                        localized: "content.delivery.reason.private_media_capability_unresolved",
                        defaultValue: "Could not confirm encrypted media support",
                        comment: "Failure reason when private-media capability negotiation did not resolve"
                    )
                )
                self.privateMediaTransferAdmissions.finish(transferId)
                return
            }
            guard let typedPayload = BLENoisePayloadFactory.privateFile(filePacket) else {
                SecureLogger.error("❌ Failed to encode file packet for private send", category: .session)
                TransferProgressManager.shared.rejectBeforeStart(
                    id: transferId,
                    reason: String(localized: "content.delivery.reason.media_encoding_failed", defaultValue: "Failed to prepare media", comment: "Failure reason when private media cannot be encoded")
                )
                self.privateMediaTransferAdmissions.finish(transferId)
                return
            }
            guard self.noiseService.hasEstablishedSession(with: targetID) else {
                if requiresAuthenticatedPrivateMediaReceipts {
                    // A retry belongs to one exact authenticated generation.
                    // Never let it enter the ordinary pending queue where a
                    // bit-8-only replacement session could later flush it.
                    TransferProgressManager.shared.rejectBeforeStart(
                        id: transferId,
                        reason: String(
                            localized: "content.delivery.reason.private_media_capability_unresolved",
                            defaultValue: "Could not confirm encrypted media support",
                            comment: "Failure reason when private-media capability negotiation did not resolve"
                        )
                    )
                    self.privateMediaTransferAdmissions.finish(transferId)
                    return
                }
                let queued = onEngine {
                    self.privateMediaTransferAdmissions.withActive(transferId) {
                        self.pendingNoiseSessionQueues.appendTypedPayload(
                            typedPayload,
                            transferId: transferId,
                            for: targetID
                        )
                        return true
                    } ?? false
                }
                guard queued else {
                    self.privateMediaTransferAdmissions.finish(transferId)
                    return
                }
                SecureLogger.debug("📥 Queued private file for \(targetID.id.prefix(8))… pending handshake", category: .session)
                guard self.privateMediaTransferAdmissions.isActive(transferId) else {
                    onEngine {
                        _ = self.pendingNoiseSessionQueues.removeTypedPayload(transferId: transferId)
                    }
                    self.privateMediaTransferAdmissions.finish(transferId)
                    return
                }
                self.initiateNoiseHandshake(with: targetID)
                return
            }

            do {
                guard self.privateMediaTransferAdmissions.isActive(transferId) else {
                    self.privateMediaTransferAdmissions.finish(transferId)
                    return
                }
                let packet = try self.makeEncryptedNoisePacket(
                    typedPayload,
                    to: targetID,
                    requiresAuthenticatedPrivateMediaReceipts:
                        requiresAuthenticatedPrivateMediaReceipts
                )
                guard self.privateMediaTransferAdmissions.isActive(transferId) else {
                    self.privateMediaTransferAdmissions.finish(transferId)
                    return
                }
                SecureLogger.debug("📁 Sending encrypted private file to \(targetID.id.prefix(8))… plaintextBytes=\(typedPayload.count)", category: .session)
                self.broadcastPacket(
                    packet,
                    transferId: transferId,
                    requiresPrivateMediaAdmission: true
                )
            } catch {
                SecureLogger.error("❌ Failed to encrypt private file for \(targetID.id.prefix(8))…: \(error)", category: .security)
                TransferProgressManager.shared.rejectBeforeStart(
                    id: transferId,
                    reason: String(localized: "content.delivery.reason.encryption_failed", comment: "Failure reason shown when a message could not be encrypted for the peer")
                )
                self.privateMediaTransferAdmissions.finish(transferId)
            }
        }
    }

    /// Compatibility-only fallback for peers that have not advertised
    /// encrypted private media. The payload is authenticated but visible to
    /// relays, matching the pre-migration behavior until those clients upgrade.
    private func sendSignedLegacyPrivateFile(
        _ filePacket: BitchatFilePacket,
        to targetID: PeerID,
        transferId: String
    ) {
        guard privateMediaTransferAdmissions.isActive(transferId) else {
            privateMediaTransferAdmissions.finish(transferId)
            return
        }
        guard let payload = filePacket.encode(),
              let recipientData = Data(hexString: targetID.id) else {
            SecureLogger.error("❌ Failed to encode legacy private file transfer", category: .session)
            TransferProgressManager.shared.rejectBeforeStart(
                id: transferId,
                reason: String(localized: "content.delivery.reason.media_encoding_failed", defaultValue: "Failed to prepare media", comment: "Failure reason when private media cannot be encoded")
            )
            privateMediaTransferAdmissions.finish(transferId)
            return
        }

        let unsigned = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: myPeerIDData,
            recipientID: recipientData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: messageTTL,
            version: 2
        )
        guard let signed = noiseService.signPacket(unsigned) else {
            SecureLogger.error("❌ Failed to sign legacy private file transfer", category: .security)
            TransferProgressManager.shared.rejectBeforeStart(
                id: transferId,
                reason: String(localized: "content.delivery.reason.media_signing_failed", defaultValue: "Failed to authenticate media", comment: "Failure reason when a legacy private-media packet cannot be signed")
            )
            privateMediaTransferAdmissions.finish(transferId)
            return
        }

        // Signing can be non-trivial; cancellation that won while it ran must
        // still prevent the clear payload from reaching the broadcast path.
        guard privateMediaTransferAdmissions.isActive(transferId) else {
            privateMediaTransferAdmissions.finish(transferId)
            return
        }

        SecureLogger.warning(
            "📁 Sending signed legacy private file to \(targetID.id.prefix(8))…; peer has not advertised E2E media",
            category: .security
        )
        broadcastPacket(
            signed,
            transferId: transferId,
            requiresPrivateMediaAdmission: true
        )
    }

    
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        // Hop like sendMessage: callers are often on the main actor, and the
        // send path sync-waits on bleQueue for link state — the main thread
        // must never block on bleQueue (see captureBluetoothStatus).
        if DispatchQueue.getSpecific(key: messageQueueKey) == nil {
            messageQueue.async { [weak self] in
                self?.sendReadReceipt(receipt, to: peerID)
            }
            return
        }
        let payload = BLENoisePayloadFactory.readReceipt(originalMessageID: receipt.originalMessageID)

        if noiseService.hasEstablishedSession(with: peerID) {
            SecureLogger.debug("📤 Sending READ receipt id=\(receipt.originalMessageID.prefix(8))… to \(peerID.id.prefix(8))…", category: .session)
            do {
                broadcastPacket(try makeEncryptedNoisePacket(payload, to: peerID))
            } catch {
                SecureLogger.error("Failed to send read receipt: \(error)")
            }
        } else {
            // Queue for after handshake; initiate only while the peer is
            // around to answer (see sendDeliveryAck — absent senders must
            // not turn queued acks into handshake floods).
            onEngine {
                pendingNoiseSessionQueues.appendTypedPayload(payload, for: peerID)
            }
            if !noiseService.hasSession(with: peerID), isPeerReachable(peerID) {
                initiateNoiseHandshake(with: peerID)
            }
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
        ingressLinks.recordIfNew(
            packet,
            link: link,
            peerID: peerID,
            lifetime: TransportConfig.bleIngressRecordLifetimeSeconds
        )
    }

    // MARK: - Packet Broadcasting
    
    private func broadcastPacket(
        _ packet: BitchatPacket,
        transferId: String? = nil,
        requiresPrivateMediaAdmission: Bool = false
    ) {
        guard !isPanicSuspended else {
            if requiresPrivateMediaAdmission, let transferId {
                privateMediaTransferAdmissions.finish(transferId)
            }
            return
        }
        if requiresPrivateMediaAdmission {
            guard let transferId,
                  privateMediaTransferAdmissions.isActive(transferId) else {
                if let transferId {
                    privateMediaTransferAdmissions.finish(transferId)
                }
                return
            }
        }
        // Apply route if recipient exists (centralized route application)
        let packetToSend: BitchatPacket
        if let recipientPeerID = PeerID(hexData: packet.recipientID) {
            packetToSend = applyRouteIfAvailable(packet, to: recipientPeerID)
        } else {
            packetToSend = packet
        }

        // Encode once using a small per-type padding policy, then delegate by type
        let padForBLE = BLEOutboundPacketPolicy.padsBLEFrame(for: packetToSend.type)

        // The 256-fragment ceiling exists to protect *current Android*
        // receivers, which only ever receive private media over the directed
        // raw-file migration fallback (they do not implement the encrypted
        // 0x20 path). Encrypted private media (`noiseEncrypted`) is sent only to
        // peers that advertised the `.privateMedia` capability — modern clients
        // that assemble up to the full receiver ceiling (see
        // `BLEFragmentAssemblyBuffer`'s 10,000-fragment guard) — so forcing them
        // down to Android's 256 cap would needlessly reject iOS→iOS photos in
        // the ~120–512 KiB range that work today. Restrict the low cap to the
        // migration fallback (directed `fileTransfer`); public media is
        // unaffected. Run the same planner the scheduler will use, after route
        // application, and reject before reserving a transfer slot or writing
        // any fragment.
        // TODO(#1434): negotiate an explicit per-peer fragment limit so a future
        // Android client that adopts the encrypted 0x20 path but still caps its
        // reassembler can advertise its own ceiling instead of relying on the
        // capability/type proxy above.
        if let transferId,
           let recipientPeerID = PeerID(hexData: packetToSend.recipientID),
           packetToSend.type == MessageType.fileTransfer.rawValue {
            let compatibilityRequest = BLEOutboundFragmentTransferRequest(
                packet: packetToSend,
                pad: padForBLE,
                maxChunk: nil,
                directedPeer: recipientPeerID,
                transferId: transferId
            )
            guard let plan = BLEOutboundFragmentPlanner.makePlan(
                for: compatibilityRequest,
                defaultChunkSize: defaultFragmentSize,
                bleMaxMTU: bleMaxMTU
            ), BLEOutboundFragmentPlanner.isPrivateMediaV1Compatible(plan) else {
                SecureLogger.warning(
                    "Private media rejected: exceeds cross-platform 256-fragment limit",
                    category: .security
                )
                TransferProgressManager.shared.rejectBeforeStart(
                    id: transferId,
                    reason: String(
                        localized: "content.delivery.reason.private_media_too_many_fragments",
                        defaultValue: "File is too large for this contact's client (more than 256 mesh fragments)",
                        comment: "Failure reason when private media exceeds the Android-compatible fragment limit"
                    )
                )
                if requiresPrivateMediaAdmission {
                    privateMediaTransferAdmissions.finish(transferId)
                }
                return
            }
        }

        // Route planning and fragment preflight can take enough time for a
        // user cancellation to win. Recheck before exposing even the test tap,
        // then check atomically with scheduler admission below.
        if requiresPrivateMediaAdmission {
            guard let transferId,
                  privateMediaTransferAdmissions.isActive(transferId) else {
                if let transferId {
                    privateMediaTransferAdmissions.finish(transferId)
                }
                return
            }
        }

        #if DEBUG
        _test_onOutboundPacket?(packetToSend)
        #endif

        if packetToSend.type == MessageType.fileTransfer.rawValue {
            sendFragmentedPacket(
                packetToSend,
                pad: padForBLE,
                maxChunk: nil,
                directedOnlyPeer: nil,
                transferId: transferId,
                requiresPrivateMediaAdmission: requiresPrivateMediaAdmission
            )
            return
        }
        // App-initiated private media is already one opaque Noise ciphertext.
        // Always fragment that outer packet so the existing transfer scheduler
        // retains progress/cancel behavior without exposing the file TLVs.
        if packetToSend.type == MessageType.noiseEncrypted.rawValue,
           let transferId,
           let recipientPeerID = PeerID(hexData: packetToSend.recipientID) {
            sendFragmentedPacket(
                packetToSend,
                pad: padForBLE,
                maxChunk: nil,
                directedOnlyPeer: recipientPeerID,
                transferId: transferId,
                requiresPrivateMediaAdmission: requiresPrivateMediaAdmission
            )
            return
        }
        if requiresPrivateMediaAdmission {
            if let transferId {
                privateMediaTransferAdmissions.finish(transferId)
            }
            SecureLogger.error(
                "Private media admission reached an unsupported non-directed packet shape",
                category: .security
            )
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
        guard !isPanicSuspended else { return }
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isPanicSuspended else { return }
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
            self.engineScheduler.schedule(after: Double(backoff) / 1_000) { [weak self] in
                self?.enqueuePendingNotification(data: data, centrals: centrals, context: context, attempt: attempt + 1)
            }
        }
    }

    /// Synchronously admits a notification to the link-specific retry queue.
    /// Destructive courier handoff uses this result as its commit point, so a
    /// full process-local queue must be reported as rejection, not success.
    private func enqueuePendingNotificationIfAccepted(
        data: Data,
        centrals: [CBCentral],
        context: String
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let result = pendingNotifications.enqueue(
            data: data,
            targets: centrals,
            capCount: TransportConfig.blePendingNotificationsCapCount
        )
        switch result {
        case let .enqueued(count):
            SecureLogger.debug("📋 Queued \(context) packet for retry (pending=\(count))", category: .session)
            return true
        case let .full(count):
            SecureLogger.warning("⚠️ Rejecting \(context) packet: notification queue full (pending=\(count))", category: .session)
            return false
        }
    }

    /// The authenticated-link eligibility check runs here on the engine —
    /// the queue that owns bindings and rebinds — so fanout planning and
    /// the final check are serialized against identity changes by
    /// construction. Only the physical admission (updateValue and the
    /// backpressure queue) hops to `bleQueue`; a central that physically
    /// departs in between is a harmless no-op delivery.
    private func notifyOrEnqueueIfAccepted(
        data: Data,
        centrals: [CBCentral],
        characteristic: CBMutableCharacteristic,
        context: String,
        requiredAuthenticatedPeer: PeerID?
    ) -> Bool {
        let eligible: [CBCentral]
        if let peerID = requiredAuthenticatedPeer {
            eligible = centrals.filter { central in
                let link = BLEIngressLinkID.central(central.identifier.uuidString)
                return linkAuth.isAuthenticated(link, for: peerID)
                    && linkBindings.peer(forCentralUUID: central.identifier.uuidString) == peerID
            }
        } else {
            eligible = centrals
        }
        guard !eligible.isEmpty else { return false }

        let accept = { [self] in
            if peripheralManager?.updateValue(data, for: characteristic, onSubscribedCentrals: eligible) == true {
                return true
            }
            return enqueuePendingNotificationIfAccepted(
                data: data,
                centrals: eligible,
                context: context
            )
        }
        // queue-contract-ok: engine → bleQueue is the sanctioned sync direction.
        return bleQueue.sync(execute: accept)
    }

    /// Returns true only when the packet was accepted by at least one current
    /// physical link (including its link-specific backpressure queue). A
    /// process-local directed spool is deliberately not success: callers
    /// that own a durable upstream copy must keep it retryable.
    @discardableResult
    private func sendOnAllLinks(
        packet: BitchatPacket,
        data: Data,
        pad: Bool,
        directedOnlyPeer: PeerID?,
        requireDirectPeerLink: Bool = false,
        requireNoiseAuthenticatedPeerLink: Bool = false
    ) -> Bool {
        guard !isPanicSuspended else { return false }
        let ingressRecord = ingressLinks.record(for: packet)
        var excludedPeerLinks = links(to: ingressRecord?.peerID)
        if requireNoiseAuthenticatedPeerLink {
            guard let directedOnlyPeer else { return false }
            let boundLinks = links(to: directedOnlyPeer)
            let authenticatedLinks = currentNoiseAuthenticatedLinks(to: directedOnlyPeer)
            guard !authenticatedLinks.isEmpty else { return false }
            excludedPeerLinks.formUnion(boundLinks.subtracting(authenticatedLinks))
        }
        let outboundPriority = BLEOutboundPacketPolicy.priority(for: packet, data: data)

        let states = snapshotPeripheralStates()
        // A link without a discovered characteristic cannot be written to
        // (the write loop below skips it); offering it to the planner only
        // wastes fanout slots — and a peer's single collapsed copy would be
        // silently dropped if its bound link is still mid-rediscovery.
        let connectedStates = states.filter { $0.isConnected && $0.characteristic != nil }
        let centralSnapshot = snapshotSubscribedCentrals()
        let subscribedCentrals = characteristic == nil ? [] : centralSnapshot.centrals
        let connectedPeripheralIDs = connectedStates.map { $0.peripheral.identifier.uuidString }
        let centralIDs = subscribedCentrals.map { $0.identifier.uuidString }
        let peripheralPeerBindings = Dictionary(uniqueKeysWithValues: connectedStates.compactMap { state -> (String, PeerID)? in
            let uuid = state.peripheral.identifier.uuidString
            return linkBindings.peer(forPeripheralID: uuid).map { (uuid, $0) }
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
            centralPeerBindings: centralSnapshot.peerIDsByCentralUUID,
            preferredPeripheralPerPeer: linkBindings.preferredPeripheralBindings,
            directAnnounceTTL: messageTTL,
            directedOnlyPeer: directedOnlyPeer,
            requireDirectPeerLink: requireDirectPeerLink || requireNoiseAuthenticatedPeerLink
        )

        if let chunk = plan.fragmentChunkSize {
            guard !plan.selectedLinks.peripheralIDs.isEmpty || !plan.selectedLinks.centralIDs.isEmpty else {
                return false
            }
            return sendFragmentedPacket(
                packet,
                pad: pad,
                maxChunk: chunk,
                directedOnlyPeer: directedOnlyPeer,
                requireDirectPeerLink: requireDirectPeerLink || requireNoiseAuthenticatedPeerLink,
                requireNoiseAuthenticatedPeerLink: requireNoiseAuthenticatedPeerLink
            )
        }

        // If directed and we currently have no links to forward on, spool for a short window
        if let only = plan.directedPeerHint,
           plan.shouldSpoolDirectedPacket {
            spoolDirectedPacket(packet, recipientPeerID: only)
        }

        var acceptedByPhysicalLink = false

        // Writes to selected connected peripherals
        for s in connectedStates {
            let pid = s.peripheral.identifier.uuidString
            guard plan.selectedLinks.peripheralIDs.contains(pid) else { continue }
            if let ch = s.characteristic {
                if requireDirectPeerLink || requireNoiseAuthenticatedPeerLink {
                    acceptedByPhysicalLink = writeOrEnqueueIfAccepted(
                        data,
                        to: s.peripheral,
                        characteristic: ch,
                        priority: outboundPriority,
                        requiredAuthenticatedPeer: requireNoiseAuthenticatedPeerLink ? directedOnlyPeer : nil
                    ) || acceptedByPhysicalLink
                } else {
                    writeOrEnqueue(data, to: s.peripheral, characteristic: ch, priority: outboundPriority)
                }
            }
        }
        // Notify selected subscribed centrals
        if let ch = characteristic {
            let targets = subscribedCentrals.filter { plan.selectedLinks.centralIDs.contains($0.identifier.uuidString) }
            if !targets.isEmpty {
                if requireDirectPeerLink || requireNoiseAuthenticatedPeerLink {
                    acceptedByPhysicalLink = notifyOrEnqueueIfAccepted(
                        data: data,
                        centrals: targets,
                        characteristic: ch,
                        context: "directed",
                        requiredAuthenticatedPeer: requireNoiseAuthenticatedPeerLink ? directedOnlyPeer : nil
                    ) || acceptedByPhysicalLink
                } else {
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
        if requireDirectPeerLink || requireNoiseAuthenticatedPeerLink { return acceptedByPhysicalLink }
        return !plan.selectedLinks.peripheralIDs.isEmpty || !plan.selectedLinks.centralIDs.isEmpty
    }

    // Directed send helper (unicast to a specific peerID) without altering packet contents
    @discardableResult
    private func sendPacketDirected(
        _ packet: BitchatPacket,
        to peerID: PeerID,
        requireDirectPeerLink: Bool = false,
        requireNoiseAuthenticatedPeerLink: Bool = false
    ) -> Bool {
        #if DEBUG
        _test_onOutboundPacket?(packet)
        #endif
        guard let data = packet.toBinaryData(padding: false) else { return false }
        return sendOnAllLinks(
            packet: packet,
            data: data,
            pad: false,
            directedOnlyPeer: peerID,
            requireDirectPeerLink: requireDirectPeerLink,
            requireNoiseAuthenticatedPeerLink: requireNoiseAuthenticatedPeerLink
        )
    }

    // MARK: - Directed store-and-forward
    private func spoolDirectedPacket(_ packet: BitchatPacket, recipientPeerID: PeerID) {
        let msgID = BLEOutboundPacketPolicy.messageID(for: packet)
        messageQueue.async { [weak self] in
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

    func flushDirectedSpool() {
        guard !isPanicSuspended else { return }
        // Runs from bleQueue maintenance: hop to the engine asynchronously
        // (bleQueue must never sync-wait on the engine). Move items out and
        // attempt broadcast; if still no links, they'll be re-spooled.
        messageQueue.async { [weak self] in
            guard let self, !self.isPanicSuspended else { return }
            let toSend = self.pendingDirectedRelays.drainUnexpired(
                now: Date(),
                window: TransportConfig.bleDirectedSpoolWindowSeconds
            )
            for entry in toSend {
                self.broadcastPacket(entry.packet)
            }
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

    // MARK: - Archived public messages ("heard here earlier")

    func purgeArchivedPublicMessages(from peerID: PeerID) {
        gossipSyncManager?.removePublicMessages(from: peerID)
    }

    /// Clearing the mesh timeline erases the archive behind it, so the cleared
    /// history is gone from disk rather than merely hidden from the timeline.
    func purgeAllArchivedPublicMessages() {
        gossipSyncManager?.removeAllPublicMessages()
    }

    func collectArchivedPublicMessages(completion: @escaping @MainActor ([ArchivedPublicMessage]) -> Void) {
        guard let generation = capturePanicLifecycleGeneration() else {
            return
        }
        guard let sync = gossipSyncManager else {
            notifyUI { [weak self] in
                guard let self,
                      self.isCurrentPanicLifecycleGeneration(generation) else {
                    return
                }
                completion([])
            }
            return
        }
        sync.collectPublicMessagePackets { [weak self] packets in
            guard let self,
                  self.isCurrentPanicLifecycleGeneration(generation) else {
                return
            }
            // Signature verification and registry lookups run on messageQueue
            // like the live receive path.
            self.messageQueue.async {
                guard self.isCurrentPanicLifecycleGeneration(generation) else {
                    return
                }
                let decoded = packets
                    .compactMap { self.decodeArchivedPublicMessage($0) }
                    .sorted { $0.timestamp < $1.timestamp }
                self.notifyUI { [weak self] in
                    guard let self,
                          self.isCurrentPanicLifecycleGeneration(generation) else {
                        return
                    }
                    completion(decoded)
                }
            }
        }
    }

    private func decodeArchivedPublicMessage(_ packet: BitchatPacket) -> ArchivedPublicMessage? {
        guard packet.type == MessageType.message.rawValue,
              let content = String(data: packet.payload, encoding: .utf8)?.trimmedOrNilIfEmpty
        else { return nil }
        let senderPeerID = PeerID(hexData: packet.senderID)
        let peers = peerRegistry.snapshotByID
        // Archived senders are usually long gone, so the signature-derived
        // identity is the best shot at a name; a live registry entry is
        // next; anonymous fallback matches the live path.
        let nickname = signedSenderDisplayName(for: packet, from: senderPeerID)
            ?? BLEPeerSenderDisplayName.resolveKnownPeer(
                peerID: senderPeerID,
                localPeerID: myPeerID,
                localNickname: myNickname,
                peers: peers,
                allowConnectedUnverified: false
            )
            ?? BLEPeerSenderDisplayName.anonymousNickname(for: senderPeerID)
        return ArchivedPublicMessage(
            packetIdHex: PacketIdUtil.computeId(packet).hexEncodedString(),
            senderPeerID: senderPeerID,
            senderNickname: nickname,
            content: content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(packet.timestamp) / 1000)
        )
    }

    private func handleFileTransfer(_ packet: BitchatPacket, from peerID: PeerID) -> Bool {
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
                return self.peerRegistry.snapshotByID
            },
            verifyPacketSignature: { [weak self] packet, signingPublicKey in
                self?.noiseService.verifyPacketSignature(packet, publicKey: signingPublicKey) ?? false
            },
            localSigningPublicKey: { [weak self] in
                self?.noiseService.getSigningPublicKeyData() ?? Data()
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
            privateMediaReceiptState: { [weak self] messageID in
                self?.incomingFileStore.privateMediaReceiptState(
                    messageID: messageID
                ) ?? .unavailable
            },
            commitPrivateMediaFile: { [weak self] messageID, storedURL in
                self?.incomingFileStore.commitPrivateMediaFile(
                    messageID: messageID,
                    storedURL: storedURL
                ) ?? false
            },
            removeIncomingFile: { [weak self] storedURL in
                self?.incomingFileStore.removeIncomingFile(at: storedURL)
            },
            finishIncomingFileDelivery: { [weak self] storedURL in
                // Serialize pending-owner release behind deletion barriers.
                // If /clear snapshots before this UI insertion, its already
                // queued barrier must still observe the path as pending. If
                // insertion wins first, the next MainActor snapshot sees the
                // new bubble and protects the path explicitly.
                self?.messageQueue.async {
                    self?.incomingFileStore.finishIncomingFileDelivery(
                        at: storedURL
                    )
                }
            },
            isPrivateMediaSenderBlocked: { [weak self] peerID in
                guard let self else { return false }
                let senderStaticKey = self.noiseService.getPeerPublicKeyData(peerID)
                    ?? onEngine {
                        self.peerRegistry.info(for: peerID)?.noisePublicKey
                    }
                guard let senderStaticKey else { return false }
                return self.identityManager.isBlocked(
                    fingerprint: senderStaticKey.sha256Fingerprint()
                )
            },
            updatePeerLastSeen: { [weak self] peerID in
                self?.updatePeerLastSeen(peerID)
            },
            acknowledgePrivateMedia: { [weak self] messageID, peerID in
                guard let self,
                      let senderStaticKey = self.noiseService.getPeerPublicKeyData(peerID),
                      !self.identityManager.isBlocked(
                        fingerprint: senderStaticKey.sha256Fingerprint()
                      ) else {
                    return
                }
                self.sendDeliveryAck(for: messageID, to: peerID)
            },
            deliverMessage: { [weak self] message, shouldDeliver, completion, finalization in
                self?.emitTransportEvent(
                    .messageReceived(message),
                    shouldDeliver: shouldDeliver,
                    completion: completion,
                    finalization: finalization
                )
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
        // Hop like sendMessage: callers are often on the main actor, and the
        // send path sync-waits on bleQueue for link state — the main thread
        // must never block on bleQueue (see captureBluetoothStatus).
        if DispatchQueue.getSpecific(key: messageQueueKey) == nil {
            messageQueue.async { [weak self] in
                self?.sendDeliveryAck(for: messageID, to: peerID)
            }
            return
        }
        let payload = BLENoisePayloadFactory.delivered(messageID: messageID)

        if noiseService.hasEstablishedSession(with: peerID) {
            do {
                broadcastPacket(try makeEncryptedNoisePacket(payload, to: peerID))
            } catch {
                SecureLogger.error("Failed to send delivery ACK: \(error)")
            }
        } else {
            // Queue for after handshake; initiate only while the peer is
            // around to answer — couriered/bridged mail routinely arrives
            // from absent (or rotated) identities, and every duplicate copy
            // initiating a handshake broadcast turns one undeliverable ack
            // into a mesh-wide flood. The queued ack flushes whenever a
            // session eventually establishes.
            onEngine {
                pendingNoiseSessionQueues.appendTypedPayload(payload, for: peerID)
            }
            if !noiseService.hasSession(with: peerID), isPeerReachable(peerID) {
                initiateNoiseHandshake(with: peerID)
            }
            SecureLogger.debug("🕒 Queued DELIVERED ack for \(peerID.id.prefix(8))… until handshake completes", category: .session)
        }
    }

    /// Accept a leave only when the claimed sender proves possession of the
    /// signing key bound by a verified announce. The persisted identity cache
    /// keeps delayed/relayed leaves verifiable after the live registry entry
    /// has aged out.
    private func handleLeave(_ packet: BitchatPacket, from peerID: PeerID) -> Bool {
        let registrySigningKey = onEngine {
            peerRegistry.info(for: peerID)?.signingPublicKey
        }
        let verifiedViaRegistry = registrySigningKey.map {
            noiseService.verifyPacketSignature(packet, publicKey: $0)
        } ?? false
        let verifiedViaPersistedIdentity = !verifiedViaRegistry
            && identityManager.getCryptoIdentitiesByPeerIDPrefix(peerID).contains { identity in
                PeerID(publicKey: identity.publicKey) == peerID
                    && identity.signingPublicKey.map {
                        noiseService.verifyPacketSignature(packet, publicKey: $0)
                    } == true
            }

        guard verifiedViaRegistry || verifiedViaPersistedIdentity else {
            SecureLogger.warning(
                "🚫 Dropping leave with missing/invalid signature for claimed sender \(peerID.id.prefix(8))…",
                category: .security
            )
            return false
        }

        // A valid departure retires transport state too; otherwise
        // canDeliverSecurely could remain true for a peer we just removed.
        clearNoiseSession(for: peerID)
        _ = linkAuth.retireLinks(ownedBy: peerID)
        // Remove the peer when they leave
        peerRegistry.mutate { _ = $0.remove(peerID) }
        // Remove any stored announcement for sync purposes
        gossipSyncManager?.removeAnnouncementForPeer(peerID)
        // Send on main thread
        notifyUI { [weak self] in
            guard let self = self else { return }
            
            // Get current peer list (after removal)
            let currentPeerIDs = self.peerRegistry.peerIDs
            
            self.deliverTransportEvent(.peerDisconnected(peerID))
            self.deliverTransportEvent(.peerListUpdated(currentPeerIDs))
        }
        return true
    }
    func sendAnnounce(forceSend: Bool = false) {
        guard !isPanicSuspended else { return }
        // Announce construction reads the replaceable Noise service and several
        // related state snapshots. Serialize the whole operation with identity
        // rotation instead of letting CoreBluetooth and maintenance callbacks
        // execute it directly on their own queues.
        messageQueue.async { [weak self] in
            self?.sendAnnounceNow(forceSend: forceSend)
        }
    }

    private func sendAnnounceNow(forceSend: Bool) {
        // Re-check on the serialized queue: a panic suspend may have started
        // after this announce was scheduled but before it runs.
        guard !isPanicSuspended else { return }
        // Throttle announces to prevent flooding
        if !announceThrottle.shouldSend(force: forceSend, now: Date()) {
            return
        }

        // Reduced logging - only log errors, not every announce
        
        // Create announce payload with both noise and signing public keys
        let noisePub = noiseService.getStaticPublicKeyData()  // For noise handshakes and peer identification
        let signingPub = noiseService.getSigningPublicKeyData()  // For signature verification
        
        let connectedPeerIDs = peerRegistry.connectedRoutingData
        let localIdentity = localIdentityState.snapshot()
        let advertisedCapabilities = localIdentity.advertisedCapabilities
        let advertisedBridgeCell = localIdentity.advertisedBridgeGeohash
        let announcement = AnnouncementPacket(
            nickname: localIdentity.nickname,
            noisePublicKey: noisePub,
            signingPublicKey: signingPub,
            directNeighbors: connectedPeerIDs,
            capabilities: advertisedCapabilities,
            bridgeGeohash: advertisedBridgeCell
        )
        
        guard let payload = announcement.encode() else {
            SecureLogger.error("❌ Failed to encode announce packet", category: .session)
            return
        }
        
        // Create packet with signature using the noise private key
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: localIdentity.peerIDData,
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
        
        broadcastPacket(signedPacket)
        // Ensure our own announce is included in sync state
        gossipSyncManager?.onPublicPacketSeen(signedPacket)

        // Keep our prekey bundle riding alongside presence (throttled; the
        // send is a no-op when the bundle was refreshed recently).
        sendPrekeyBundle()
    }

    // MARK: QR Verification over Noise
    
    // MARK: Private Groups

    /// Sends creator-signed group state (invite) 1:1 over the Noise session,
    /// queueing behind a handshake when none is established yet.
    func sendGroupInvite(_ statePayload: Data, to peerID: PeerID) {
        sendNoisePayload(NoisePayload(type: .groupInvite, data: statePayload).encode(), to: peerID)
    }

    /// Sends creator-signed group state (key rotation / roster update) 1:1
    /// over the Noise session.
    func sendGroupKeyUpdate(_ statePayload: Data, to peerID: PeerID) {
        sendNoisePayload(NoisePayload(type: .groupKeyUpdate, data: statePayload).encode(), to: peerID)
    }

    /// Broadcasts a sealed group message (MessageType 0x25) like a public
    /// message: fire-and-flood with gossip-sync backfill. The outer packet is
    /// intentionally unsigned — receivers authenticate the sender's Ed25519
    /// signature inside the ciphertext, which still verifies for backfilled
    /// copies long after the sender's announce has expired.
    func broadcastGroupMessage(_ envelope: Data) {
        guard !envelope.isEmpty else { return }
        messageQueue.async { [weak self] in
            guard let self else { return }
            let packet = BitchatPacket(
                type: MessageType.groupMessage.rawValue,
                senderID: Data(hexString: self.myPeerID.id) ?? Data(),
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: envelope,
                signature: nil,
                ttl: self.messageTTL
            )
            // Pre-mark our own broadcast as processed to avoid handling a
            // relayed self copy.
            let dedupID = BLESelfBroadcastTracker.dedupID(for: packet)
            self.messageDeduplicator.markProcessed(dedupID)
            self.broadcastPacket(packet)
            // Track our own broadcast for gossip sync
            self.gossipSyncManager?.onPublicPacketSeen(packet)
        }
    }

    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        let payload = VerificationService.shared.buildVerifyChallenge(noiseKeyHex: noiseKeyHex, nonceA: nonceA)
        sendNoisePayload(payload, to: peerID)
    }

    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        guard let payload = VerificationService.shared.buildVerifyResponse(noiseKeyHex: noiseKeyHex, nonceA: nonceA) else { return }
        sendNoisePayload(payload, to: peerID)
    }

    // MARK: Vouching over Noise

    func sendVouchAttestations(_ payload: Data, to peerID: PeerID) {
        sendNoisePayload(NoisePayload(type: .vouch, data: payload).encode(), to: peerID)
    }

    // MARK: Live Voice (PTT)

    /// Sends one live voice-burst packet inside the Noise session. Unlike
    /// `sendNoisePayload` this never queues behind a handshake: live audio is
    /// only useful now, so without an established session frames are dropped.
    func sendVoiceFrame(_ burstContent: Data, to peerID: PeerID) {
        messageQueue.async { [weak self] in
            guard let self else { return }
            guard self.noiseService.hasEstablishedSession(with: peerID) else {
                SecureLogger.debug("PTT: dropping voice frame — no established session with \(peerID.id.prefix(8))…", category: .session)
                return
            }
            do {
                let typedPayload = NoisePayload(type: .voiceFrame, data: burstContent).encode()
                self.broadcastPacket(try self.makeEncryptedNoisePacket(typedPayload, to: peerID))
            } catch {
                SecureLogger.error("Failed to send voice frame: \(error)", category: .session)
            }
        }
    }

    /// Broadcasts one live voice-burst packet to the public mesh, signed like
    /// a public message so receivers can authenticate the talker. Ephemeral:
    /// never tracked for gossip sync (stale audio is worthless to replay).
    func sendVoiceFrameBroadcast(_ burstContent: Data) {
        guard !burstContent.isEmpty else { return }
        messageQueue.async { [weak self] in
            guard let self else { return }
            let packet = BitchatPacket(
                type: MessageType.voiceFrame.rawValue,
                senderID: self.myPeerIDData,
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: burstContent,
                signature: nil,
                ttl: self.messageTTL
            )
            guard let signedPacket = self.noiseService.signPacket(packet) else {
                SecureLogger.error("❌ Failed to sign voice frame", category: .security)
                return
            }
            // Pre-mark our own broadcast as processed to avoid handling a
            // relayed self copy.
            let dedupID = BLESelfBroadcastTracker.dedupID(for: signedPacket)
            self.messageDeduplicator.markProcessed(dedupID)
            self.broadcastPacket(signedPacket)
        }
    }

    func addPeerAuthenticatedObserver(_ handler: @escaping (PeerID, String) -> Void) {
        // Appends to the encryption service's handler array, so this never
        // displaces the callbacks installed by installNoiseSessionCallbacks.
        noiseService.addOnPeerAuthenticatedHandler(handler)
    }
}

// MARK: - GossipSyncManager Delegate
extension BLEService: GossipSyncManager.Delegate {
    // Gossip calls arrive on the manager's own serial queue; sends read
    // the engine-owned bindings, so they enter an engine slot. The sync
    // hop is safe: mesh.sync sits above the engine in the sync order —
    // production engine code only ever queue.async's into the manager
    // (the queue.sync helpers are DEBUG test entry points that run on
    // test threads), so no reverse edge exists.
    func sendPacket(_ packet: BitchatPacket) {
        onEngine {
            broadcastPacket(packet)
        }
    }

    func sendPacket(to peerID: PeerID, packet: BitchatPacket) {
        onEngine {
            sendPacketDirected(packet, to: peerID)
        }
    }

    func signPacketForBroadcast(_ packet: BitchatPacket) -> BitchatPacket {
        return noiseService.signPacket(packet) ?? packet
    }
    
    func getConnectedPeers() -> [PeerID] {
        return onEngine {
            peerRegistry.connectedPeerIDs
        }
    }
}

// MARK: - Radio controller integration

extension BLEService: BLERadioControllerDelegate {
    func radioIsPanicSuspended() -> Bool {
        isPanicSuspended
    }

    func radioIsAppActive() -> Bool {
        #if os(iOS)
        return isAppActive
        #else
        return true
        #endif
    }

    func radioTearDownPeripheralLink(_ peripheralID: String) {
        // bleQueue (the controller's queue): physical discard now, identity
        // retirement via the port.
        discardPeripheralLinkPhysical(peripheralID)
        emitLinkEvent(.peripheralLinkEnded(peripheralID: peripheralID, runPeerBookkeeping: false))
    }

    /// bleQueue half of a peripheral-link teardown: the link's write
    /// backpressure and its physical link-state entry. Identity retirement
    /// (proof, epoch, binding repair) rides a separate engine hop —
    /// `retirePeripheralLinkIdentity`. bleQueue-confined.
    func discardPeripheralLinkPhysical(_ peripheralID: String) {
        pendingPeripheralWrites.discardAll(for: peripheralID)
        linkStateStore.removePeripheral(peripheralID)
    }

    /// Engine half of a peripheral-link teardown: retires the link's Noise
    /// proof and revalidation epoch, and its binding — repairing the peer's
    /// preferred link onto a connected survivor, preferring a writable one
    /// (a link mid-service-rediscovery would strand directed sends until
    /// its characteristic comes back). Returns the peer that owned the
    /// binding. Engine-confined.
    @discardableResult
    func retirePeripheralLinkIdentity(_ peripheralID: String) -> PeerID? {
        linkAuth.retireLink(.peripheral(peripheralID))
        return linkBindings.peripheralRemoved(peripheralID) { remaining in
            let alive = readLinkState { store in
                remaining.compactMap { uuid -> (uuid: String, writable: Bool)? in
                    guard let state = store.state(forPeripheralID: uuid),
                          state.isConnected else { return nil }
                    return (uuid, state.characteristic != nil)
                }
            }
            return (alive.first(where: \.writable) ?? alive.first)?.uuid
        }
    }

    /// Binds only live physical links, preserving the store-era guard that
    /// a binding can never precede its link (a lost race against a
    /// concurrent physical removal is healed by that removal's queued
    /// identity retirement). Engine-confined.
    func bindPeripheralLink(_ peripheralUUID: String, to peerID: PeerID) {
        guard readLinkState({ $0.state(forPeripheralID: peripheralUUID) }) != nil else { return }
        linkBindings.bindPeripheral(peripheralUUID, to: peerID)
    }

    /// Whether the peer holds a live direct link in either role: bindings
    /// (engine) joined against physical liveness (readLinkState).
    /// Engine-confined.
    func directLinkState(for peerID: PeerID) -> BLEDirectLinkState {
        let hasPeripheral = linkBindings.preferredPeripheralUUID(for: peerID)
            .flatMap { uuid in readLinkState { $0.state(forPeripheralID: uuid)?.isConnected } } ?? false
        return BLEDirectLinkState(
            hasPeripheral: hasPeripheral,
            hasCentral: linkBindings.hasCentral(boundTo: peerID)
        )
    }

    /// The peer's preferred peripheral link state, when physically present.
    /// Engine-confined.
    func directPeripheralState(for peerID: PeerID) -> BLEPeripheralLinkState? {
        linkBindings.preferredPeripheralUUID(for: peerID)
            .flatMap { uuid in readLinkState { $0.state(forPeripheralID: uuid) } }
    }

    /// Subscribed centrals with their bindings, one view. Engine-confined.
    func subscribedCentralSnapshot() -> BLESubscribedCentralSnapshot {
        BLESubscribedCentralSnapshot(
            centrals: readLinkState(\.subscribedCentrals),
            peerIDsByCentralUUID: linkBindings.centralPeersByUUID
        )
    }
}


#if DEBUG
// Test-only helper to inject packets into the receive pipeline
extension BLEService {
    /// Queues an event through the same MainActor hop as production receive
    /// handlers so panic-boundary tests can deterministically invalidate it.
    func _test_emitTransportEvent(_ event: TransportEvent) {
        emitTransportEvent(event)
    }

    var _test_isPanicIngressOpen: Bool {
        capturePanicLifecycleGeneration() != nil
    }

    /// Queries the receipt store of the service's OWN incoming-file store —
    /// the instance production lookups run against — so panic tests exercise
    /// the real wiring instead of a same-instance shortcut.
    func _test_privateMediaReceiptState(
        messageID: String
    ) -> BLEPrivateMediaReceiptState {
        incomingFileStore.privateMediaReceiptState(messageID: messageID)
    }

    /// Models a CoreBluetooth delegate callback without requiring a physical
    /// peripheral. The callback itself runs on `bleQueue`, exactly where the
    /// panic radio-stop barrier must linearize it.
    func _test_handlePacketFromBLEQueue(
        _ packet: BitchatPacket,
        fromPeerID: PeerID
    ) {
        bleQueue.async { [weak self] in
            self?.handleReceivedPacket(packet, from: fromPeerID)
        }
    }

    /// Simulated-link ingress: the full production attribution path —
    /// binding lookup, spoof rejection, raw-announce binding, ingress
    /// recording — for a frame arriving on a synthetic link. The
    /// SimulatedMesh harness feeds every node through this, so multi-node
    /// tests exercise the same engine code as CoreBluetooth ingress.
    func _test_ingestFrame(_ packet: BitchatPacket, link: BLEIngressLinkID) {
        emitLinkEvent(.frameDecoded(packet, link: link, linkDescription: "Simulated \(link)"))
    }

    /// Sends an unthrottled announce, exactly like the maintenance forced
    /// path. SimulatedMesh uses this as the deterministic discovery step.
    func _test_forceAnnounce() {
        onEngine { sendAnnounceNow(forceSend: true) }
    }

    /// Clears the announce throttle's wall-clock debt — the simulator's
    /// stand-in for "enough real time has passed", since scheduler time
    /// cannot move the throttle's Date-based window. Deliberately NOT
    /// part of `_test_forceAnnounce`: the panic-rotation mesh test relies
    /// on the production panic path performing its own reset, and a
    /// blanket reset here would mask that regression.
    func _test_resetAnnounceThrottle() {
        announceThrottle.reset()
    }

    /// Blocks until every engine slot enqueued so far has run — the
    /// deterministic settling fence for simulated-mesh pumping.
    func _test_fenceEngine() {
        onEngine {}
    }

    func _test_emitTransportEvent(
        _ event: TransportEvent,
        completion: @escaping () -> Void,
        finalization: @escaping (TransportEventDeliveryOutcome) -> Void
    ) {
        emitTransportEvent(
            event,
            completion: completion,
            finalization: finalization
        )
    }

    func _test_handlePacket(_ packet: BitchatPacket, fromPeerID: PeerID, preseedPeer: Bool = true, signingPublicKey: Data? = nil) {
        if preseedPeer {
            // Ensure the synthetic peer is known and marked verified for public-message tests
            let normalizedID = PeerID(hexData: packet.senderID)
            peerRegistry.mutate { registry in
                if var existing = registry.info(for: normalizedID) {
                    existing.isConnected = true
                    existing.isVerifiedNickname = true
                    if let signingPublicKey { existing.signingPublicKey = signingPublicKey }
                    existing.lastSeen = Date()
                    registry.upsert(existing)
                } else {
                    registry.upsert(BLEPeerInfo(
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

    /// Waits until fragment ingress already submitted by a test has finished
    /// reassembly/reinjection and any resulting transport event has crossed
    /// the MainActor delivery hop. This is a deterministic pipeline fence,
    /// avoiding wall-clock sleeps that become flaky under a parallel suite.
    func _test_drainFragmentPipeline() async {
        await withCheckedContinuation { continuation in
            messageQueue.async {
                // Reassembled packets are reinjected synchronously on
                // `messageQueue`; their UI delivery task is therefore already
                // enqueued before this later MainActor marker.
                Task { @MainActor in
                    continuation.resume()
                }
            }
        }
    }

    func _test_hasGossipPrekeyBundle(for peerID: PeerID) -> Bool {
        gossipSyncManager?._hasPrekeyBundle(for: peerID) ?? false
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

    func _test_bindCentral(_ centralUUID: String, to peerID: PeerID) {
        onEngine { linkBindings.bindCentral(centralUUID, to: peerID) }
    }

    func _test_centralBinding(_ centralUUID: String) -> PeerID? {
        onEngine { linkBindings.peer(forCentralUUID: centralUUID) }
    }

    func _test_markNoiseAuthenticatedCentral(_ centralUUID: String, to peerID: PeerID) {
        onEngine {
            guard linkBindings.peer(forCentralUUID: centralUUID) == peerID else { return }
            linkAuth.markAuthenticated(.central(centralUUID), owner: peerID)
        }
    }

    func _test_isNoiseAuthenticatedCentral(_ centralUUID: String, for peerID: PeerID) -> Bool {
        onEngine {
            linkAuth.isAuthenticated(.central(centralUUID), for: peerID)
        }
    }

    func _test_seedConnectedPeer(
        _ peerID: PeerID,
        nickname: String,
        capabilities: PeerCapabilities? = nil,
        noisePublicKey: Data? = nil
    ) {
        peerRegistry.mutate {
            $0.upsert(BLEPeerInfo(
                peerID: peerID,
                nickname: nickname,
                isConnected: true,
                noisePublicKey: noisePublicKey,
                signingPublicKey: nil,
                isVerifiedNickname: true,
                lastSeen: Date(),
                capabilities: capabilities ?? [],
                capabilitiesWereExplicitlyAdvertised: capabilities != nil
            ))
        }
    }

    /// Handshake plumbing for tests that need a real established Noise
    /// session (e.g. canDeliverSecurely) without Bluetooth in the loop.
    func _test_noiseInitiateHandshake(with peerID: PeerID) throws -> Data {
        try noiseService.initiateHandshake(with: peerID)
    }

    func _test_noiseProcessHandshakeMessage(from peerID: PeerID, message: Data) throws -> Data? {
        try noiseService.processHandshakeMessage(from: peerID, message: message)
    }

    func _test_enqueuePendingPrivateMessage(
        content: String,
        messageID: String,
        for peerID: PeerID
    ) {
        onEngine {
            pendingNoiseSessionQueues.appendPrivateMessage(
                content: content,
                messageID: messageID,
                for: peerID
            )
        }
    }

    func _test_enqueuePendingNoisePayload(
        _ payload: Data,
        transferId: String,
        for peerID: PeerID
    ) {
        guard privateMediaTransferAdmissions.begin(transferId) == .admitted else { return }
        onEngine {
            pendingNoiseSessionQueues.appendTypedPayload(
                payload,
                transferId: transferId,
                for: peerID
            )
        }
    }

    func _test_sendPendingNoisePayloadsAfterHandshake(for peerID: PeerID) {
        sendPendingNoisePayloadsAfterHandshake(for: peerID)
    }

    func _test_hasPendingPrivateMediaPolicyResolution(for peerID: PeerID) -> Bool {
        privateMediaSessions.hasPendingPolicyResolution(for: peerID.toShort())
    }

    func _test_forcePrivateMediaProofTimeout(for peerID: PeerID) {
        let normalizedPeerID = peerID.toShort()
        let target = privateMediaSessions.proofTimeoutTarget(for: normalizedPeerID)
        guard let target else { return }
        handlePrivateMediaProofTimeout(
            for: normalizedPeerID,
            fingerprint: target.fingerprint,
            sessionGeneration: target.generation,
            nonce: target.nonce
        )
    }

    func _test_privateMediaTransferState(
        transferId: String
    ) -> (admissionActive: Bool, pendingNoise: Bool, activeScheduler: Int, pendingScheduler: Int) {
        let scheduler = onEngine {
            (
                pendingNoiseSessionQueues.containsTypedPayload(transferId: transferId),
                outboundFragmentTransfers.activeCount,
                outboundFragmentTransfers.pendingCount
            )
        }
        return (
            privateMediaTransferAdmissions.isActive(transferId),
            scheduler.0,
            scheduler.1,
            scheduler.2
        )
    }

    func _test_privateMediaAdmissionEntryCount() -> Int {
        privateMediaTransferAdmissions.count
    }

    @discardableResult
    func _test_beginPrivateMediaAdmission(_ transferId: String, now: Date) -> Bool {
        privateMediaTransferAdmissions.begin(transferId, now: now) == .admitted
    }

    func _test_isPrivateMediaAdmissionActive(_ transferId: String, now: Date) -> Bool {
        privateMediaTransferAdmissions.isActive(transferId, now: now)
    }

    func _test_finishPrivateMediaAdmission(_ transferId: String) {
        privateMediaTransferAdmissions.finish(transferId)
    }

    func _test_drainPrivateMediaSendPipeline() async {
        await withCheckedContinuation { continuation in
            self.messageQueue.async { [weak self] in
                self?.messageQueue.async {
                    continuation.resume()
                }
            }
        }
    }

    func _test_broadcastPrivateMediaPacket(
        _ packet: BitchatPacket,
        transferId: String
    ) {
        broadcastPacket(
            packet,
            transferId: transferId,
            requiresPrivateMediaAdmission: true
        )
    }

    func _test_drainNoiseMessagePipeline() async {
        await withCheckedContinuation { continuation in
            self.messageQueue.async {
                self.messageQueue.async {
                    continuation.resume()
                }
            }
        }
    }

    /// Replays the current generation's ready callback. Restore tests use
    /// this to prove same-generation reconciliation is idempotent.
    func _test_reconcileCurrentNoiseSession(for peerID: PeerID) {
        let normalizedPeerID = peerID.toShort()
        messageQueue.async { [weak self] in
            guard let self,
                  let generation = self.noiseService.sessionGeneration(
                    for: normalizedPeerID
                  ),
                  let fingerprint = self.noiseService.getPeerFingerprint(
                    normalizedPeerID
                  ) else {
                return
            }
            self.handleNoisePeerAuthenticated(
                peerID: normalizedPeerID,
                fingerprint: fingerprint,
                sessionGeneration: generation
            )
        }
    }

    /// Builds an authenticated-session packet from an exact typed plaintext.
    /// Compatibility tests use this to model Android's deployed 0x20 file
    /// payload and the short-lived 0x09 prerelease payload without exposing a
    /// production API that can emit the old value.
    func _test_makeEncryptedNoisePacket(_ typedPayload: Data, to peerID: PeerID) throws -> BitchatPacket {
        try makeEncryptedNoisePacket(typedPayload, to: peerID)
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


// MARK: - Advertising Builders & Alias Rotation

extension BLEService {
    // Advertising payload and alias policy live on BLERadioController.
}

// MARK: - Private Media Deletion

extension BLEService: PrivateMediaDeletionPersisting {
    @MainActor
    func persistDeletedPrivateMedia(
        messageIDs: [String],
        payloadRelativePaths: [String: String],
        protectedPayloadRelativePaths: Set<String>,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let fileStore = incomingFileStore
        messageQueue.async {
            guard let reservation = fileStore
                    .reservePrivateMediaDeletion(
                        messageIDs: messageIDs,
                        payloadRelativePaths: payloadRelativePaths
                    ) else {
                Task { @MainActor in
                    completion(false)
                }
                return
            }
            let persisted = fileStore
                .commitPrivateMediaDeletion(
                    reservation: reservation,
                    messageIDs: messageIDs,
                    payloadRelativePaths: payloadRelativePaths,
                    protectedPayloadRelativePaths:
                        protectedPayloadRelativePaths
                )
            Task { @MainActor in
                completion(persisted)
            }
        }
    }

    @MainActor
    func removeLegacyPrivateMediaPayload(relativePath: String) {
        let fileStore = incomingFileStore
        messageQueue.async {
            fileStore.removeLegacyIncomingFile(relativePath: relativePath)
        }
    }
}

// MARK: - Private Helpers

enum TransportEventDeliveryOutcome: Equatable {
    /// A synchronous sink inserted the message and revalidation succeeded.
    case accepted
    /// A supported plain delegate was invoked, but insertion cannot be
    /// confirmed synchronously.
    case invokedUnconfirmed
    /// No sink accepted the event, or receipt revalidation rejected it.
    case rejected
}

enum TransportEventDeliveryGate {
    /// Runs finalization exactly once for every attempted main-actor delivery,
    /// including pre-insertion rejection, a missing/rejecting sink, and
    /// post-insertion revalidation failure. Only a fully accepted delivery
    /// runs `completion` (for example, a stable-media ACK).
    @MainActor
    static func attempt(
        shouldDeliver: () -> Bool,
        deliver: () -> TransportEventDeliveryOutcome,
        completion: () -> Void,
        finalization: (TransportEventDeliveryOutcome) -> Void
    ) {
        var outcome = TransportEventDeliveryOutcome.rejected
        defer { finalization(outcome) }
        guard shouldDeliver() else {
            return
        }
        switch deliver() {
        case .rejected:
            return
        case .invokedUnconfirmed:
            outcome = .invokedUnconfirmed
            return
        case .accepted:
            break
        }
        guard shouldDeliver() else { return }
        outcome = .accepted
        completion()
    }
}

extension BLEService {
    
    /// Notify UI on the MainActor to satisfy Swift concurrency isolation
    private func notifyUI(_ block: @escaping @MainActor () -> Void) {
        // Capture the panic lifecycle before queueing the MainActor hop. A
        // receive callback can enqueue UI delivery immediately before panic
        // clears application state; rechecking here prevents that stale work
        // from repopulating the wiped conversation store afterward.
        guard let generation = capturePanicLifecycleGeneration() else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  self.isCurrentPanicLifecycleGeneration(generation) else {
                return
            }
            block()
        }
    }

    func emitTransportEvent(
        _ event: TransportEvent,
        shouldDeliver: (() -> Bool)? = nil,
        completion: (() -> Void)? = nil,
        finalization: ((TransportEventDeliveryOutcome) -> Void)? = nil
    ) {
        guard let generation = capturePanicLifecycleGeneration() else {
            Task { @MainActor in
                finalization?(.rejected)
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  self.isCurrentPanicLifecycleGeneration(generation) else {
                finalization?(.rejected)
                return
            }
            TransportEventDeliveryGate.attempt(
                shouldDeliver: {
                    self.isCurrentPanicLifecycleGeneration(generation)
                        && (shouldDeliver?() ?? true)
                },
                deliver: {
                    return self.deliverTransportEvent(event)
                },
                completion: { completion?() },
                finalization: { finalization?($0) }
            )
        }
    }

    /// Delivers a transport event to the installed delegates and reports
    /// whether acceptance was confirmed.
    ///
    /// For `.messageReceived`, returns `true` only when a
    /// `SynchronousMessageTransportEventDelegate` synchronously confirmed
    /// acceptance of the message (duplicates count as accepted). Returns
    /// `false` when acceptance cannot be confirmed: the sink blocked the
    /// message, the content was empty, or only a non-synchronous delegate is
    /// installed so delivery happens without confirmation. Downstream logic
    /// MUST NOT treat `false` as safe to acknowledge — a `false` return
    /// means do not ACK.
    ///
    /// For all other events, returns `true` when any delegate received the
    /// event and `false` when no delegate is installed.
    @MainActor
    @discardableResult
    private func deliverTransportEvent(
        _ event: TransportEvent
    ) -> TransportEventDeliveryOutcome {
        if case .messageReceived(let message) = event {
            if let synchronousDelegate =
                eventDelegate as? SynchronousMessageTransportEventDelegate {
                return synchronousDelegate
                    .didReceiveTransportMessageSynchronously(message)
                    ? .accepted
                    : .rejected
            }
            if let eventDelegate {
                eventDelegate.didReceiveTransportEvent(event)
                return .invokedUnconfirmed
            }
            if let synchronousDelegate =
                delegate as? SynchronousMessageTransportEventDelegate {
                return synchronousDelegate
                    .didReceiveTransportMessageSynchronously(message)
                    ? .accepted
                    : .rejected
            }
        }

        if let eventDelegate {
            eventDelegate.didReceiveTransportEvent(event)
            return .accepted
        } else {
            guard let delegate else { return .rejected }
            delegate.receiveTransportEvent(event)
            if case .messageReceived = event {
                return .invokedUnconfirmed
            }
            return .accepted
        }
    }

    func logBluetoothStatus(_ context: String) {
        scheduleBluetoothStatusSample(after: 0, context: context)
    }

    private func scheduleBluetoothStatusSample(after delay: TimeInterval, context: String) {
        #if os(iOS)
        // Sample the main-actor background budget first (async hop, never a
        // sync wait), then log from bleQueue off the cache — bleQueue must
        // never block on main (see captureBluetoothStatus).
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.refreshCachedBackgroundTimeRemaining()
            self.bleQueue.async { self.captureBluetoothStatus(context: context) }
        }
        #else
        bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.captureBluetoothStatus(context: context)
        }
        #endif
    }

    #if os(iOS)
    /// Main thread only (reads main-actor UIApplication state).
    private func refreshCachedBackgroundTimeRemaining() {
        dispatchPrecondition(condition: .onQueue(.main))
        let seconds = UIApplication.shared.backgroundTimeRemaining
        backgroundTimeLock.lock()
        _cachedBackgroundTimeRemaining = seconds
        backgroundTimeLock.unlock()
    }
    #endif

    private func captureBluetoothStatus(context: String) {
        assert(DispatchQueue.getSpecific(key: bleQueueKey) != nil, "captureBluetoothStatus must run on bleQueue")

        let centralState = centralManager?.state ?? .unknown
        let isScanning = centralManager?.isScanning ?? false
        let peripheralState = peripheralManager?.state ?? .unknown
        let isAdvertising = peripheralManager?.isAdvertising ?? false

        let candidateCount = radio.candidateCount
        let peerSummary = peerRegistry.read {
            (
                connected: $0.connectedCount,
                known: $0.count,
                candidates: candidateCount
            )
        }

        #if os(iOS)
        // INVARIANT: bleQueue must NEVER sync-dispatch to the main thread.
        // The main actor sync-waits on bleQueue along the send paths
        // (readLinkState), so a main.sync here completes an ABBA deadlock —
        // field-verified as a permanent freeze when a courier-drop storm put
        // an ack send (main → bleQueue.sync) up against a status capture
        // (bleQueue → main.sync). backgroundTimeRemaining is main-actor
        // state, so it is sampled on main and cached.
        let backgroundSeconds = cachedBackgroundTimeRemaining
        let backgroundDescriptor: String
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
        meshTopology.updateNeighbors(for: myPeerIDData, neighbors: peerRegistry.connectedRoutingData)
    }

    private func computeRoute(to peerID: PeerID) -> [Data]? {
        // Version-gated: every hop and the recipient must have been observed
        // speaking v2, since a v1-only node drops v2 frames on decode.
        meshTopology.computeRoute(
            from: myPeerIDData,
            to: routingData(for: peerID),
            maxHops: TransportConfig.bleSourceRouteMaxIntermediateHops,
            requiringVersion: 2
        )
    }

    private func applyRouteIfAvailable(_ packet: BitchatPacket, to recipient: PeerID) -> BitchatPacket {
        let now = Date()
        let route = BLESourceRouteOriginationPolicy.route(
            for: packet,
            to: recipient,
            localPeerIDData: myPeerIDData,
            isRecipientConnected: { self.isPeerConnected($0) },
            shouldAttemptRoute: { peer in
                onEngine {
                    self.sourceRouteFailures.shouldAttemptRoute(to: peer, now: now)
                }
            },
            computeRoute: { self.computeRoute(to: $0) }
        )
        guard let route else { return packet }
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
        onEngine {
            sourceRouteFailures.noteRoutedSend(to: recipient, now: now)
        }
        return signedPacket
    }

    private func routingPeer(from data: Data) -> PeerID? {
        PeerID(routingData: data)
    }

    // MARK: - Mesh Diagnostics (/ping, /trace, topology map)

    /// Sends a directed unencrypted ping probe (8-byte nonce + origin TTL).
    /// The completion fires exactly once on the main actor: with RTT/hops
    /// when the matching pong returns, or nil after the timeout window.
    func sendMeshPing(to peerID: PeerID, completion: @escaping @MainActor (MeshPingResult?) -> Void) {
        guard let generation = capturePanicLifecycleGeneration() else {
            return
        }
        messageQueue.async { [weak self] in
            guard let self,
                  self.isCurrentPanicLifecycleGeneration(generation),
                  let recipientData = peerID.toShort().routingData,
                  let payload = MeshPingPayload(
                    nonce: Data((0..<MeshPingPayload.nonceLength).map { _ in UInt8.random(in: .min ... .max) }),
                    originTTL: self.messageTTL
                  ) else {
                self?.notifyUI { [weak self] in
                    guard let self,
                          self.isCurrentPanicLifecycleGeneration(generation) else {
                        return
                    }
                    completion(nil)
                }
                return
            }
            let nonce = payload.nonce
            let packet = BitchatPacket(
                type: MessageType.ping.rawValue,
                senderID: self.myPeerIDData,
                recipientID: recipientData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload.encode(),
                signature: nil,
                ttl: self.messageTTL
            )
            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let expired = onEngine {
                    self.meshPings.expire(nonce: nonce)
                }
                guard let expired else { return }
                self.notifyUI { [weak self] in
                    guard let self,
                          self.isCurrentPanicLifecycleGeneration(
                              expired.lifecycleGeneration
                          ) else {
                        return
                    }
                    expired.completion(nil)
                }
            }
            onEngine {
                self.meshPings.register(
                    BLEMeshPingProbe(
                        peerID: PeerID(hexData: recipientData),
                        sentAt: Date(),
                        lifecycleGeneration: generation,
                        completion: completion,
                        timeout: timeout
                    ),
                    nonce: nonce
                )
            }
            self.engineScheduler.schedule(
                after: TransportConfig.meshPingTimeoutSeconds,
                execute: timeout
            )
            self.broadcastPacket(packet)
        }
    }

    /// Answers a ping addressed to us with a pong echoing its nonce; pings
    /// addressed elsewhere are left to the generic directed-relay path.
    ///
    /// `linkPeerID` is the directly connected peer that delivered the packet
    /// (the ingress link), NOT the packet's claimed sender: pings are
    /// unsigned, so `packet.senderID` is attacker-controlled, and keying the
    /// response budget on it would let one connected peer rotate forged
    /// sender IDs to emit unbounded pongs. The budget is per physical link;
    /// the pong still goes to the claimed sender (that's the protocol).
    private func handleMeshPing(_ packet: BitchatPacket, fromLink linkPeerID: PeerID) {
        guard packet.recipientID == myPeerIDData else { return }
        guard let ping = MeshPingPayload.decode(packet.payload) else {
            SecureLogger.debug("⚠️ Malformed ping via \(linkPeerID.id.prefix(8))…", category: .session)
            return
        }
        let allowed = onEngine {
            meshPings.shouldRespond(toLink: linkPeerID, now: Date())
        }
        guard allowed else {
            if logRateLimiter.shouldLog(key: "ping-limit:\(linkPeerID.id)") {
                SecureLogger.warning("🚫 Rate-limiting pings via link \(linkPeerID.id.prefix(8))…", category: .security)
            }
            return
        }
        guard let pong = MeshPingPayload(nonce: ping.nonce, originTTL: messageTTL) else { return }
        let reply = BitchatPacket(
            type: MessageType.pong.rawValue,
            senderID: myPeerIDData,
            recipientID: packet.senderID,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: pong.encode(),
            signature: nil,
            ttl: messageTTL
        )
        broadcastPacket(reply)
    }

    /// Resolves a pong against its outstanding probe. The unguessable echoed
    /// nonce plus the sender check bind the reply to the probed peer; hops
    /// come from the pong's TTL decrements on the return path.
    private func handleMeshPong(_ packet: BitchatPacket, from peerID: PeerID) {
        guard packet.recipientID == myPeerIDData else { return }
        guard let pong = MeshPingPayload.decode(packet.payload) else { return }
        let pending = onEngine {
            meshPings.resolve(nonce: pong.nonce, from: peerID)
        }
        guard let pending else { return }
        pending.timeout.cancel()
        let rttMs = Int((Date().timeIntervalSince(pending.sentAt) * 1000).rounded())
        let result = MeshPingResult(
            rttMs: max(0, rttMs),
            hops: MeshPingPayload.hopCount(originTTL: pong.originTTL, receivedTTL: packet.ttl)
        )
        notifyUI { [weak self] in
            guard let self,
                  self.isCurrentPanicLifecycleGeneration(
                      pending.lifecycleGeneration
                  ) else {
                return
            }
            pending.completion(result)
        }
    }

    /// Estimated intermediate hops toward `peerID`, BFS over gossiped
    /// bidirectionally-confirmed neighbor claims ([] = direct, nil = none).
    func computeMeshPath(to peerID: PeerID) -> [PeerID]? {
        refreshLocalTopology()
        if let route = computeRoute(to: peerID) {
            return route.compactMap { PeerID(routingData: $0) }
        }
        // Confirmed claims can lag a brand-new link (the peer's next announce
        // hasn't arrived yet); a live direct connection is still a known path.
        return isPeerConnected(peerID) ? [] : nil
    }

    /// Mesh graph for the topology map. Edges are advisory: announces cap
    /// neighbor lists at 10, so an edge claimed by either endpoint counts.
    func currentMeshTopology() -> MeshTopologySnapshot? {
        refreshLocalTopology()
        let claims = meshTopology.adjacencySnapshot()
        var nodes = Set<PeerID>()
        var edges = Set<MeshTopologyEdge>()
        for (source, neighbors) in claims {
            guard let sourcePeer = PeerID(routingData: source) else { continue }
            nodes.insert(sourcePeer)
            for neighborData in neighbors {
                guard let neighborPeer = PeerID(routingData: neighborData),
                      neighborPeer != sourcePeer else { continue }
                nodes.insert(neighborPeer)
                edges.insert(MeshTopologyEdge(sourcePeer, neighborPeer))
            }
        }
        nodes.insert(myPeerID)
        return MeshTopologySnapshot(
            localPeerID: myPeerID,
            nodes: nodes.sorted(),
            edges: edges.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
        )
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

    /// The current direct-link state for a peer. Engine-confined (bindings
    /// joined against physical liveness inside directLinkState).
    private func linkState(for peerID: PeerID) -> (hasPeripheral: Bool, hasCentral: Bool) {
        let state = directLinkState(for: peerID)
        return (state.hasPeripheral, state.hasCentral)
    }

    private func links(to peerID: PeerID?) -> Set<BLEIngressLinkID> {
        linkBindings.links(to: peerID)
    }



    /// Marks the exact physical ingress link that completed a fresh Noise
    /// handshake. An old session keyed only by peer ID is insufficient: a
    /// replayed announce can rebind an attacker's link to that ID.
    /// Engine-confined.
    private func markNoiseAuthenticatedIngressLink(for packet: BitchatPacket, peerID: PeerID) {
        guard let link = ingressLinks.link(for: packet) else { return }
        guard linkBindings.boundPeer(for: link) == peerID else { return }
        linkAuth.markAuthenticated(link, owner: peerID)
    }

    private func isNoiseAuthenticatedIngressLink(for packet: BitchatPacket, peerID: PeerID) -> Bool {
        guard let link = ingressLinks.link(for: packet) else { return false }
        return linkAuth.isAuthenticated(link, for: peerID) && linkBindings.boundPeer(for: link) == peerID
    }

    private func hasCurrentNoiseAuthenticatedLink(to peerID: PeerID) -> Bool {
        !currentNoiseAuthenticatedLinks(to: peerID).isEmpty
    }

    private func currentNoiseAuthenticatedLinks(to peerID: PeerID) -> Set<BLEIngressLinkID> {
        Set(linkAuth.links(ownedBy: peerID).filter { link in
            linkBindings.boundPeer(for: link) == peerID
        })
    }

    /// A peer-level session can outlive the physical link that established it.
    /// Revalidate a fresh direct link with an ordinary XX exchange, retiring
    /// cached sending keys atomically before message 1 can leave.
    ///
    /// Takes the already-resolved ingress link. Engine-confined: it runs
    /// inside the rebind's engine slot, so no observer can see the new
    /// binding while a cached peer-level sender is still considered
    /// established.
    private func refreshNoiseSessionForVerifiedDirectLink(
        link: BLEIngressLinkID,
        peerID: PeerID
    ) {
        let hasEstablishedSession = noiseService.hasEstablishedSession(with: peerID)
        let authenticatedPeerLinks = currentNoiseAuthenticatedLinks(to: peerID)
        let shouldRevalidate: Bool
        if linkBindings.boundPeer(for: link) == peerID {
            shouldRevalidate = linkAuth.shouldRevalidate(
                on: link,
                for: peerID,
                hasEstablishedSession: hasEstablishedSession,
                hasAuthenticatedPeerLink: !authenticatedPeerLinks.isEmpty,
                now: Date()
            )
        } else {
            shouldRevalidate = false
        }
        guard shouldRevalidate else { return }

        SecureLogger.info(
            "🔄 Revalidating cached Noise session on fresh direct link to \(peerID.id.prefix(8))…",
            category: .session
        )
        initiateNoiseReconnectHandshake(with: peerID)
    }
    
    private func configureNoiseServiceCallbacks(for service: NoiseEncryptionService) {
        service.onPeerAuthenticatedWithGeneration = { [weak self] peerID, fingerprint, generation in
            SecureLogger.debug("🔐 Noise session authenticated with \(peerID.id.prefix(8))…, fingerprint: \(fingerprint.prefix(16))…")
            // Authentication can be reported while an initiator is still
            // returning XX message 3. Serialize generation-bound state and
            // every post-handshake drain behind the handshake packet handler.
            self?.messageQueue.async { [weak self] in
                self?.handleNoisePeerAuthenticated(
                    peerID: peerID,
                    fingerprint: fingerprint,
                    sessionGeneration: generation
                )
            }
        }
        service.onRekeyHandshakeReady = {
            [weak self, weak service] peerID, initiation in
            self?.messageQueue.async {
                [weak self, weak service] in
                guard let self,
                      let service,
                      self.noiseService === service else {
                    return
                }
                self.noteNoiseSessionCleared(for: peerID)
                guard let message = service.claimHandshakeInitiation(
                    initiation,
                    for: peerID
                ) else {
                    return
                }
                self.broadcastNoiseHandshake(message, to: peerID)
            }
        }
        service.onHandshakeRecoveryRequired = {
            [weak self, weak service] request in
            guard let self, let service else { return }
            #if DEBUG
            self._test_beforeHandshakeRecoveryEnqueued?(request.peerID)
            #endif
            self.messageQueue.async {
                [weak self, weak service] in
                guard let self,
                      let service,
                      self.noiseService === service else {
                    return
                }
                let peerID = request.peerID
                guard self.isPeerReachable(peerID) else {
                    service.cancelHandshakeRecovery(request)
                    return
                }

                do {
                    guard let preparation =
                        try service.prepareHandshakeRecovery(request) else {
                        return
                    }
                    switch preparation {
                    case .ordinary(let initiation):
                        self.noteNoiseSessionCleared(for: peerID)
                        guard let handshakeData =
                            service.claimHandshakeInitiation(
                                initiation,
                                for: peerID
                            ) else {
                            return
                        }
                        self.broadcastNoiseHandshake(
                            handshakeData,
                            to: peerID
                        )
                    case .transferred:
                        return
                    }
                } catch {
                    SecureLogger.error(
                        "Failed to prepare handshake recovery with \(peerID.id.prefix(8))…: \(error)",
                        category: .session
                    )
                }
            }
        }
        service.onSessionRestoredWithGeneration = { [weak self, weak service] peerID, generation, reason in
            guard let self, let service else { return }
            // The manager makes restored keys visible atomically. Reconcile
            // transport state and queued sends as the next serialized phase.
            self.messageQueue.async { [weak self, weak service] in
                guard let self,
                      let service,
                      self.noiseService === service,
                      let fingerprint = service.getPeerFingerprint(peerID) else {
                    return
                }
                SecureLogger.debug(
                    "🔐 Restored quarantined Noise session with \(peerID.id.prefix(8))…",
                    category: .session
                )
                // Re-enter the same generation-bound transition used after a
                // successful handshake to restore authenticated protocol
                // state. Only a terminal restore may also drain the PM and
                // typed-payload queues: after a responder timeout the
                // counterpart may have completed the replacement handshake
                // and discarded the restored keys, so encrypting the queues
                // under them would lose every message silently. The mandatory
                // convergence retry that accompanies the restore drains them
                // under the new session instead (any establishment does).
                self.handleNoisePeerAuthenticated(
                    peerID: peerID,
                    fingerprint: fingerprint,
                    sessionGeneration: generation,
                    deferOutboundUntilConvergence: reason == .pendingConvergence
                )
            }
        }
    }

    private func handleNoisePeerAuthenticated(
        peerID: PeerID,
        fingerprint: String,
        sessionGeneration generation: UUID,
        deferOutboundUntilConvergence: Bool = false
    ) {
        // Engine-only: the store transition below runs inside the noise
        // manager's critical section while this engine slot stays blocked.
        // The store is a leaf lock, so that nesting is safe — but nothing in
        // that closure may sync-re-enter the engine (self-deadlock).
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(messageQueue))
        #endif
        let normalizedPeerID = peerID.toShort()
        // The generation lease serializes this transition against session
        // replacement; nil-inside-nil distinguishes a lost lease (outer)
        // from the same-generation reconciliation path (inner).
        guard let leased = noiseService.withCurrentSessionGeneration(
            for: normalizedPeerID,
            expected: generation,
            {
                privateMediaSessions.beginAuthenticatedGeneration(
                    for: normalizedPeerID,
                    fingerprint: fingerprint,
                    generation: generation
                )
            }
        ) else { return }

        guard let fresh = leased else {
            // A quarantined transport restored the same cryptographic
            // generation. Its capability proof and announce state never
            // became stale; only work queued while outbound keys were paused
            // needs one idempotent ready transition. Retrying the bounded
            // early-ciphertext queue is receive-side and therefore always
            // safe under the restored keys.
            noisePacketHandler.handleSessionAuthenticated(normalizedPeerID)
            #if DEBUG
            _test_onPrivateMediaSessionReconciled?(normalizedPeerID)
            #endif
            if deferOutboundUntilConvergence {
                // Timeout-restore: the counterpart may have completed the
                // replacement handshake and discarded these keys, so
                // encrypting the parked queues here would lose them silently.
                // The restore's mandatory convergence retry — or any later
                // handshake the reconnect policy initiates — re-enters this
                // transition with a fresh generation and drains them under
                // keys both sides hold. The flag also holds the proof
                // watchdog's drain to the same rule.
                privateMediaSessions.setOutboundDeferredUntilConvergence(normalizedPeerID)
                return
            }
            privateMediaSessions.clearOutboundDeferredUntilConvergence(normalizedPeerID)
            sendPendingMessagesAfterHandshake(for: normalizedPeerID)
            sendPendingNoisePayloadsAfterHandshake(for: normalizedPeerID)
            return
        }

        completePrivateMediaPolicyResolution(fresh.rejected, with: .blockedDowngrade)
        schedulePrivateMediaProofTimeout(
            for: normalizedPeerID,
            fingerprint: fingerprint,
            sessionGeneration: generation,
            nonce: fresh.watchdogNonce
        )
        // Cross-link delivery can put ciphertext sent immediately after
        // message 3 ahead of message 3 itself. Retry the bounded queue only
        // after this generation's transport state has been fully installed.
        noisePacketHandler.handleSessionAuthenticated(normalizedPeerID)

        if deferOutboundUntilConvergence {
            // Timeout-restore: the session is back for receive purposes and
            // the generation-bound protocol state above is rebuilt, but the
            // counterpart may already hold replacement keys that discarded
            // this generation's. Encrypting the pending queues here would
            // lose them silently, so leave them parked: the restore's
            // mandatory convergence retry — or any later handshake the
            // reconnect policy initiates — re-enters this transition with a
            // fresh generation and drains them under keys both sides hold.
            // The flag also holds the proof watchdog's drain to the same
            // rule — its timeout can fire while this restore is current.
            privateMediaSessions.setOutboundDeferredUntilConvergence(normalizedPeerID)
            #if DEBUG
            _test_onPrivateMediaSessionReconciled?(normalizedPeerID)
            #endif
            return
        }
        privateMediaSessions.clearOutboundDeferredUntilConvergence(normalizedPeerID)

        // `onPeerAuthenticated` can fire while the initiator is returning XX
        // message 3. This callback is queued behind the handshake handler, so
        // message 3 is broadcast first. Both peers also send one idempotent
        // echo after receiving the other's state to recover cross-link races.
        sendAuthenticatedPeerState(to: normalizedPeerID, echo: false)
        #if DEBUG
        _test_onPrivateMediaSessionReconciled?(normalizedPeerID)
        #endif
        sendPendingMessagesAfterHandshake(for: normalizedPeerID)
        sendPendingNoisePayloadsAfterHandshake(for: normalizedPeerID)
        sendAnnounce(forceSend: true)
    }

    private func sendAuthenticatedPeerState(to peerID: PeerID, echo: Bool) {
        let normalizedPeerID = peerID.toShort()
        guard privateMediaSessions.markPeerStateSend(for: normalizedPeerID, echo: echo) else { return }

        let capabilities = localIdentityState.snapshot().advertisedCapabilities
        let state = AuthenticatedPeerStatePacket(
            capabilities: capabilities,
            signingPublicKey: noiseService.getSigningPublicKeyData()
        )
        guard let payload = BLENoisePayloadFactory.authenticatedPeerState(state) else {
            SecureLogger.error("Failed to encode authenticated peer state", category: .security)
            return
        }
        sendNoisePayload(payload, to: normalizedPeerID)
    }

    private func handleAuthenticatedPeerState(
        _ payload: Data,
        from peerID: PeerID,
        sessionGeneration generation: UUID
    ) {
        // Engine-only, like handleNoisePeerAuthenticated: the closure below
        // runs on the noise manager's queue while this engine slot stays
        // blocked, so it accesses engine-owned state directly instead of
        // sync-re-entering the engine (self-deadlock).
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(messageQueue))
        #endif
        let normalizedPeerID = peerID.toShort()
        guard let state = AuthenticatedPeerStatePacket.decode(from: payload) else {
            SecureLogger.warning(
                "Ignoring malformed authenticated peer state from \(normalizedPeerID.id.prefix(8))…",
                category: .security
            )
            return
        }
        guard let fingerprint = noiseService.getPeerFingerprint(normalizedPeerID),
              let publicKey = noiseService.getPeerPublicKeyData(normalizedPeerID),
              publicKey.sha256Fingerprint().caseInsensitiveCompare(fingerprint) == .orderedSame else {
            SecureLogger.warning(
                "Ignoring peer state without a matching authenticated Noise identity",
                category: .security
            )
            return
        }
        guard let application = noiseService.withCurrentSessionGeneration(
            for: normalizedPeerID,
            expected: generation,
            {
                () -> (accepted: Bool, completions: [@MainActor (PrivateMediaSendPolicy) -> Void]) in
                guard privateMediaSessions.currentGeneration(for: normalizedPeerID) == generation else {
                    return (false, [])
                }

                // The generation lease (plus the engine slot this section
                // holds) prevents rekey/session promotion from interleaving
                // between validation and these durable mutations.
                identityManager.bindAuthenticatedSigningPublicKey(
                    state.signingPublicKey,
                    fingerprint: fingerprint
                )
                identityManager.upsertCryptographicIdentity(
                    fingerprint: fingerprint,
                    noisePublicKey: publicKey,
                    signingPublicKey: state.signingPublicKey,
                    claimedNickname: nil
                )
                if state.capabilities.contains(.privateMedia) {
                    identityManager.markPrivateMediaCapable(fingerprint: fingerprint)
                }

                peerRegistry.mutate {
                    $0.bindAuthenticatedSigningPublicKey(
                        state.signingPublicKey,
                        for: normalizedPeerID
                    )
                }
                guard let completions = privateMediaSessions.applyAuthenticatedPeerState(
                    for: normalizedPeerID,
                    fingerprint: fingerprint,
                    generation: generation,
                    capabilities: state.capabilities
                ) else {
                    return (false, [])
                }
                return (true, completions)
            }
        ), application.accepted else { return }

        // One bounded echo makes initiator/responder proof ordering converge
        // even when message 3 and the first proof take different mesh links.
        sendAuthenticatedPeerState(to: normalizedPeerID, echo: true)
        let policy = privateMediaSendPolicy(to: normalizedPeerID)
        sendPendingNoisePayloadsAfterHandshake(for: normalizedPeerID)
        completePrivateMediaPolicyResolution(application.completions, with: policy)
    }

    private func noteNoiseSessionCleared(for peerID: PeerID) {
        let normalizedPeerID = peerID.toShort()
        let reset = privateMediaSessions.clearSession(for: normalizedPeerID)
        if let reset {
            schedulePrivateMediaProofTimeout(
                for: normalizedPeerID,
                fingerprint: reset.fingerprint,
                sessionGeneration: nil,
                nonce: reset.nonce
            )
        }
    }

    private func clearNoiseSession(for peerID: PeerID) {
        noiseService.clearSession(for: peerID)
        noteNoiseSessionCleared(for: peerID)
    }

    /// Swaps `myPeerID`/`myPeerIDData` to match the current Noise identity.
    /// The swap runs as a `messageQueue` barrier so in-flight work items that
    /// read the identity (e.g. `sendMessage` building packets) complete
    /// against the old value and everything after sees the new one atomically.
    /// Callers (init, panic reset on the main thread) are never on
    /// `messageQueue`; the re-entrancy check keeps any future on-queue caller
    /// from deadlocking.
    private func refreshPeerIdentity() {
        onEngine {
            let fingerprint = noiseService.getIdentityFingerprint()
            localIdentityState.replacePeerIdentity(
                with: PeerID(str: fingerprint.prefix(16))
            )
            meshTopology.reset()
        }
    }


    
    private func sendNoisePayload(_ typedPayload: Data, to peerID: PeerID) {
        // Hop like sendMessage: the Transport-facing wrappers (verify/vouch/
        // group payloads) call this from the main actor, and the send path
        // sync-waits on bleQueue for link state.
        if DispatchQueue.getSpecific(key: messageQueueKey) == nil {
            messageQueue.async { [weak self] in
                self?.sendNoisePayload(typedPayload, to: peerID)
            }
            return
        }
        guard noiseService.hasEstablishedSession(with: peerID) else {
            // No established session yet - queue the payload synchronously
            // before initiating a handshake
            // to prevent race where fast handshake completion drains empty queue
            onEngine {
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

    private func makeEncryptedNoisePacket(
        _ typedPayload: Data,
        to peerID: PeerID,
        requiresAuthenticatedPrivateMediaReceipts: Bool = false
    ) throws -> BitchatPacket {
        let encrypted: Data
        let isPrivateFile = NoisePayloadType.isPrivateFile(rawValue: typedPayload.first)
        if isPrivateFile {
            let provenGeneration = privateMediaSessions.provenGeneration(
                for: peerID,
                requireReceipts: requiresAuthenticatedPrivateMediaReceipts
            )
            guard let provenGeneration else {
                throw NoiseEncryptionError.sessionNotEstablished
            }
            encrypted = try noiseService.encryptPrivateFilePayload(
                typedPayload,
                for: peerID,
                sessionGeneration: provenGeneration
            )
        } else {
            encrypted = try noiseService.encrypt(typedPayload, for: peerID)
        }
        return BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: myPeerIDData,
            recipientID: Data(hexString: peerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: encrypted,
            signature: nil,
            ttl: messageTTL,
            // v1 has a 16-bit payload length; finalized media can exceed it.
            version: isPrivateFile ? 2 : 1
        )
    }

    // MARK: Courier Store-and-Forward

    /// Seal `content` for the recipient and hand the envelope to the given
    /// couriers for physical delivery. When a verified one-time prekey bundle
    /// is cached for the recipient, sealing targets one of its prekeys
    /// (forward secret, envelope v2); otherwise it falls back to their static
    /// key (one-way Noise X, v1) exactly as before. Returns false when no
    /// courier is connected, the payload cannot be built, or sealing fails;
    /// link writes are queued asynchronously after the envelope is ready.
    func sendCourierMessage(_ content: String, messageID: String, recipientNoiseKey: Data, via couriers: [PeerID]) -> Bool {
        let connected = couriers.filter { isPeerConnected($0) }
        guard !connected.isEmpty,
              let typedPayload = BLENoisePayloadFactory.privateMessage(content: content, messageID: messageID) else {
            return false
        }

        let payload: Data
        do {
            let now = Date()
            let sealed: Data
            let prekeyID: UInt32?
            if let prekey = assignRecipientPrekey(messageID: messageID, recipientNoiseKey: recipientNoiseKey) {
                sealed = try noiseService.sealPrekeyPayload(typedPayload, recipientPrekey: prekey)
                prekeyID = prekey.id
            } else {
                sealed = try noiseService.sealCourierPayload(typedPayload, recipientStaticKey: recipientNoiseKey)
                prekeyID = nil
            }
            let envelope = CourierEnvelope(
                recipientTag: CourierEnvelope.recipientTag(
                    noiseStaticKey: recipientNoiseKey,
                    epochDay: CourierEnvelope.epochDay(for: now)
                ),
                expiry: UInt64((now.timeIntervalSince1970 + CourierEnvelope.maxLifetimeSeconds) * 1000),
                ciphertext: sealed,
                copies: TransportConfig.courierInitialCopies,
                prekeyID: prekeyID
            )
            guard let encoded = envelope.encode() else { return false }
            payload = encoded
        } catch {
            SecureLogger.error("Failed to seal courier envelope: \(error)", category: .encryption)
            return false
        }

        messageQueue.async { [weak self] in
            guard let self else { return }
            for courier in connected {
                SecureLogger.debug("📦 Depositing courier envelope with \(courier.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
                self.sendPacketDirected(self.makeCourierPacket(payload, to: courier), to: courier)
            }
        }
        return true
    }

    // MARK: Courier over the bridge

    /// Seals `content` into a courier envelope for relay parking (a bridge
    /// courier drop). Same sealing rules as `sendCourierMessage` — prekey
    /// (v2) when a verified bundle is cached, static Noise X (v1) otherwise —
    /// but carry-only: a relay copy never sprays.
    func sealBridgeCourierEnvelope(_ content: String, messageID: String, recipientNoiseKey: Data) -> CourierEnvelope? {
        guard let typedPayload = BLENoisePayloadFactory.privateMessage(content: content, messageID: messageID) else {
            return nil
        }
        do {
            let now = Date()
            let sealed: Data
            let prekeyID: UInt32?
            if let prekey = assignRecipientPrekey(messageID: messageID, recipientNoiseKey: recipientNoiseKey) {
                sealed = try noiseService.sealPrekeyPayload(typedPayload, recipientPrekey: prekey)
                prekeyID = prekey.id
            } else {
                sealed = try noiseService.sealCourierPayload(typedPayload, recipientStaticKey: recipientNoiseKey)
                prekeyID = nil
            }
            return CourierEnvelope(
                recipientTag: CourierEnvelope.recipientTag(
                    noiseStaticKey: recipientNoiseKey,
                    epochDay: CourierEnvelope.epochDay(for: now)
                ),
                expiry: UInt64((now.timeIntervalSince1970 + CourierEnvelope.maxLifetimeSeconds) * 1000),
                ciphertext: sealed,
                copies: 1,
                prekeyID: prekeyID
            )
        } catch {
            SecureLogger.error("Failed to seal bridge courier envelope: \(error)", category: .encryption)
            return nil
        }
    }

    /// Opens a courier envelope that arrived as a bridge drop (relay fetch,
    /// not a directed mesh packet). Returns false when the rotating tag does
    /// not match our static key — a drop for someone else, or a stale tag.
    /// The inner Noise X seal authenticates the sender; there is no packet
    /// signature to check on this path.
    @discardableResult
    func openBridgedCourierEnvelope(_ envelope: CourierEnvelope) -> Bool {
        guard !envelope.isExpired else { return false }
        let myKey = noiseService.getStaticPublicKeyData()
        guard CourierEnvelope.candidateTags(noiseStaticKey: myKey, around: Date()).contains(envelope.recipientTag) else {
            return false
        }
        return openCourierEnvelope(envelope)
    }

    /// Hands a bridge-fetched envelope directly to the matching local peer
    /// as a directed courier packet. Delivery-only by design: the recipient's
    /// tag matched, so this never lands in a stranger's carry quota.
    /// Returns true only if a current Noise-authenticated physical link
    /// accepted the packet; a stale peer-level session, reachability record,
    /// replay-rebound link, or process-local spool is not delivery.
    @discardableResult
    func deliverBridgedEnvelope(_ envelope: CourierEnvelope, to peerID: PeerID) -> Bool {
        guard let payload = envelope.encode() else { return false }
        let packet = makeCourierPacket(payload, to: peerID)
        return onEngine {
            // Engine slot: the auth-link check and the directed send see one
            // consistent view of the identity domain.
            guard hasCurrentNoiseAuthenticatedLink(to: peerID) else { return false }
            return sendPacketDirected(
                packet,
                to: peerID,
                requireDirectPeerLink: true,
                requireNoiseAuthenticatedPeerLink: true
            )
        }
    }

    /// Our own Noise static public key (for computing our courier tags).
    func myNoiseStaticPublicKey() -> Data {
        noiseService.getStaticPublicKeyData()
    }

    /// Verified reachable peers with known Noise keys — the set a bridge
    /// gateway watches courier drops for.
    func verifiedPeersWithNoiseKeys() -> [(peerID: PeerID, noiseKey: Data)] {
        let now = Date()
        return onEngine {
            peerRegistry.snapshotByID.values.compactMap { info in
                guard info.isVerifiedNickname,
                      let key = info.noisePublicKey,
                      peerRegistry.isReachable(info.peerID, now: now) else { return nil }
                return (info.peerID, key)
            }
        }
    }

    /// The prekey to seal a courier message with, or nil to fall back to
    /// static sealing. The real signal is a verified, unexpired bundle with a
    /// spare prekey; the advertised `.prekeys` capability only acts as a veto
    /// for peers we currently see on the mesh (a cached bundle can outlive a
    /// peer's downgrade to a build that no longer holds the privates).
    /// Re-deposits of the same message reuse its assigned prekey, so one
    /// message consumes exactly one prekey ID regardless of courier count.
    private func assignRecipientPrekey(messageID: String, recipientNoiseKey: Data) -> PrekeyBundle.Prekey? {
        let shortID = PeerID(publicKey: recipientNoiseKey)
        let knownOnMesh = peerRegistry.info(for: shortID) != nil
        if knownOnMesh, !peerCapabilities(shortID).contains(.prekeys) {
            return nil
        }
        return prekeyBundleStore.assignPrekey(messageID: messageID, recipientNoiseKey: recipientNoiseKey)
    }

    private func makeCourierPacket(_ payload: Data, to peerID: PeerID) -> BitchatPacket {
        let packet = BitchatPacket(
            type: MessageType.courierEnvelope.rawValue,
            senderID: myPeerIDData,
            recipientID: Data(hexString: peerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: messageTTL
        )
        // Signed so a courier can authenticate the depositor before carrying
        // mail under their quota. Handover to the recipient doesn't need the
        // packet signature — the inner Noise X seal authenticates the sender.
        return noiseService.signPacket(packet) ?? packet
    }

    /// Handles both courier roles for an incoming envelope addressed to us:
    /// recipient (the rotating tag matches our static key → open and deliver)
    /// or courier (a trusted peer is depositing mail for someone else → store).
    private func handleCourierEnvelope(_ packet: BitchatPacket, from peerID: PeerID) {
        // Directed packets only; envelopes addressed elsewhere ride the
        // generic relay path untouched.
        guard packet.recipientID == myPeerIDData else { return }
        guard let envelope = CourierEnvelope.decode(packet.payload), !envelope.isExpired else { return }

        let myKey = noiseService.getStaticPublicKeyData()
        if CourierEnvelope.candidateTags(noiseStaticKey: myKey, around: Date()).contains(envelope.recipientTag) {
            openCourierEnvelope(envelope)
        } else {
            acceptCourierDeposit(envelope, from: peerID, packet: packet)
        }
    }

    @discardableResult
    private func openCourierEnvelope(_ envelope: CourierEnvelope) -> Bool {
        do {
            let typedPayload: Data
            let senderStaticKey: Data
            if let prekeyID = envelope.prekeyID {
                // Envelope v2: sealed to one of our one-time prekeys. Opening
                // consumes the prekey (48h redelivery grace), which shrinks our
                // published bundle under a strictly newer generatedAt. Re-gossip
                // so peers replace their cached copy and stop assigning the
                // consumed ID before the grace lapses; force the broadcast when
                // the batch also topped back up (low-water), otherwise let the
                // rebroadcast throttle coalesce bursts.
                let opened = try noiseService.openPrekeyPayload(envelope.ciphertext, prekeyID: prekeyID)
                (typedPayload, senderStaticKey) = (opened.payload, opened.senderStaticKey)
                if opened.consumedPrekey {
                    let replenished = noiseService.replenishPrekeysIfNeeded()
                    sendPrekeyBundle(force: replenished)
                }
            } else {
                (typedPayload, senderStaticKey) = try noiseService.openCourierPayload(envelope.ciphertext)
            }
            guard let typeRaw = typedPayload.first,
                  let payloadType = NoisePayloadType(rawValue: typeRaw),
                  payloadType == .privateMessage else {
                SecureLogger.warning("⚠️ Courier envelope carried unsupported payload type", category: .session)
                return true // decrypted but deterministically unsupported
            }
            let payload = Data(typedPayload.dropFirst())
            guard let innerMessageID = PrivateMessagePacket.decode(from: payload)?.messageID else {
                SecureLogger.warning("⚠️ Courier envelope carried undecodable private message", category: .session)
                return true // decrypted but deterministically malformed
            }
            // Redundant copies of one message arrive as distinct envelopes
            // (fresh seal each: mesh couriers, bridge drops across relays),
            // so dedup here on the inner message ID — before delivery, ack,
            // and handshake work. A duplicate costs only the decrypt above
            // and at most one ack ever goes out per message ID.
            let firstOpen = onEngine {
                openedCourierMessageIDs.insert(innerMessageID)
            }
            guard firstOpen else {
                SecureLogger.debug("📦 Dropping duplicate courier envelope for message \(innerMessageID.prefix(8))…", category: .session)
                return true
            }
            // Couriered mail arrives while the sender is absent, so the UI's
            // block check can't resolve their fingerprint from a live session.
            // Gate here, where the full static key is in hand.
            guard !identityManager.isBlocked(fingerprint: senderStaticKey.sha256Fingerprint()) else {
                SecureLogger.debug("🚫 Dropping courier envelope from blocked sender", category: .security)
                return true
            }
            // A present sender resolves to their live mesh thread via the
            // derived short ID. An absent sender — the usual courier case —
            // uses the full noise-key ID so the message lands on the stable
            // favorite conversation instead of an unresolvable short-ID
            // thread labeled "Unknown".
            let shortID = PeerID(publicKey: senderStaticKey)
            let isKnownOnMesh = peerRegistry.info(for: shortID) != nil
            let senderPeerID = isKnownOnMesh ? shortID : PeerID(hexData: senderStaticKey)
            SecureLogger.debug("📦 Opened courier envelope from \(senderPeerID.id.prefix(8))…", category: .session)
            sfMetrics?.record(.courierOpened)
            notifyUI { [weak self] in
                self?.deliverTransportEvent(.noisePayloadReceived(
                    peerID: senderPeerID,
                    type: payloadType,
                    payload: payload,
                    timestamp: Date()
                ))
            }
            return true
        } catch {
            // Tag collision or stale key: not addressed to us after all.
            SecureLogger.debug("📦 Courier envelope failed to open: \(error)", category: .encryption)
            return false
        }
    }

    private func acceptCourierDeposit(_ envelope: CourierEnvelope, from peerID: PeerID, packet: BitchatPacket) {
        // A deposit must come from its depositor over the direct link: the
        // claimed sender has to be the ingress peer, and the packet signature
        // has to verify against that peer's announced signing key. Otherwise
        // an untrusted sender could route an envelope through any trusted
        // neighbor and have us carry it under the neighbor's quota.
        guard PeerID(hexData: packet.senderID) == peerID else {
            SecureLogger.debug("📦 Courier deposit rejected: relayed envelope claims sender \(PeerID(hexData: packet.senderID).id.prefix(8))… but arrived from \(peerID.id.prefix(8))…", category: .security)
            return
        }
        let depositorInfo = peerRegistry.info(for: peerID)
        guard let depositorKey = depositorInfo?.noisePublicKey else {
            SecureLogger.debug("📦 Courier deposit from unknown peer \(peerID.id.prefix(8))… rejected", category: .session)
            return
        }
        guard let signingKey = depositorInfo?.signingPublicKey,
              noiseService.verifyPacketSignature(packet, publicKey: signingKey) else {
            SecureLogger.debug("📦 Courier deposit from \(peerID.id.prefix(8))… rejected (missing/invalid signature)", category: .security)
            return
        }
        let isVerifiedPeer = depositorInfo?.isVerifiedNickname ?? false
        let store = courierStore
        let policy = courierDepositPolicy
        let metrics = sfMetrics
        notifyUI {
            guard let tier = policy(depositorKey, isVerifiedPeer) else {
                SecureLogger.debug("📦 Courier deposit from \(peerID.id.prefix(8))… rejected (neither favorite nor verified)", category: .session)
                return
            }
            if store.deposit(envelope, from: depositorKey, tier: tier) {
                SecureLogger.debug("📦 Carrying courier envelope deposited by \(peerID.id.prefix(8))… (\(tier.rawValue))", category: .session)
                metrics?.record(.courierAccepted)
            }
        }
    }

    /// Hand over any carried envelopes addressed to a peer we just heard from.
    private func deliverCourierMail(to peerID: PeerID, noiseKey: Data) {
        let metrics = sfMetrics
        let accepted = courierStore.handoverEnvelopes(for: noiseKey) { [weak self] envelope in
            guard let self,
                  let payload = envelope.encode(),
                  self.sendPacketDirected(
                      self.makeCourierPacket(payload, to: peerID),
                      to: peerID,
                      requireDirectPeerLink: true,
                      requireNoiseAuthenticatedPeerLink: true
                  ) else {
                return false
            }
            metrics?.record(.courierHandedOver)
            return true
        }
        if accepted > 0 {
            SecureLogger.debug("📦 Handed over \(accepted) courier envelope(s) to \(peerID.id.prefix(8))…", category: .session)
        }
    }

    /// Speculative handover toward a recipient heard only via a relayed
    /// announce: the envelope floods the mesh as a directed packet (relays
    /// treat it like a directed DM). Non-destructive — the carried copy stays
    /// until a direct handover or expiry, throttled per envelope so repeated
    /// announces don't re-flood.
    private func deliverCourierMailRemotely(to peerID: PeerID, noiseKey: Data) {
        let envelopes = courierStore.envelopesForRemoteHandover(
            recipientNoiseKey: noiseKey,
            cooldown: TransportConfig.courierRemoteHandoverCooldownSeconds
        )
        guard !envelopes.isEmpty else { return }
        SecureLogger.debug("📦 Remote handover: flooding \(envelopes.count) envelope(s) toward \(peerID.id.prefix(8))…", category: .session)
        for envelope in envelopes {
            guard let payload = envelope.encode() else { continue }
            broadcastPacket(makeCourierPacket(payload, to: peerID))
            sfMetrics?.record(.courierRemoteHandover)
        }
    }

    /// Spray-and-wait: split copy budgets with another courier we just
    /// encountered, so carried mail diffuses through a moving crowd instead
    /// of riding a single carrier. Only favorites and verified peers qualify,
    /// mirroring the deposit policy they would apply to us.
    private func sprayCourierMail(to peerID: PeerID, noiseKey: Data, isVerifiedPeer: Bool) {
        let store = courierStore
        let metrics = sfMetrics
        let sendSpray: () -> Void = { [weak self] in
            guard let self else { return }
            let accepted = store.transferSprayCopies(to: noiseKey) { envelope in
                guard let payload = envelope.encode(),
                      self.sendPacketDirected(
                          self.makeCourierPacket(payload, to: peerID),
                          to: peerID,
                          requireDirectPeerLink: true,
                          requireNoiseAuthenticatedPeerLink: true
                      ) else {
                    return false
                }
                metrics?.record(.courierSprayed)
                return true
            }
            if accepted > 0 {
                SecureLogger.debug("📦 Sprayed \(accepted) envelope copy(ies) to courier \(peerID.id.prefix(8))…", category: .session)
            }
        }
        let policy = courierDepositPolicy
        notifyUI {
            // Same trust gate as deposits: don't hand mail to a peer who
            // would reject it from us.
            guard policy(noiseKey, isVerifiedPeer) != nil else { return }
            sendSpray()
        }
    }

    // MARK: One-Time Prekey Bundles

    /// Broadcasts our signed prekey bundle and tracks it for gossip sync.
    /// Unforced sends (piggybacked on announces) are throttled — gossip does
    /// the spreading, the broadcast just keeps our own gossip entry fresh.
    /// Forced sends (bundle changed after consumption) go immediately.
    private func sendPrekeyBundle(force: Bool = false) {
        let now = Date()
        let shouldSend: Bool = onEngine {
            if !force,
               let last = lastPrekeyBundleSentAt,
               now.timeIntervalSince(last) < TransportConfig.prekeyBundleRebroadcastSeconds {
                return false
            }
            lastPrekeyBundleSentAt = now
            return true
        }
        guard shouldSend else { return }
        guard let bundle = noiseService.currentPrekeyBundle(),
              let payload = bundle.encode() else {
            SecureLogger.error("❌ Failed to build prekey bundle", category: .security)
            return
        }
        let packet = BitchatPacket(
            type: MessageType.prekeyBundle.rawValue,
            senderID: myPeerIDData,
            recipientID: nil,
            timestamp: UInt64(now.timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: messageTTL
        )
        guard let signedPacket = noiseService.signPacket(packet) else {
            SecureLogger.error("❌ Failed to sign prekey bundle packet", category: .security)
            return
        }
        if DispatchQueue.getSpecific(key: messageQueueKey) != nil {
            broadcastPacket(signedPacket)
        } else {
            messageQueue.async { [weak self] in
                self?.broadcastPacket(signedPacket)
            }
        }
        gossipSyncManager?.onPublicPacketSeen(signedPacket)
    }

    /// Ingests a gossiped prekey bundle. Attribution is layered: the outer
    /// packet must originate from the bundle owner (fabricated sender IDs, used
    /// to multiply cache/gossip entries, are rejected), and BOTH the inner
    /// bundle signature and the outer packet signature must verify against the
    /// owner's announce-bound signing key. Verifying the outer packet — whose
    /// signed bytes cover senderID and timestamp — stops a valid bundle from
    /// being replayed under a fresh timestamp or spoofed sender to pass
    /// freshness or poison attribution. Only after that does the packet enter
    /// our own gossip store, so we never help spread a bundle we couldn't
    /// attribute.
    private func handlePrekeyBundle(_ packet: BitchatPacket, from peerID: PeerID) {
        guard let bundle = PrekeyBundle.decode(packet.payload) else {
            SecureLogger.debug("🔑 Ignoring malformed prekey bundle from \(peerID.id.prefix(8))…", category: .security)
            return
        }
        // Our own bundle is tracked at send time; a copy echoing back adds nothing.
        guard bundle.noiseStaticPublicKey != noiseService.getStaticPublicKeyData() else { return }
        let owner = PeerID(publicKey: bundle.noiseStaticPublicKey)
        // The owner's genuine bundle (direct or relayed) always carries the
        // owner's senderID + outer signature; gossip resends preserve both. A
        // packet whose senderID isn't the owner can't be authenticated here.
        guard PeerID(hexData: packet.senderID) == owner else {
            SecureLogger.debug("🔑 Ignoring prekey bundle whose sender ≠ owner \(owner.id.prefix(8))…", category: .security)
            return
        }
        // Look up the announce-bound signing key and stash-if-unbound in ONE
        // barrier: the receive queue is concurrent, so this bundle can race
        // ahead of the announce that binds the key. Reading the live registry
        // and stashing atomically closes the check-then-act gap against
        // handleAnnounce's drain (see drainPendingPrekeyBundles).
        let signingKey: Data? = onEngine {
            if let info = peerRegistry.info(for: owner),
               info.noisePublicKey == bundle.noiseStaticPublicKey,
               let key = info.signingPublicKey {
                return key
            }
            // Offline-verified identities are stable across this race.
            for candidate in identityManager.getCryptoIdentitiesByPeerIDPrefix(owner)
            where candidate.publicKey == bundle.noiseStaticPublicKey {
                if let key = candidate.signingPublicKey { return key }
            }
            // No binding yet: retain the latest bundle per owner, bounded, and
            // retry once the verified announce lands.
            if pendingPrekeyBundles[owner] != nil
                || pendingPrekeyBundles.count < Self.pendingPrekeyBundleCap {
                pendingPrekeyBundles[owner] = packet
            }
            return nil
        }
        guard let signingKey else {
            SecureLogger.debug("🔑 Deferring prekey bundle without a bound signing key (owner \(owner.id.prefix(8))…)", category: .security)
            return
        }
        ingestVerifiedPrekeyBundle(bundle, packet: packet, owner: owner, signingKey: signingKey)
    }

    /// Verify a bundle's inner + outer signatures against the owner's bound
    /// signing key and, on success, cache it and let it enter our gossip store.
    private func ingestVerifiedPrekeyBundle(_ bundle: PrekeyBundle, packet: BitchatPacket, owner: PeerID, signingKey: Data) {
        guard noiseService.verifyPrekeyBundleSignature(bundle, signingPublicKey: signingKey),
              noiseService.verifyPacketSignature(packet, publicKey: signingKey) else {
            SecureLogger.debug("🔑 Ignoring prekey bundle without verifiable signature (owner \(owner.id.prefix(8))…)", category: .security)
            return
        }
        if prekeyBundleStore.ingest(bundle) {
            SecureLogger.debug("🔑 Cached prekey bundle for \(owner.id.prefix(8))… (\(bundle.prekeys.count) prekeys)", category: .security)
        }
        gossipSyncManager?.onPublicPacketSeen(packet)
    }

    /// Re-attempt any prekey bundle that arrived before this owner's announce
    /// bound a signing key. Called from handleAnnounce after a verified
    /// announce, in a barrier ordered after the registry write, so a bundle
    /// stashed before the write is always observed here.
    private func drainPendingPrekeyBundles(for owner: PeerID) {
        let pending: BitchatPacket? = onEngine {
            pendingPrekeyBundles.removeValue(forKey: owner)
        }
        guard let packet = pending,
              let bundle = PrekeyBundle.decode(packet.payload),
              let signingKey = announceBoundSigningKey(forNoiseKey: bundle.noiseStaticPublicKey) else { return }
        ingestVerifiedPrekeyBundle(bundle, packet: packet, owner: owner, signingKey: signingKey)
    }

    /// Ed25519 signing key bound to a Noise static key by a verified
    /// announce: from the live registry when the owner is on the mesh, else
    /// from identities persisted for offline verification.
    private func announceBoundSigningKey(forNoiseKey noiseKey: Data) -> Data? {
        let shortID = PeerID(publicKey: noiseKey)
        if let info = peerRegistry.info(for: shortID),
           info.noisePublicKey == noiseKey,
           let signingKey = info.signingPublicKey {
            return signingKey
        }
        for candidate in identityManager.getCryptoIdentitiesByPeerIDPrefix(shortID)
        where candidate.publicKey == noiseKey {
            if let signingKey = candidate.signingPublicKey {
                return signingKey
            }
        }
        return nil
    }

    // MARK: Gateway carrier (nostrCarrier)

    /// Sign and send an encoded `toGateway` carrier payload directed at a
    /// gateway peer. The packet is signed so the gateway can key its uplink
    /// quotas to an authenticated depositor; the carried Nostr event has its
    /// own Schnorr signature for content authenticity. Returns false when
    /// the gateway is not reachable or signing fails.
    func sendNostrCarrier(_ payload: Data, to gatewayPeer: PeerID) -> Bool {
        guard isPeerReachable(gatewayPeer) else { return false }
        let packet = BitchatPacket(
            type: MessageType.nostrCarrier.rawValue,
            senderID: myPeerIDData,
            recipientID: Data(hexString: gatewayPeer.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: messageTTL
        )
        guard let signed = noiseService.signPacket(packet) else { return false }
        messageQueue.async { [weak self] in
            // broadcastPacket applies a known route when one exists and
            // otherwise floods the directed packet like a DM, so a gateway
            // that is reachable but multi-hop still gets the deposit.
            self?.broadcastPacket(signed)
        }
        return true
    }

    /// Broadcast an encoded `fromGateway` carrier payload on the mesh with
    /// the default TTL. Unsigned at the packet layer — receivers verify the
    /// carried event's own Schnorr signature.
    func broadcastNostrCarrier(_ payload: Data) {
        let packet = BitchatPacket(
            type: MessageType.nostrCarrier.rawValue,
            senderID: myPeerIDData,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: messageTTL
        )
        messageQueue.async { [weak self] in
            self?.broadcastPacket(packet)
        }
    }

    /// Transport-level handling for a received nostrCarrier packet; policy
    /// (verification of the carried event, quotas, loop prevention) lives in
    /// `GatewayService` behind `onNostrCarrierPacket`.
    private func handleNostrCarrier(_ packet: BitchatPacket, from _: PeerID) {
        let senderID = PeerID(hexData: packet.senderID)
        let directedToUs: Bool
        if let recipientID = packet.recipientID {
            // Carriers addressed elsewhere ride the generic relay path untouched.
            guard recipientID == myPeerIDData else { return }
            // Uplink deposit: quotas are keyed by the depositor, so the
            // packet signature must verify against the sender's announced
            // signing key. Unlike courier deposits the depositor may be
            // multi-hop away, so ingress-link identity is not required.
            let signingKey = peerRegistry.info(for: senderID)?.signingPublicKey
            guard let signingKey,
                  noiseService.verifyPacketSignature(packet, publicKey: signingKey) else {
                SecureLogger.debug("🌐 nostrCarrier uplink from \(senderID.id.prefix(8))… rejected (missing/invalid packet signature)", category: .security)
                return
            }
            directedToUs = true
        } else {
            directedToUs = false
        }
        let payload = packet.payload
        notifyUI { [weak self] in
            self?.onNostrCarrierPacket?(payload, senderID, directedToUs)
        }
    }

    // MARK: Link capability snapshots
    // Physical link state is bleQueue-owned; the engine (and main) may
    // sync-read it here. The bindings half of a combined view comes from
    // the engine-owned identity domain directly.

    private func readLinkState<T>(_ body: (BLELinkStateStore) -> T) -> T {
        if DispatchQueue.getSpecific(key: bleQueueKey) != nil {
            return body(linkStateStore)
        } else {
            return bleQueue.sync { body(linkStateStore) }
        }
    }

    private func snapshotDirectPeripheralState(for peerID: PeerID) -> BLEPeripheralLinkState? {
        directPeripheralState(for: peerID)
    }

    private func snapshotPeripheralStates() -> [BLEPeripheralLinkState] {
        readLinkState(\.peripheralStates)
    }

    private func snapshotSubscribedCentrals() -> BLESubscribedCentralSnapshot {
        subscribedCentralSnapshot()
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

    /// Writes immediately or synchronously admits the packet to this
    /// peripheral's bounded retry queue. Unlike `writeOrEnqueue`, the return
    /// value distinguishes a retained queue item from one rejected or trimmed
    /// immediately, which lets durable courier state commit truthfully.
    ///
    /// The authenticated-link eligibility check runs on the engine (which
    /// owns bindings and rebinds, so it is serialized against identity
    /// changes by construction); only the physical admission hops to
    /// `bleQueue`.
    private func writeOrEnqueueIfAccepted(
        _ data: Data,
        to peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        priority: BLEOutboundWritePriority,
        requiredAuthenticatedPeer: PeerID?
    ) -> Bool {
        let uuid = peripheral.identifier.uuidString
        if let peerID = requiredAuthenticatedPeer {
            let link = BLEIngressLinkID.peripheral(uuid)
            guard linkBindings.peer(forPeripheralID: uuid) == peerID,
                  linkAuth.isAuthenticated(link, for: peerID) else {
                return false
            }
        }
        let accept = { [self] in
            guard let state = linkStateStore.state(forPeripheralID: uuid),
                  state.isConnected,
                  state.characteristic?.uuid == characteristic.uuid else {
                return false
            }

            if peripheral.canSendWriteWithoutResponse {
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                return true
            }

            let attempt = pendingPeripheralWrites.enqueueReportingAcceptance(
                data: data,
                for: uuid,
                priority: priority,
                capBytes: TransportConfig.blePendingWriteBufferCapBytes
            )
            switch attempt.result {
            case .oversized(let bytes):
                SecureLogger.warning("⚠️ Rejecting oversized write chunk (\(bytes)B) for peripheral \(uuid)", category: .session)
            case let .enqueued(trimmedBytes, remainingBytes) where trimmedBytes > 0:
                SecureLogger.warning("📉 Trimmed pending write buffer for \(uuid) by \(trimmedBytes)B to \(remainingBytes)B", category: .session)
            case .enqueued:
                break
            }
            return attempt.accepted
        }

        if DispatchQueue.getSpecific(key: bleQueueKey) != nil {
            return accept()
        }
        return bleQueue.sync(execute: accept)
    }

    func drainPendingWrites(for peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isPanicSuspended else { return }
            guard let state = self.linkStateStore.state(forPeripheralID: uuid), let ch = state.characteristic else { return }

            let itemsToSend = self.pendingPeripheralWrites.takeAll(for: uuid)
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
                self.pendingPeripheralWrites.prepend(unsent, for: uuid)
            }
        }
    }

    /// Periodically try to drain pending notifications as a backup mechanism
    private func drainPendingNotificationsIfPossible() {
        drainPendingNotifications(logPrefix: "🔄 Periodic drain: sent")
    }

    /// Periodically try to drain pending writes for all connected peripherals
    private func drainAllPendingWrites() {
        let uuids = pendingPeripheralWrites.peripheralIDs
        for uuid in uuids {
            guard let state = linkStateStore.state(forPeripheralID: uuid), state.isConnected else { continue }
            drainPendingWrites(for: state.peripheral)
        }
    }

    // MARK: Application State Handlers (iOS)

    #if os(iOS)
    @objc private func appDidBecomeActive() {
        isAppActive = true
        refreshCachedBackgroundTimeRemaining()
        // Restart scanning with allow duplicates when app becomes active
        if centralManager?.state == .poweredOn {
            centralManager?.stopScan()
            radio.startScanning()
        }
        radio.cancelStalePendingConnects()
        logBluetoothStatus("became-active")
        scheduleBluetoothStatusSample(after: 5.0, context: "active-5s")
        // No Local Name; nothing to refresh for advertising policy
    }

    @objc private func appDidEnterBackground() {
        isAppActive = false
        refreshCachedBackgroundTimeRemaining()
        // Restart scanning without allow duplicates in background
        if centralManager?.state == .poweredOn {
            centralManager?.stopScan()
            radio.startScanning()
        }
        radio.armPendingBackgroundConnects()
        // Backgrounding may precede a kill; flush the public-history archive
        // outside its 30s maintenance cadence.
        gossipSyncManager?.persistNow()
        logBluetoothStatus("entered-background")
        scheduleBluetoothStatusSample(after: 15.0, context: "background-15s")
        // No Local Name; nothing to refresh for advertising policy
    }
    #endif
    
    // MARK: Private Message Handling
    
    private func sendPrivateMessage(_ content: String, to recipientID: PeerID, messageID: String) {
        // Hop like sendMessage: the Transport-facing wrappers call this from
        // the main actor (router sends, favorite notifications), and the send
        // path sync-waits on bleQueue for link state.
        if DispatchQueue.getSpecific(key: messageQueueKey) == nil {
            messageQueue.async { [weak self] in
                self?.sendPrivateMessage(content, to: recipientID, messageID: messageID)
            }
            return
        }
        // Sessions and wire recipient IDs are keyed by the short 16-hex form;
        // callers may pass the full 64-hex noise key (mirrors sendFilePrivate).
        let recipientID = recipientID.toShort()
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
            onEngine {
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
        let service = noiseService
        do {
            guard let initiation = try service.initiateHandshakeIfNeeded(
                with: peerID,
                retryOnTimeout: true
            ) else {
                return
            }
            messageQueue.async {
                [weak self, weak service] in
                guard let self,
                      let service,
                      self.noiseService === service,
                      let handshakeData = service.claimHandshakeInitiation(
                        initiation,
                        for: peerID
                      ) else {
                    return
                }
                self.broadcastNoiseHandshake(handshakeData, to: peerID)
            }
        } catch {
            SecureLogger.error("Failed to initiate handshake: \(error)")
        }
    }

    private func broadcastNoiseHandshake(_ handshakeData: Data, to peerID: PeerID) {
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
    }

    /// Starts a wire-compatible ordinary XX reconnect. The manager prepares
    /// the initiator before atomically retiring the cached transport; the
    /// one-shot claim prevents a crossed inbound message from making a stale
    /// message 1 leave after this peer has already become responder.
    private func initiateNoiseReconnectHandshake(with peerID: PeerID) {
        let service = noiseService
        do {
            let initiation = try service.initiateReconnectHandshake(
                with: peerID,
                retryOnTimeout: true
            )
            messageQueue.async { [weak self, weak service] in
                guard let self,
                      let service,
                      self.noiseService === service else {
                    return
                }
                self.noteNoiseSessionCleared(for: peerID)
                guard let handshakeData = service.claimHandshakeInitiation(
                          initiation,
                          for: peerID
                      ) else {
                    return
                }
                self.broadcastNoiseHandshake(handshakeData, to: peerID)
            }
        } catch NoiseSessionError.notEstablished {
            initiateNoiseHandshake(with: peerID)
        } catch {
            SecureLogger.error(
                "Failed to initiate ordinary reconnect: \(error)",
                category: .session
            )
        }
    }
    
    private func sendPendingMessagesAfterHandshake(for peerID: PeerID) {
        // Atomically take all pending messages to process (prevents concurrent modification)
        let pendingMessages = onEngine { () -> [BLEPendingPrivateMessage] in
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
                    self?.deliverTransportEvent(.messageDeliveryStatusUpdated(messageID: message.messageID, status: .failed(reason: String(localized: "content.delivery.reason.encryption_failed", comment: "Failure reason shown when a message could not be encrypted for the peer"))))
                }
            }
        }

        // Re-queue any failed messages for retry on next handshake
        if !failedMessages.isEmpty {
            messageQueue.async { [weak self] in
                guard let self = self else { return }
                // Prepend failed messages to maintain order
                self.pendingNoiseSessionQueues.prependPrivateMessages(failedMessages, for: peerID)
                SecureLogger.warning("⚠️ Re-queued \(failedMessages.count) failed messages for \(peerID.id.prefix(8))…", category: .session)
            }
        }
    }
    
    // MARK: Fragmentation (Required for messages > BLE MTU)
    
    @discardableResult
    private func sendFragmentedPacket(
        _ packet: BitchatPacket,
        pad: Bool,
        maxChunk: Int? = nil,
        directedOnlyPeer: PeerID? = nil,
        transferId: String? = nil,
        requireDirectPeerLink: Bool = false,
        requireNoiseAuthenticatedPeerLink: Bool = false,
        requiresPrivateMediaAdmission: Bool = false
    ) -> Bool {
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: pad,
            maxChunk: maxChunk,
            directedPeer: directedOnlyPeer,
            transferId: transferId,
            requireDirectPeerLink: requireDirectPeerLink,
            requireNoiseAuthenticatedPeerLink: requireNoiseAuthenticatedPeerLink
        )

        let result: BLEOutboundFragmentTransferScheduler.SubmitResult? = onEngine {
            if requiresPrivateMediaAdmission {
                guard let transferId else { return nil }
                // This lock is taken while the scheduler is already
                // engine-confined. Cancellation takes the admission lock
                // synchronously but never waits on the engine, avoiding
                // lock inversion while giving submit/cancel one linear order.
                return privateMediaTransferAdmissions.withActive(transferId) {
                    outboundFragmentTransfers.submit(
                        request,
                        maxConcurrentTransfers: TransportConfig.bleMaxConcurrentTransfers
                    )
                }
            }
            return outboundFragmentTransfers.submit(
                request,
                maxConcurrentTransfers: TransportConfig.bleMaxConcurrentTransfers
            )
        }
        guard let result else {
            if let transferId, requiresPrivateMediaAdmission {
                privateMediaTransferAdmissions.finish(transferId)
            }
            return false
        }
        if let transferId, requiresPrivateMediaAdmission {
            // The scheduler now owns normal cancellation (active or pending).
            privateMediaTransferAdmissions.finish(transferId)
        }
        return handleFragmentTransferSubmitResult(result)
    }

    @discardableResult
    private func handleFragmentTransferSubmitResult(_ result: BLEOutboundFragmentTransferScheduler.SubmitResult) -> Bool {
        switch result {
        case let .start(request, reservedTransferId):
            return startFragmentedPacket(request, reservedTransferId: reservedTransferId)

        case let .queued(_, transferId, _):
            if let transferId {
                SecureLogger.debug("🚦 Queued media transfer \(transferId.prefix(8))… waiting for slot", category: .session)
            } else {
                SecureLogger.debug("🚦 Queued fragment transfer waiting for slot", category: .session)
            }
            return false

        case let .rejectedStrict(_, transferId):
            SecureLogger.debug(
                "🚫 Strict directed fragment transfer \(transferId?.prefix(8) ?? "?")… rejected while scheduler busy",
                category: .session
            )
            return false

        case let .droppedDuplicate(_, activeTransferId):
            SecureLogger.debug(
                "🔁 Skipping duplicate outbound transfer — same content already in flight as \(activeTransferId?.prefix(8) ?? "?")…",
                category: .session
            )
            return false
        }
    }

    @discardableResult
    private func startFragmentedPacket(
        _ request: BLEOutboundFragmentTransferRequest,
        reservedTransferId: String?
    ) -> Bool {
        let releaseReservedSlot: (String) -> Void = { [weak self] id in
            guard let self = self else { return }
            TransferProgressManager.shared.cancel(id: id)
            messageQueue.async { [weak self] in
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
            return false
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
                    self?.radio.startScanning()
                }
            }
        }

        let transferIdentifier: String?
        if let id = reservedTransferId {
            let activated = onEngine {
                self.outboundFragmentTransfers.activateReservedTransfer(
                    id: id,
                    totalFragments: plan.totalFragments,
                    workItems: []
                )
            }
            // Cancellation may remove the reservation between submit and plan
            // construction. Treat that as cancellation, not as permission to
            // schedule an untracked fragment train.
            guard activated else { return false }
            TransferProgressManager.shared.start(id: id, totalFragments: plan.totalFragments)
            transferIdentifier = id
        } else {
            transferIdentifier = nil
        }

        let sendFragment: (BitchatPacket) -> Bool = { [weak self] fragmentPacket in
            guard let self else { return false }
            if request.requireDirectPeerLink, let directedPeer = request.directedPeer {
                return self.sendPacketDirected(
                    fragmentPacket,
                    to: directedPeer,
                    requireDirectPeerLink: true,
                    requireNoiseAuthenticatedPeerLink: request.requireNoiseAuthenticatedPeerLink
                )
            }
            self.broadcastPacket(fragmentPacket)
            return true
        }

        // Strict courier handoff is transactional at the fragment-admission
        // boundary: every fragment must enter the intended authenticated
        // link or its bounded retry queue before the durable owner may commit.
        // A partial train is harmlessly abandoned and the envelope stays
        // retryable with a fresh fragment ID on the next encounter.
        if request.requireDirectPeerLink {
            let admitted = BLEStrictFragmentAdmission.admitAll(plan.fragmentPackets) { fragmentPacket in
                guard sendFragment(fragmentPacket) else { return false }
                if let transferId = transferIdentifier {
                    markFragmentSent(transferId: transferId)
                }
                return true
            }
            guard admitted else {
                if let id = reservedTransferId {
                    releaseReservedSlot(id)
                }
                return false
            }
            return true
        }

        var scheduledItems: [(item: DispatchWorkItem, index: Int)] = []

        for (index, fragmentPacket) in plan.fragmentPackets.enumerated() {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if let transferId = transferIdentifier {
                    let isActive = onEngine { self.outboundFragmentTransfers.isActive(transferId) }
                    guard isActive else { return }
                }
                if fragmentPacket.recipientID == nil || fragmentPacket.recipientID?.allSatisfy({ $0 == 0xFF }) == true {
                    self.gossipSyncManager?.onPublicPacketSeen(fragmentPacket)
                }
                _ = sendFragment(fragmentPacket)
                if let transferId = transferIdentifier {
                    self.markFragmentSent(transferId: transferId)
                }
            }

            scheduledItems.append((item: workItem, index: index))
        }

        if let transferId = transferIdentifier {
            let workItems = scheduledItems.map { $0.item }
            messageQueue.async { [weak self] in
                _ = self?.outboundFragmentTransfers.updateWorkItems(workItems, for: transferId)
            }
        }

        for (workItem, index) in scheduledItems {
            let delayMs = index * plan.spacingMs
            engineScheduler.schedule(after: Double(delayMs) / 1_000, execute: workItem)
        }
        return true
    }
    
    // MARK: - Fragmentation (Required for messages > BLE MTU)

    private func markFragmentSent(transferId: String) {
        messageQueue.async { [weak self] in
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
        let results = onEngine {
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
            messageQueue.async { [weak self] in
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
                return onEngine {
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
    
    // MARK: Link-event port (bleQueue → engine)

    /// The single upward entry of the link-layer port: the bleQueue side
    /// (CoreBluetooth delegates, radio policy) and the simulated mesh
    /// report everything through here. Frames capture the panic lifecycle
    /// at the handoff; lifecycle events ride plain engine slots (the
    /// panic path clears their state wholesale either way).
    func emitLinkEvent(_ event: BLELinkEvent) {
        if case let .frameDecoded(packet, link, linkDescription) = event {
            ingestDecodedPacket(packet, link: link, linkDescription: linkDescription)
            return
        }
        messageQueue.async { [weak self] in
            self?.handleLinkEvent(event)
        }
    }

    /// Engine-confined consumer of the link-layer port: identity
    /// retirement, survivor repair, and peer-disconnect bookkeeping for
    /// every physical lifecycle transition the link layer reports.
    private func handleLinkEvent(_ event: BLELinkEvent) {
        switch event {
        case .frameDecoded:
            // Routed through ingestDecodedPacket by emitLinkEvent; frames
            // never reach the lifecycle switch.
            assertionFailure("frameDecoded must enter via emitLinkEvent")

        case let .peripheralLinkEnded(peripheralID, runPeerBookkeeping):
            let peerID = retirePeripheralLinkIdentity(peripheralID)
            guard runPeerBookkeeping else { return }
            if let peerID {
                SecureLogger.debug("📱 Disconnected link was bound to \(peerID.id.prefix(8))…", category: .session)
            }
            // A duplicate link can drop while the peer stays live on
            // another (the dual-role central link, or a second bound link
            // after a restore): peer-disconnect bookkeeping only runs once
            // the peer's last live link is gone. The retirement just
            // repaired the reverse map onto a connected survivor, so
            // directLinkState is accurate here.
            let remainingLinks = peerID.map { directLinkState(for: $0) }
            let peerStillLinked = (remainingLinks?.hasPeripheral ?? false) || (remainingLinks?.hasCentral ?? false)
            if let peerID, !peerStillLinked {
                // Do not remove peer; mark as not connected but retain for reachability
                peerRegistry.mutate { $0.markDisconnected(peerID) }
                refreshLocalTopology()
            }
            notifyUI { [weak self] in
                guard let self = self else { return }
                let currentPeerIDs = self.peerRegistry.peerIDs
                if let peerID, !peerStillLinked {
                    self.notifyPeerDisconnectedDebounced(peerID)
                }
                self.requestPeerDataPublish()
                self.deliverTransportEvent(.peerListUpdated(currentPeerIDs))
            }

        case let .centralLinkEnded(centralUUID):
            linkAuth.retireLink(.central(centralUUID))
            guard let peerID = linkBindings.centralRemoved(centralUUID) else { return }
            // The remote side retiring a redundant duplicate connection
            // arrives as an unsubscribe while the peer stays live on its
            // other links; only the peer's last link disconnecting counts.
            guard linkBindings.links(to: peerID).isEmpty else { return }
            peerRegistry.mutate { $0.markDisconnected(peerID) }
            refreshLocalTopology()
            notifyUI { [weak self] in
                guard let self = self else { return }
                let currentPeerIDs = self.peerRegistry.peerIDs
                self.notifyPeerDisconnectedDebounced(peerID)
                self.requestPeerDataPublish()
                self.deliverTransportEvent(.peerListUpdated(currentPeerIDs))
            }

        case let .allPeripheralLinksEnded(peripheralIDs, retireProofsAndNotify):
            guard retireProofsAndNotify else {
                _ = linkBindings.clearPeripherals()
                return
            }
            for peripheralID in peripheralIDs {
                linkAuth.retireLink(.peripheral(peripheralID))
            }
            let peerIDs = linkBindings.clearPeripherals()
            for peerID in peerIDs {
                notifyUI { [weak self] in
                    self?.notifyPeerDisconnectedDebounced(peerID)
                }
            }

        case let .allCentralLinksEnded(centralUUIDs, retireProofsAndNotify):
            guard retireProofsAndNotify else {
                _ = linkBindings.clearCentrals()
                return
            }
            for centralUUID in centralUUIDs {
                linkAuth.retireLink(.central(centralUUID))
            }
            let peerIDs = linkBindings.clearCentrals()
            for peerID in peerIDs {
                notifyUI { [weak self] in
                    self?.notifyPeerDisconnectedDebounced(peerID)
                }
            }
        }
    }

    // MARK: Packet Reception

    /// The bleQueue → engine handoff for every frame the link layer
    /// decodes: the radio side hands up (packet, linkID) and all
    /// attribution — binding lookup, spoof rejection, raw-announce
    /// binding, ingress recording — happens on the engine, the queue that
    /// owns the identity domain. Captures the panic lifecycle at the
    /// handoff, like `handleReceivedPacket`.
    ///
    /// Per-link frame order is preserved end to end (bleQueue and the
    /// engine are both serial), so an announce that binds a link is
    /// attributed before the directed frames that ride behind it — the
    /// same-batch spoof protection the old bleQueue-side attribution
    /// enforced with a batch-local binding.
    private func ingestDecodedPacket(
        _ packet: BitchatPacket,
        link: BLEIngressLinkID,
        linkDescription: String
    ) {
        guard let lifecycleGeneration = capturePanicLifecycleGeneration() else { return }
        messageQueue.async { [weak self] in
            guard let self,
                  self.isCurrentPanicLifecycleGeneration(lifecycleGeneration) else {
                return
            }
            self.attributeAndHandlePacket(packet, link: link, linkDescription: linkDescription)
        }
    }

    /// Engine-confined attribution: resolves the link's bound owner,
    /// admits or rejects the claimed sender, lets a direct raw announce
    /// bind an unbound link (rotation rebinds still require a verified
    /// announce — `rebindLinkAfterVerifiedDirectAnnounce`), records
    /// ingress, and hands the packet to the handler pipeline.
    private func attributeAndHandlePacket(
        _ packet: BitchatPacket,
        link: BLEIngressLinkID,
        linkDescription: String
    ) {
        let claimedSenderID = PeerID(hexData: packet.senderID)
        let context = acceptedIngressContext(
            for: packet,
            claimedSenderID: claimedSenderID,
            boundPeerID: linkBindings.boundPeer(for: link),
            linkDescription: linkDescription
        )
        guard let context else { return }

        if packet.type != MessageType.announce.rawValue {
            SecureLogger.debug("📦 Decoded packet type: \(packet.type) from sender: \(claimedSenderID.id.prefix(8))… (\(linkDescription))", category: .session)
        }

        if packet.type == MessageType.announce.rawValue,
           packet.ttl == messageTTL {
            // Raw announces only bind unbound links: this runs before
            // signature verification, so a bound link must not be re-bound
            // by a raw announce (spoofable).
            let boundPeerID = linkBindings.boundPeer(for: link)
            if boundPeerID == nil || boundPeerID == claimedSenderID {
                switch link {
                case .peripheral(let peripheralUUID):
                    bindPeripheralLink(peripheralUUID, to: claimedSenderID)
                case .central(let centralUUID):
                    linkBindings.bindCentral(centralUUID, to: claimedSenderID)
                }
                refreshLocalTopology()
            }
        }

        guard recordIngressIfNew(packet, link: link, peerID: context.receivedFromPeerID) else {
            return
        }

        handleReceivedPacket(packet, from: context.receivedFromPeerID)
    }

    private func handleReceivedPacket(_ packet: BitchatPacket, from peerID: PeerID) {
        let isNoisePacket = packet.type == MessageType.noiseHandshake.rawValue
            || packet.type == MessageType.noiseEncrypted.rawValue

        // Capture the panic lifecycle at the first off-messageQueue handoff.
        // Noise packets still enter through a barrier so handshake promotion,
        // quarantine, and encrypted delivery share one ordered session.
        if DispatchQueue.getSpecific(key: messageQueueKey) == nil {
            guard let lifecycleGeneration =
                    capturePanicLifecycleGeneration() else {
                return
            }
            #if DEBUG
            _test_beforeReceivePacketHandoff?()
            #endif
            let flags: DispatchWorkItemFlags = isNoisePacket ? .barrier : []
            messageQueue.async(flags: flags) { [weak self] in
                guard let self,
                      self.isCurrentPanicLifecycleGeneration(
                          lifecycleGeneration
                      ) else {
                    return
                }
                #if DEBUG
                self._test_onReceivePacketHandoff?()
                #endif
                self.handleReceivedPacketOnQueue(packet, from: peerID)
            }
            return
        }

        if isNoisePacket {
            guard let lifecycleGeneration =
                    capturePanicLifecycleGeneration() else {
                return
            }
            messageQueue.async { [weak self] in
                guard let self,
                      self.isCurrentPanicLifecycleGeneration(
                          lifecycleGeneration
                      ) else {
                    return
                }
                self.handleReceivedPacketOnQueue(packet, from: peerID)
            }
        } else {
            handleReceivedPacketOnQueue(packet, from: peerID)
        }
    }

    private func handleReceivedPacketOnQueue(
        _ packet: BitchatPacket,
        from peerID: PeerID
    ) {
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

        // Track recent traffic timestamps for adaptive behavior; the same
        // barrier hop confirms route health for the packet's originator.
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            self.recentTrafficTracker.recordPacket(at: Date())
            self.sourceRouteFailures.noteInboundActivity(from: senderID)
        }

        // Per-peer protocol version: originated source routes only use hops
        // observed speaking v2 (a v1-only node cannot decode v2 frames).
        if packet.version >= 2 {
            meshTopology.recordObservedVersion(packet.version, for: packet.senderID)
            if peerID != senderID {
                meshTopology.recordObservedVersion(packet.version, for: routingData(for: peerID))
            }
        }

        #if os(iOS)
        // The maintenance timer is suspended with the app, so a packet arriving
        // while backgrounded means the radio woke us — use the wake window to
        // run the announce/flush/drain pass the timer would have run.
        if !isAppActive {
            bleQueue.async { [weak self] in self?.performBackgroundWakeMaintenanceIfStale() }
        }
        #endif


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
            // Broadcast files that fail sender authentication must not spread
            // to downstream (possibly older, ungated) nodes; skip the relay
            // step below, like invalid board posts and voice frames.
            guard handleFileTransfer(packet, from: senderID) else { return }

        case .courierEnvelope:
            handleCourierEnvelope(packet, from: peerID)

        case .groupMessage:
            handleGroupMessage(packet, from: senderID)

        case .prekeyBundle:
            handlePrekeyBundle(packet, from: senderID)

        case .boardPost:
            // Invalid or deleted posts must not spread; skip the relay step.
            guard handleBoardPost(packet, from: senderID) else { return }
        case .nostrCarrier:
            handleNostrCarrier(packet, from: peerID)

        case .voiceFrame:
            // Rejected frames (unsigned/stale/spoofed) must not spread; skip
            // the relay step below, like invalid board posts.
            guard handleVoiceFrame(packet, from: senderID) else { return }

        case .ping:
            // Rate limiting must key on the ingress link (`peerID`), not the
            // packet-claimed sender: pings are unsigned, so `senderID` is
            // attacker-controlled and rotating it would reset the budget.
            handleMeshPing(packet, fromLink: peerID)

        case .pong:
            handleMeshPong(packet, from: senderID)

        case .leave:
            // A forged leave must neither evict the claimed peer nor spread
            // to downstream nodes.
            guard handleLeave(packet, from: senderID) else { return }

        case .none:
            SecureLogger.warning("⚠️ Unknown message type: \(packet.type)", category: .session)
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

        let connectedCount = peerRegistry.connectedCount
        if BLEReceivePipeline.shouldCancelScheduledRelayForDuplicate(connectedPeerCount: connectedCount) {
            messageQueue.async { [weak self] in
                self?.scheduledRelays.cancel(messageID: messageID)
            }
        }

        return true
    }

    private func scheduleRelayIfNeeded(_ packet: BitchatPacket, senderID: PeerID, messageID: String) {
        let degree = peerRegistry.connectedCount
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
            messageQueue.async { [weak self] in
                self?.scheduledRelays.remove(messageID: messageID)
            }
            var relayPacket = packet
            relayPacket.ttl = decision.newTTL
            self.broadcastPacket(relayPacket)
        }

        messageQueue.async { [weak self] in
            self?.scheduledRelays.schedule(work, messageID: messageID)
        }
        engineScheduler.schedule(after: Double(decision.delayMs) / 1_000, execute: work)
    }
    
    private func handleAnnounce(_ packet: BitchatPacket, from peerID: PeerID) {
        let result = announceHandler.handle(packet, from: peerID)

        // A capability bit in the public announce is only a discovery hint.
        // Start authentication promptly for a directly connected candidate,
        // but never pin or pre-queue private bytes until encrypted 0x21 state
        // arrives from the completed Noise session.
        if let result,
           result.isVerified,
           result.isDirectAnnounce,
           result.announcement.capabilities?.contains(.privateMedia) == true,
           privateMediaSendPolicy(to: result.peerID) == .awaitingCapabilityProof,
           !noiseService.hasSession(with: result.peerID) {
            initiateNoiseHandshake(with: result.peerID)
        }

        // A verified announce is the moment a signing key becomes bound to this
        // owner's noise key: retry any prekey bundle that raced ahead of it.
        if let result, result.isVerified {
            drainPendingPrekeyBundles(for: result.peerID)
        }

        // A verified direct announce proves the sender owns the link it came
        // in on: heal any stale binding left by a peer-ID rotation, and
        // consolidate duplicate same-role connections onto that link.
        if let result, result.isVerified, result.isDirectAnnounce {
            rebindLinkAfterVerifiedDirectAnnounce(packet, to: result.peerID)
            retireRedundantPeripheralLinks(packet, to: result.peerID)
        }

        // Bridge courier watch: a verified announce may add a peer whose
        // relay-parked drops we should start watching for.
        if let result, result.isVerified {
            onVerifiedPeerAnnounce?(result.peerID)
        }

        // Courier work: an announce is the moment we learn a peer's Noise
        // static key, so check whether we're carrying mail addressed to them
        // (or spray-able mail they could carry). Verified announces only.
        guard !courierStore.isEmpty,
              let result,
              result.isVerified else { return }
        let noiseKey = result.announcement.noisePublicKey
        let authenticatedIngress = result.isDirectAnnounce
            && canDeliverSecurely(to: result.peerID)
            && isNoiseAuthenticatedIngressLink(for: packet, peerID: result.peerID)
        if authenticatedIngress {
            // The session was established on this still-bound ingress link.
            // A peer-level Noise session alone is not enough: it can outlive
            // its physical link while a replay rebinds an attacker's link to
            // the victim's ID.
            deliverCourierMail(to: result.peerID, noiseKey: noiseKey)
            sprayCourierMail(to: result.peerID, noiseKey: noiseKey, isVerifiedPeer: true)
        } else {
            // Relayed announce, or a direct-looking announce that has not yet
            // proved link ownership with Noise: push a speculative copy while
            // retaining the durable carried original.
            deliverCourierMailRemotely(to: result.peerID, noiseKey: noiseKey)
            if result.isDirectAnnounce,
               !hasCurrentNoiseAuthenticatedLink(to: result.peerID) {
                // A cached session may predate this physical link.
                // rebindLinkAfterVerifiedDirectAnnounce performs its atomic
                // ordinary reconnect after the binding is published.
                if !noiseService.hasSession(with: result.peerID) {
                    initiateNoiseHandshake(with: result.peerID)
                }
            }
        }
    }

    /// When a peer relaunches it rotates its ephemeral peer ID, but an
    /// already-open BLE connection keeps its old peripheral/central→peerID
    /// binding. Until that binding heals, the rotated peer shows up twice in
    /// the peer list and its directed traffic on this link is dropped as
    /// spoofed. A signature-verified direct announce proves the claimed
    /// sender owns the link it arrived on, so rebind the link to the new ID
    /// and retire the old identity.
    /// Engine-confined: the whole rebind — containment checks, proof
    /// retirement, binding flip, reconnect decision, and rotated-identity
    /// retirement — is one engine slot, so no observer can see a
    /// half-applied rotation. Only the physical connection cancels hop to
    /// bleQueue.
    private func rebindLinkAfterVerifiedDirectAnnounce(_ packet: BitchatPacket, to peerID: PeerID) {
        guard let link = ingressLinks.link(for: packet) else { return }
        let linkUUID: String
        let previousPeerID: PeerID?
        switch link {
        case .peripheral(let peripheralUUID):
            linkUUID = peripheralUUID
            previousPeerID = linkBindings.peer(forPeripheralID: peripheralUUID)
        case .central(let centralUUID):
            linkUUID = centralUUID
            previousPeerID = linkBindings.peer(forCentralUUID: centralUUID)
        }
        guard let previousPeerID else { return }
        guard previousPeerID != peerID else {
            refreshNoiseSessionForVerifiedDirectLink(
                link: link,
                peerID: peerID
            )
            return
        }

        // The signature does not authenticate directness (TTL is excluded
        // from signing because relays mutate it), so a "verified direct"
        // announce can be a replay of another peer's fresh announce with
        // its TTL restored. Contain what a forged rebind could do:
        // never steal an identity another live link already owns, and
        // allow at most one rebind per link per cooldown window so two
        // identities can't fight over a link in a replay flip-flop.
        guard linkBindings.links(to: peerID).isEmpty else {
            SecureLogger.warning("🚫 Refusing link rebind to \(peerID.id.prefix(8))…: identity already owns another live link", category: .security)
            return
        }
        let now = Date()
        guard linkAuth.permitRebind(
            linkUUID: linkUUID,
            now: now,
            cooldown: TransportConfig.bleLinkRebindCooldownSeconds
        ) else {
            SecureLogger.warning("🚫 Refusing link rebind to \(peerID.id.prefix(8))…: rebind cooldown active for this link", category: .security)
            return
        }

        // A Noise proof belongs to the old physical binding. Never carry
        // it across an announce-driven rebind, whose direct TTL is
        // replayable; the new owner must complete a fresh handshake.
        linkAuth.retireLink(link)
        switch link {
        case .peripheral(let peripheralUUID):
            bindPeripheralLink(peripheralUUID, to: peerID)
        case .central(let centralUUID):
            linkBindings.bindCentral(centralUUID, to: peerID)
        }
        // Same engine slot as the rebind: no observer may see the new
        // binding while a cached peer-level sender is still considered
        // established.
        refreshNoiseSessionForVerifiedDirectLink(
            link: link,
            peerID: peerID
        )
        SecureLogger.debug("🔄 Rebinding link after peer-ID rotation: \(previousPeerID.id.prefix(8))… → \(peerID.id.prefix(8))…", category: .session)
        refreshLocalTopology()
        // The announce that triggered this rebind was upserted as
        // disconnected: the registry ran while the link still belonged
        // to the previous ID (the ambiguous state BLEAnnounceHandler
        // denies the connected shortcut). The rebind has now
        // containment-checked the claim and the identity owns a live
        // link, so promote it — otherwise a healed rotation leaves a
        // live link that reads as disconnected until the next announce.
        promoteReboundPeerToConnected(peerID)
        // Any other peripheral links still bound to the rotated-away ID
        // are stale duplicates of the same physical device (its restored
        // connections outlived the relaunch that rotated the ID): cancel
        // them now instead of leaving ghost links that spray duplicate
        // traffic until the inactivity timeout.
        cancelBoundPeripheralLinks(to: previousPeerID, keeping: linkUUID)
        // Retire the rotated-away ID only once its last link is gone; a
        // remaining stale link heals the same way or ages out.
        guard linkBindings.links(to: previousPeerID).isEmpty else { return }
        retireRotatedPeer(previousPeerID)
    }

    /// After a restore relaunch the same phone can reappear under a fresh
    /// peripheral UUID while its restored connection lives on, leaving
    /// several live central-role connections to one peer that each carry
    /// every packet (field-verified: every voice frame arrived 2-3x). A
    /// verified direct announce is the consolidation point: keep the link it
    /// proves live (or the peer's most recently bound one) and cancel the
    /// rest. Only same-role duplicates are touched — one connection per role
    /// is the normal dual-role topology — and only connections we own as
    /// central: the peer's central subscriptions on our peripheral manager
    /// are its connections to cancel, and it runs this same policy.
    ///
    /// Directness is forgeable (TTL is unsigned), so a replayed announce
    /// could nominate the replayer's link as the survivor. Containment
    /// mirrors the rotation rebind: only links already BOUND to the peer are
    /// retired (announce-evidenced, never pre-announce links), at most one
    /// retirement per peer per cooldown window, and the peer keeps a live
    /// link either way.
    private func retireRedundantPeripheralLinks(_ packet: BitchatPacket, to peerID: PeerID) {
        let ingressLink = ingressLinks.link(for: packet)
        let now = Date()
        var ingressPeripheralUUID: String?
        if case .peripheral(let uuid) = ingressLink {
            ingressPeripheralUUID = uuid
        }
        guard let keptUUID = BLERedundantLinkPolicy.keptPeripheralUUID(
            ingressPeripheralUUID: ingressPeripheralUUID,
            mostRecentlyBoundUUID: linkBindings.preferredPeripheralUUID(for: peerID),
            links: peripheralLinkPolicySnapshot(),
            peerID: peerID
        ) else { return }

        guard linkAuth.permitRedundantRetirement(
            peerID: peerID,
            now: now,
            cooldown: TransportConfig.bleLinkRebindCooldownSeconds
        ) else { return }
        // The survivor becomes the peer's reverse-mapped link so directed
        // sends follow the consolidation.
        bindPeripheralLink(keptUUID, to: peerID)
        cancelBoundPeripheralLinks(to: peerID, keeping: keptUUID)
        refreshLocalTopology()
    }

    /// Cancels our central-role connections whose link is bound to `peerID`,
    /// except `keptUUID`. Engine-confined: each binding is retired BEFORE
    /// the cancel is issued, so didDisconnectPeripheral's identity hop sees
    /// no peer binding and skips its peer-disconnect bookkeeping — the peer
    /// is still live (on the kept link, or under its rotated identity).
    /// Only the physical discard and the CoreBluetooth cancel hop to
    /// bleQueue.
    private func cancelBoundPeripheralLinks(to peerID: PeerID, keeping keptUUID: String?) {
        let retiring = BLERedundantLinkPolicy.peripheralUUIDsToRetire(
            links: peripheralLinkPolicySnapshot(),
            peerID: peerID,
            keeping: keptUUID ?? ""
        )
        for uuid in retiring {
            retirePeripheralLinkIdentity(uuid)
            SecureLogger.info(
                "🔗 Retiring redundant link \(uuid.prefix(8))… bound to \(peerID.id.prefix(8))…\(keptUUID.map { " (keeping \($0.prefix(8))…)" } ?? "")",
                category: .session
            )
            bleQueue.async { [weak self] in
                guard let self,
                      let state = self.linkStateStore.state(forPeripheralID: uuid) else { return }
                self.discardPeripheralLinkPhysical(uuid)
                self.centralManager?.cancelPeripheralConnection(state.peripheral)
            }
        }
    }

    /// Engine-confined: physical link rows joined with their engine-owned
    /// bindings.
    private func peripheralLinkPolicySnapshot() -> [BLERedundantLinkPolicy.PeripheralLink] {
        let physical = readLinkState { store in
            store.peripheralStates.map {
                (uuid: $0.peripheral.identifier.uuidString,
                 isConnected: $0.isConnected,
                 hasCharacteristic: $0.characteristic != nil)
            }
        }
        return physical.map {
            BLERedundantLinkPolicy.PeripheralLink(
                uuid: $0.uuid,
                peerID: linkBindings.peer(forPeripheralID: $0.uuid),
                isConnected: $0.isConnected,
                hasCharacteristic: $0.hasCharacteristic
            )
        }
    }

    /// After a successful verified rebind the new identity owns a live link,
    /// but its announce was stored disconnected (the link was still bound to
    /// the rotated-away ID when the registry upsert ran). Flip it to
    /// connected and republish so routing and the peer list see the healed
    /// link. The `.peerConnected` UI event already fired from the announce
    /// path (new/reconnected + direct), so only list state needs refreshing.
    private func promoteReboundPeerToConnected(_ peerID: PeerID) {
        let promoted = peerRegistry.mutate { $0.markConnected(peerID) }
        guard promoted else { return }
        refreshLocalTopology()
        publishFullPeerData()
        notifyUI { [weak self] in
            guard let self else { return }
            let currentPeerIDs = self.peerRegistry.peerIDs
            self.deliverTransportEvent(.peerListUpdated(currentPeerIDs))
        }
    }

    /// Rotation is an implicit leave of the old identity: drop it immediately
    /// instead of letting a ghost duplicate linger for the reachability
    /// retention window.
    private func retireRotatedPeer(_ peerID: PeerID) {
        let removed = peerRegistry.mutate { $0.remove(peerID) != nil }
        guard removed else { return }
        gossipSyncManager?.removeAnnouncementForPeer(peerID)
        refreshLocalTopology()
        notifyUI { [weak self] in
            guard let self else { return }
            let currentPeerIDs = self.peerRegistry.peerIDs
            self.deliverTransportEvent(.peerDisconnected(peerID))
            self.deliverTransportEvent(.peerListUpdated(currentPeerIDs))
        }
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
            existingPeerKeys: { [weak self] peerID in
                guard let self = self else { return (nil, nil) }
                return onEngine {
                    let info = self.peerRegistry.info(for: peerID)
                    return (info?.noisePublicKey, info?.signingPublicKey)
                }
            },
            persistedSigningPublicKey: { [weak self] peerID in
                // Same synchronous identity-manager read pattern as
                // signedSenderDisplayName(for:from:); the manager serializes
                // access on its own internal queue.
                guard let self = self else { return nil }
                return self.identityManager.getCryptoIdentitiesByPeerIDPrefix(peerID)
                    .compactMap { $0.signingPublicKey }
                    .first
            },
            authenticatedSigningPublicKey: { [weak self] noisePublicKey in
                self?.identityManager.authenticatedSigningPublicKey(
                    forFingerprint: noisePublicKey.sha256Fingerprint()
                )
            },
            verifySignature: { [weak self] packet, signingPublicKey in
                self?.noiseService.verifyPacketSignature(packet, publicKey: signingPublicKey) ?? false
            },
            linkState: { [weak self] peerID in
                self?.linkState(for: peerID) ?? (hasPeripheral: false, hasCentral: false)
            },
            linkBoundToOtherPeer: { [weak self] packet, peerID in
                // Reads the CURRENT binding — i.e. the state before
                // rebindLinkAfterVerifiedDirectAnnounce (which runs after the
                // handler) may steal the link and promote the new owner to
                // connected. See the caller in BLEAnnounceHandler for why the
                // residual forged-presence window this leaves is accepted.
                guard let self else { return false }
                guard let link = self.ingressLinks.link(for: packet) else { return false }
                guard let boundPeerID = self.linkBindings.boundPeer(for: link) else { return false }
                return boundPeerID != peerID
            },
            withRegistryBarrier: { [weak self] body in
                self?.onEngine { body() }
            },
            upsertVerifiedAnnounce: { [weak self] peerID, announcement, isConnected, now in
                // Called from inside withRegistryBarrier; access registry directly.
                guard let self = self else {
                    return BLEPeerAnnounceUpdate(isNewPeer: false, wasDisconnected: false, previousNickname: nil)
                }
                return self.peerRegistry.mutate {
                    $0.upsertVerifiedAnnounce(
                        peerID: peerID,
                        nickname: announcement.nickname,
                        noisePublicKey: announcement.noisePublicKey,
                        signingPublicKey: announcement.signingPublicKey,
                        isConnected: isConnected,
                        // Propagate `nil` (registry refused the announce because it
                        // carries a signing key different from the pinned one) so
                        // the handler's guard rejects it instead of overwriting the
                        // pinned identity. Main's capabilities/bridgeGeohash are
                        // preserved.
                        now: now,
                        capabilities: announcement.capabilities,
                        bridgeGeohash: announcement.bridgeGeohash
                    )
                }
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
                    let currentPeerIDs = self.peerRegistry.peerIDs
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
                self?.engineScheduler.schedule(after: delay) { [weak self] in
                    self?.sendAnnounce(forceSend: true)
                }
            }
        )
    }

    // MARK: - Board (geohash bulletin board)

    /// Validates and stores an incoming board post or tombstone. Returns
    /// whether the packet is worth relaying onward.
    private func handleBoardPost(_ packet: BitchatPacket, from peerID: PeerID) -> Bool {
        guard let wire = BoardWire.decode(from: packet.payload) else {
            SecureLogger.warning("⚠️ Malformed board packet from \(peerID.id.prefix(8))…", category: .session)
            return false
        }
        // Posts are self-authenticating: the payload embeds the author's
        // Ed25519 key and signature, so verification does not depend on the
        // author still being around to announce.
        guard wire.verifySignature() else {
            if logRateLimiter.shouldLog(key: "board-sig:\(peerID.id)") {
                SecureLogger.warning("🚫 Dropping board packet with invalid signature from \(peerID.id.prefix(8))…", category: .security)
            }
            return false
        }
        switch boardStore.ingest(wire, packet: packet) {
        case .accepted, .duplicate:
            return true
        case .rejected:
            return false
        }
    }

    /// Broadcasts a pre-signed board payload (post or tombstone) built by the
    /// board manager, and ingests it locally so it shows up on our own board
    /// and joins gossip sync immediately.
    func sendBoardPayload(_ payload: Data) {
        guard let wire = BoardWire.decode(from: payload), wire.verifySignature() else {
            SecureLogger.error("❌ Refusing to send invalid board payload", category: .session)
            return
        }
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            let basePacket = BitchatPacket(
                type: MessageType.boardPost.rawValue,
                senderID: Data(hexString: self.myPeerID.id) ?? Data(),
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: self.messageTTL
            )
            guard let signedPacket = self.noiseService.signPacket(basePacket) else {
                SecureLogger.error("❌ Failed to sign board packet", category: .security)
                return
            }
            // Pre-mark our own broadcast as processed to avoid handling a relayed self copy
            let dedupID = BLESelfBroadcastTracker.dedupID(for: signedPacket)
            self.messageDeduplicator.markProcessed(dedupID)
            self.boardStore.ingest(wire, packet: signedPacket)
            self.broadcastPacket(signedPacket)
        }
    }

    // Handle REQUEST_SYNC: decode payload and respond with missing packets via sync manager
    private func handleRequestSync(_ packet: BitchatPacket, from peerID: PeerID) {
        // REQUEST_SYNC is link-local by design (always sent with ttl 0): a
        // nonzero TTL means a crafted or relayed request, and answering one
        // would let a single small packet fan a full store replay out of
        // every node it reaches.
        guard packet.ttl == 0 else {
            if logRateLimiter.shouldLog(key: "sync-ttl:\(peerID.id)") {
                SecureLogger.warning("🚫 Dropping REQUEST_SYNC with nonzero TTL from \(peerID.id.prefix(8))…", category: .security)
            }
            return
        }
        // A response can replay the entire gossip store, so require proof the
        // requester owns the claimed sender ID: the request must verify
        // against the signing key from that peer's announce.
        let signingKey = peerRegistry.info(for: peerID)?.signingPublicKey
        guard let signingKey, noiseService.verifyPacketSignature(packet, publicKey: signingKey) else {
            if logRateLimiter.shouldLog(key: "sync-sig:\(peerID.id)") {
                SecureLogger.warning("🚫 Dropping REQUEST_SYNC without verifiable signature from \(peerID.id.prefix(8))…", category: .security)
            }
            return
        }
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
                return self.peerRegistry.snapshotByID
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

    /// Group broadcasts are opaque ciphertext to this layer: track them for
    /// gossip backfill and hand the payload to the UI layer, where the group
    /// coordinator decrypts and authenticates against the roster. Non-members
    /// still relay (generic broadcast relay path) but never decode.
    private func handleGroupMessage(_ packet: BitchatPacket, from _: PeerID) {
        let isBroadcastRecipient: Bool = {
            guard let recipient = packet.recipientID else { return true }
            return recipient.count == 8 && recipient.allSatisfy { $0 == 0xFF }
        }()
        guard isBroadcastRecipient, !packet.payload.isEmpty else { return }

        gossipSyncManager?.onPublicPacketSeen(packet)

        let payload = packet.payload
        let timestamp = Date(timeIntervalSince1970: TimeInterval(packet.timestamp) / 1000)
        notifyUI { [weak self] in
            self?.deliverTransportEvent(.groupMessageReceived(payload: payload, timestamp: timestamp))
        }
    }

    /// Inbound public live-voice packet: broadcast-only, freshness-gated, and
    /// signature-verified against the claimed sender's announce (mirrors the
    /// public-message identity gate — `senderID` is attacker-controlled, so a
    /// valid packet signature is required before any audio reaches the UI).
    /// Returns whether the packet was accepted; rejected packets must not be
    /// relayed either, or spoofed 0x29 floods would still amplify.
    private func handleVoiceFrame(_ packet: BitchatPacket, from peerID: PeerID) -> Bool {
        guard peerID != myPeerID else { return false }
        guard BLEPacketFreshnessPolicy.isBroadcastRecipient(packet.recipientID) else { return false }
        guard !BLEPacketFreshnessPolicy.isStale(
            timestampMilliseconds: packet.timestamp,
            now: Date(),
            maxAgeSeconds: TransportConfig.pttPublicFrameMaxAgeSeconds
        ) else { return false }

        let peersSnapshot = peerRegistry.snapshotByID
        let registrySigningKey = peersSnapshot[peerID]?.signingPublicKey
        let verifiedViaRegistry = registrySigningKey.map { noiseService.verifyPacketSignature(packet, publicKey: $0) } ?? false
        let signedDisplayName = verifiedViaRegistry ? nil : signedSenderDisplayName(for: packet, from: peerID)
        guard verifiedViaRegistry || signedDisplayName != nil else {
            SecureLogger.warning("🚫 Dropping voice frame with missing/invalid signature for claimed sender \(peerID.id.prefix(8))…", category: .security)
            return false
        }
        guard let senderNickname = BLEPeerSenderDisplayName.resolveKnownPeer(
            peerID: peerID,
            localPeerID: myPeerID,
            localNickname: myNickname,
            peers: peersSnapshot,
            allowConnectedUnverified: false
        ) ?? signedDisplayName else {
            return false
        }

        let payload = packet.payload
        let timestamp = Date(timeIntervalSince1970: TimeInterval(packet.timestamp) / 1000)
        notifyUI { [weak self] in
            self?.deliverTransportEvent(.publicVoiceFrameReceived(
                peerID: peerID,
                nickname: senderNickname,
                payload: payload,
                timestamp: timestamp
            ))
        }
        return true
    }

    private func handleNoiseHandshake(_ packet: BitchatPacket, from peerID: PeerID) {
        let result = noisePacketHandler.handleHandshakeWithResult(
            packet,
            from: peerID
        )
        // An inbound message 1 quarantines the old transport receive-only.
        // Keep its generation-bound BLE state intact: the manager's new
        // handshaking generation already gates every outbound policy, while
        // a rollback can become ready again without repeating capability
        // proof or announce side effects. Only the exact handshake candidate's
        // authenticated completion may promote the physical ingress link.
        if result.didEstablishAuthenticatedSession {
            markNoiseAuthenticatedIngressLink(for: packet, peerID: peerID)
        }
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
                guard let self else {
                    return NoiseHandshakeProcessingResult(
                        response: nil,
                        didEstablishAuthenticatedSession: false
                    )
                }
                return try self.noiseService.processHandshakeMessageWithResult(
                    from: peerID,
                    message: message
                )
            },
            hasNoiseSession: { [weak self] peerID in
                self?.noiseService.hasSession(with: peerID) ?? false
            },
            isAwaitingResponderHandshakeCompletion: { [weak self] peerID in
                self?.noiseService.isAwaitingResponderHandshakeCompletion(
                    with: peerID
                ) ?? false
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
                // Decrypt runs on the engine queue; the readiness callback
                // fires on the noise manager's queue; the session store is
                // a leaf lock, so the read is safe from there.
                let result = try self.noiseService.decryptWithSessionGeneration(
                    payload,
                    from: peerID,
                    establishedGenerationIsReady: { generation in
                        self.privateMediaSessions.currentGeneration(
                            for: peerID.toShort()
                        ) == generation
                    }
                )
                return BLENoiseDecryptionResult(
                    plaintext: result.plaintext,
                    sessionGeneration: result.sessionGeneration
                )
            },
            clearSession: { [weak self] peerID in
                self?.clearNoiseSession(for: peerID)
            },
            handleAuthenticatedPeerState: { [weak self] peerID, payload, generation in
                self?.handleAuthenticatedPeerState(
                    payload,
                    from: peerID,
                    sessionGeneration: generation
                )
            },
            deliverNoisePayload: { [weak self] peerID, type, payload, timestamp in
                if type == .privateFile {
                    self?.fileTransferHandler.handlePrivatePayload(
                        payload,
                        from: peerID,
                        timestamp: timestamp
                    )
                    return
                }
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
        let payloads = onEngine { () -> [BLEPendingTypedPayload] in
            pendingNoiseSessionQueues.takeTypedPayloads(for: peerID)
        }
        guard !payloads.isEmpty else { return }
        SecureLogger.debug("📤 Sending \(payloads.count) pending noise payloads to \(peerID.id.prefix(8))… after handshake", category: .session)
        for pending in payloads {
            let isPrivateMedia = NoisePayloadType.isPrivateFile(rawValue: pending.payload.first)
            let privateMediaTransferId = isPrivateMedia ? pending.transferId : nil

            if isPrivateMedia {
                switch privateMediaSendPolicy(to: peerID) {
                case .encrypted:
                    break

                case .awaitingCapabilityProof:
                    // Handshake completion alone is insufficient. Put the
                    // exact payload back until authenticated 0x21 state
                    // arrives; that handler calls this drain again.
                    onEngine {
                        pendingNoiseSessionQueues.appendTypedPayload(
                            pending.payload,
                            transferId: pending.transferId,
                            for: peerID
                        )
                    }
                    continue

                case .legacyRequiresConsent, .blockedDowngrade:
                    if let transferId = pending.transferId {
                        TransferProgressManager.shared.rejectBeforeStart(
                            id: transferId,
                            reason: String(
                                localized: "content.delivery.reason.private_media_capability_unresolved",
                                defaultValue: "Could not confirm encrypted media support",
                                comment: "Failure reason when queued private media cannot be authenticated after handshake"
                            )
                        )
                        privateMediaTransferAdmissions.finish(transferId)
                    }
                    continue
                }
            }
            if let transferId = privateMediaTransferId,
               !privateMediaTransferAdmissions.isActive(transferId) {
                privateMediaTransferAdmissions.finish(transferId)
                continue
            }
            do {
                if let transferId = privateMediaTransferId,
                   !privateMediaTransferAdmissions.isActive(transferId) {
                    privateMediaTransferAdmissions.finish(transferId)
                    continue
                }
                let packet = try makeEncryptedNoisePacket(pending.payload, to: peerID)
                if let transferId = privateMediaTransferId,
                   !privateMediaTransferAdmissions.isActive(transferId) {
                    privateMediaTransferAdmissions.finish(transferId)
                    continue
                }
                broadcastPacket(
                    packet,
                    transferId: pending.transferId,
                    requiresPrivateMediaAdmission: privateMediaTransferId != nil
                )
            } catch {
                SecureLogger.error("❌ Failed to send pending noise payload to \(peerID.id.prefix(8))…: \(error)")
                if let transferId = pending.transferId {
                    TransferProgressManager.shared.rejectBeforeStart(
                        id: transferId,
                        reason: String(
                            localized: "content.delivery.reason.encryption_failed",
                            defaultValue: "Failed to encrypt media",
                            comment: "Failure reason shown when queued private media cannot be encrypted after handshake"
                        )
                    )
                    privateMediaTransferAdmissions.finish(transferId)
                }
            }
        }
    }
    
    private func updatePeerLastSeen(_ peerID: PeerID) {
        peerRegistry.mutate { $0.updateLastSeen(peerID, at: Date()) }
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
        let transportPeers = peerRegistry.transportSnapshots(selfNickname: myNickname)
        notifyUI { [weak self] in
            self?.peerEventsDelegate?.didUpdatePeerSnapshots(transportPeers)
        }
    }
    
    // MARK: Consolidated Maintenance
    
    private func performMaintenance() {
        guard !isPanicSuspended else { return }
        maintenanceCounter += 1
        lastMaintenanceAt = Date()

        let now = Date()
        let connectedCount = peerRegistry.connectedCount
        let elapsed = announceThrottle.elapsed(since: now)
        let recentSeen = recentTrafficTracker.hasTraffic(within: 5.0, now: now)
        let hasNoPeers = peerRegistry.isEmpty
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
                pm.startAdvertising(BLERadioController.advertisementData())
            }
        }
        
        // Update scanning duty-cycle based on connectivity
        radio.updateScanningDutyCycle(connectedCount: connectedCount)
        radio.updateRSSIThreshold(connectedCount: connectedCount)

        // Drain the connection candidate queue. Weak-RSSI discoveries are
        // enqueued rather than connected immediately, and the event-driven
        // drains (disconnect/failure/timeout) never fire when we're idle —
        // without this, an isolated node surrounded only by weak (distant)
        // peers would queue them all and never connect to anyone.
        radio.tryConnectFromQueue()
        
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
    
    #if os(iOS)
    /// Catch-up maintenance for background wake windows (bleQueue-confined).
    /// Rate-limited to the normal maintenance cadence so a burst of inbound
    /// packets during one wake still runs at most one extra pass.
    private func performBackgroundWakeMaintenanceIfStale() {
        guard meshBackgroundEnabled,
              !isAppActive,
              Date().timeIntervalSince(lastMaintenanceAt) >= TransportConfig.bleMaintenanceInterval else { return }
        performMaintenance()
    }
    #endif

    private func checkPeerConnectivity() {
        // Maintenance ticks on bleQueue; connectivity reconciliation reads
        // the engine-owned bindings, so it rides an engine slot.
        messageQueue.async { [weak self] in
            self?.checkPeerConnectivityOnEngine()
        }
    }

    private func checkPeerConnectivityOnEngine() {
        let now = Date()
        let peerIDsForLinkState: [PeerID] = peerRegistry.peerIDs
        var cachedLinkStates: [PeerID: BLEPeerLinkPresence] = [:]
        for peerID in peerIDsForLinkState {
            let state = linkState(for: peerID)
            cachedLinkStates[peerID] = BLEPeerLinkPresence(
                hasPeripheral: state.hasPeripheral,
                hasCentral: state.hasCentral
            )
        }
        
        let changes = peerRegistry.mutate {
            $0.reconcileConnectivity(now: now, linkStates: cachedLinkStates)
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
                let currentPeerIDs = self.peerRegistry.peerIDs
                
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

        // Admission expiry is a visible transfer failure, never a silent
        // eviction. The registry delivers notifications after releasing its
        // lock, so this maintenance pass cannot deadlock a concurrent cancel.
        privateMediaTransferAdmissions.prune(now: now)
        
        // Clean old processed messages efficiently
        messageDeduplicator.cleanup()
        
        // Clean old fragments (> configured seconds old), then ask peers for
        // the specific fragment streams whose reassembly has stalled instead
        // of waiting for the next periodic GCS fragment round.
        messageQueue.async { [weak self] in
            guard let self else { return }
            let cutoff = now.addingTimeInterval(-TransportConfig.bleFragmentLifetimeSeconds)
            self.fragmentAssemblyBuffer.removeExpired(before: cutoff)
            self.sourceRouteFailures.prune(now: now)
            let stalledFragmentIDs = self.fragmentAssemblyBuffer.stalledBroadcastFragmentIDs(
                stalledAfter: TransportConfig.bleFragmentResyncStallSeconds,
                retryAfter: TransportConfig.bleFragmentResyncRetrySeconds,
                now: now
            )
            if !stalledFragmentIDs.isEmpty {
                // GossipSyncManager serializes on its own internal queue.
                self.gossipSyncManager?.requestMissingFragments(fragmentIDs: stalledFragmentIDs)
            }
        }

        // Clean old connection timeout backoff entries (> window)
        let timeoutCutoff = now.addingTimeInterval(-TransportConfig.bleConnectTimeoutBackoffWindowSeconds)
        radio.pruneConnectionTimeouts(before: timeoutCutoff)

        // Clean up stale scheduled relays that somehow persisted (> 2s)
        messageQueue.async { [weak self] in
            guard let self = self else { return }
            // Nothing to compare times to; just cap the size defensively
            self.scheduledRelays.removeAllIfOverCapacity(512)
        }

        // Clean ingress link records older than configured seconds
        messageQueue.async { [weak self] in
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

        messageQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.selfBroadcastTracker.isEmpty else { return }
            let cutoff = now.addingTimeInterval(-TransportConfig.messageDedupMaxAgeSeconds)
            self.selfBroadcastTracker.prune(before: cutoff)
        }
    }

}
