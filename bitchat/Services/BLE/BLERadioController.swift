import BitLogger
import CoreBluetooth
import Foundation

/// The radio's contact points back into the transport. All calls arrive on
/// bleQueue.
protocol BLERadioControllerDelegate: AnyObject {
    /// Whether a panic wipe has quiesced the radio.
    func radioIsPanicSuspended() -> Bool
    /// iOS app-active snapshot (drives allow-duplicates scanning and
    /// background connect deferral); always true on macOS.
    func radioIsAppActive() -> Bool
    /// A connect attempt died (timeout or foreground stale-reclaim): retire
    /// the link's transport bookkeeping — write buffers, link-auth proof,
    /// reconnect epoch, and the link-state entry itself.
    func radioTearDownPeripheralLink(_ peripheralID: String)
    /// A discovery entered the connection candidate queue; wake maintenance
    /// from idle cadence so the first weak peer is drained promptly.
    func radioDidQueueConnectionCandidate()
}

/// bleQueue-confined owner of the central-role radio policy: discovery
/// admission, the connection budget and queue, connect timeouts,
/// wake-on-proximity background connects, scan duty-cycling, RSSI
/// adaptation, and the advertising payload.
///
/// First slice of the link layer (docs/BLE-ARCHITECTURE-V3.md): this type
/// makes no peer decisions and owns no bindings or security state — it
/// shares the bleQueue-confined link-state store for admission reads and
/// asks its delegate to tear down transport bookkeeping when an attempt
/// dies.
final class BLERadioController {
    weak var delegate: BLERadioControllerDelegate?
    /// The transport is every peripheral's CBPeripheralDelegate; connects
    /// initiated here must point new peripherals at it.
    weak var peripheralDelegate: CBPeripheralDelegate?
    /// Attached when the transport creates (or restores) its managers.
    weak var central: CBCentralManager?

    private let queue: DispatchQueue
    private let linkStateStore: BLELinkStateStore
    private let recentTraffic: BLERecentTrafficMonitor

    // Connection budget & scheduling (central role)
    private var scheduler = BLEConnectionScheduler<CBPeripheral>()
    // Recently seen peripherals retained for background wake-on-proximity
    // connects
    private let recentPeripheralCache = BLERecentPeripheralCache<CBPeripheral>()

    // Adaptive scanning duty-cycle
    private var scanDutyTimer: DispatchSourceTimer?
    private var dutyResumeWorkItem: DispatchWorkItem?
    private var dutyOnDuration: TimeInterval = TransportConfig.bleDutyOnDuration
    private var dutyOffDuration: TimeInterval = TransportConfig.bleDutyOffDuration
    private var dutyActive: Bool = false
    private var lastScanAllowDuplicates: Bool?
    private var fragmentScanPauses = BLEFragmentScanPauseTracker<UUID, DispatchWorkItem>()

    init(
        queue: DispatchQueue,
        linkStateStore: BLELinkStateStore,
        recentTraffic: BLERecentTrafficMonitor
    ) {
        self.queue = queue
        self.linkStateStore = linkStateStore
        self.recentTraffic = recentTraffic
    }

    deinit {
        dutyResumeWorkItem?.cancel()
        scanDutyTimer?.cancel()
        for handle in fragmentScanPauses.cancelAll() {
            handle.cancel()
        }
    }

    // MARK: - Advertising

    static func advertisementData() -> [String: Any] {
        // No Local Name for privacy.
        [CBAdvertisementDataServiceUUIDsKey: [BLEService.serviceUUID]]
    }

    // MARK: - Scanning

    private var desiredAllowDuplicates: Bool {
        // Allow duplicates while active and below the central link budget for
        // fast discovery. Under Low Power Mode, in background, or once all
        // central link slots are saturated, coalesced CoreBluetooth discoveries
        // avoid waking the CPU on every nearby BLE advertising beacon.
        let isSaturated = linkStateStore.connectedOrConnectingPeripheralCount >= TransportConfig.bleMaxCentralLinks
        return (delegate?.radioIsAppActive() ?? true)
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && !isSaturated
    }

    func startScanning() {
        guard !fragmentScanPauses.isPaused,
              delegate?.radioIsPanicSuspended() == false,
              let central,
              central.state == .poweredOn,
              !central.isScanning else { return }

        let allowDuplicates = desiredAllowDuplicates
        lastScanAllowDuplicates = allowDuplicates
        central.scanForPeripherals(
            withServices: [BLEService.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
    }

    #if os(iOS)
    /// Stops any active scan and restarts it with current options on `bleQueue`.
    func restartScanning() {
        guard delegate?.radioIsPanicSuspended() == false,
              let central,
              central.state == .poweredOn else { return }
        if central.isScanning {
            central.stopScan()
        }
        lastScanAllowDuplicates = nil
        startScanning()
    }
    #endif

    /// Ensures scanning is active with up-to-date options (e.g. if Low Power
    /// Mode toggled while a scan was already running).
    private func ensureScanningWithCurrentOptions() {
        guard !fragmentScanPauses.isPaused,
              delegate?.radioIsPanicSuspended() == false,
              let central,
              central.state == .poweredOn else { return }
        let desired = desiredAllowDuplicates
        if central.isScanning {
            guard lastScanAllowDuplicates != desired else { return }
            central.stopScan()
            lastScanAllowDuplicates = nil
        }
        startScanning()
    }

    func beginFragmentScanPause(token: UUID, duration: TimeInterval) {
        guard delegate?.radioIsPanicSuspended() == false,
              let central,
              central.state == .poweredOn,
              central.isScanning || scanDutyTimer != nil || fragmentScanPauses.isPaused else { return }
        if central.isScanning {
            central.stopScan()
            lastScanAllowDuplicates = nil
        }
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.fragmentScanPauses.timeoutFired(token: token) {
                self.resumeScanningAfterFragmentPauseIfAllowed()
            }
        }
        let transition = fragmentScanPauses.begin(token: token, timeoutHandle: timeoutWork)
        transition.replacedHandle?.cancel()
        queue.asyncAfter(deadline: .now() + duration, execute: timeoutWork)
    }

    func endFragmentScanPause(token: UUID) {
        let result = fragmentScanPauses.end(token: token)
        result.removedHandle?.cancel()
        if result.shouldResumeScanning {
            resumeScanningAfterFragmentPauseIfAllowed()
        }
    }

    func cancelFragmentScanPauses() {
        for handle in fragmentScanPauses.cancelAll() {
            handle.cancel()
        }
    }

    private func resumeScanningAfterFragmentPauseIfAllowed() {
        guard !fragmentScanPauses.isPaused else { return }
        if scanDutyTimer != nil && !dutyActive {
            return
        }
        startScanning()
    }

    func updateScanningDutyCycle(connectedCount: Int) {
        guard let central, central.state == .poweredOn else { return }
        // Duty cycle only when the app is active and at least one peer is
        // connected (or in Low Power Mode); force full-time scanning during
        // active traffic bursts.
        let hasRecentTraffic = recentTraffic.hasTraffic(
            within: TransportConfig.bleRecentTrafficForceScanSeconds,
            now: Date()
        )
        let scanPlan = BLEScanDutyPolicy.plan(
            appIsActive: delegate?.radioIsAppActive() ?? true,
            connectedCount: connectedCount,
            hasRecentTraffic: hasRecentTraffic,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )

        switch scanPlan {
        case .dutyCycle(let onDuration, let offDuration):
            let durationsChanged = dutyOnDuration != onDuration || dutyOffDuration != offDuration
            dutyOnDuration = onDuration
            dutyOffDuration = offDuration

            if scanDutyTimer == nil {
                // Start with scanning ON; turn OFF after onDuration.
                let t = DispatchSource.makeTimerSource(queue: queue)
                ensureScanningWithCurrentOptions()
                dutyActive = true
                // 1s leeway allows OS timer coalescing and reduces idle CPU wakeups.
                t.schedule(deadline: .now() + dutyOnDuration, repeating: dutyOnDuration + dutyOffDuration, leeway: .seconds(1))
                t.setEventHandler { [weak self] in
                    guard let self, let c = self.central else { return }
                    if self.dutyActive {
                        if c.isScanning {
                            c.stopScan()
                            self.lastScanAllowDuplicates = nil
                        }
                        self.dutyActive = false
                        self.dutyResumeWorkItem?.cancel()
                        let resumeWork = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            self.dutyResumeWorkItem = nil
                            guard self.scanDutyTimer != nil,
                                  self.delegate?.radioIsPanicSuspended() == false else { return }
                            if self.central?.state == .poweredOn { self.startScanning() }
                            self.dutyActive = true
                        }
                        self.dutyResumeWorkItem = resumeWork
                        self.queue.asyncAfter(deadline: .now() + self.dutyOffDuration, execute: resumeWork)
                    }
                }
                t.resume()
                scanDutyTimer = t
            } else if durationsChanged {
                dutyResumeWorkItem?.cancel()
                dutyResumeWorkItem = nil
                scanDutyTimer?.schedule(deadline: .now() + dutyOnDuration, repeating: dutyOnDuration + dutyOffDuration, leeway: .seconds(1))
                ensureScanningWithCurrentOptions()
                dutyActive = true
            } else if dutyActive {
                ensureScanningWithCurrentOptions()
            }
        case .continuous:
            // Cancel duty cycle and ensure scanning is ON with current options.
            stopDutyCycle()
            ensureScanningWithCurrentOptions()
        }
    }

    func stopDutyCycle() {
        dutyResumeWorkItem?.cancel()
        dutyResumeWorkItem = nil
        scanDutyTimer?.cancel()
        scanDutyTimer = nil
        dutyActive = false
    }

    func updateRSSIThreshold(connectedCount: Int) {
        scheduler.updateRSSIThreshold(
            connectedCount: connectedCount,
            connectedOrConnectingLinkCount: linkStateStore.connectedOrConnectingPeripheralCount,
            now: Date()
        )
    }

    // MARK: - Discovery & connection budget

    func handleDiscovery(
        _ peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        guard delegate?.radioIsPanicSuspended() == false, let central else { return }
        let peripheralID = peripheral.identifier.uuidString
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? (peripheralID.prefix(6) + "…")
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true

        let candidate = BLEConnectionCandidate(
            peripheral: peripheral,
            peripheralID: peripheralID,
            rssi: rssi.intValue,
            name: String(advertisedName),
            isConnectable: isConnectable,
            discoveredAt: Date()
        )
        if isConnectable {
            recentPeripheralCache.record(peripheral, peripheralID: peripheralID, at: candidate.discoveredAt)
        }
        let existingState = linkStateStore.state(forPeripheralID: peripheralID).map(BLEExistingConnectionState.init)

        switch scheduler.handleDiscovery(
            candidate,
            connectedOrConnectingCount: linkStateStore.connectedOrConnectingPeripheralCount,
            existingState: existingState,
            peripheralState: peripheral.state.connectionSchedulerState,
            now: candidate.discoveredAt
        ) {
        case .ignore:
            return
        case .queued:
            delegate?.radioDidQueueConnectionCandidate()
            return
        case .scheduleRetry(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
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

    func tryConnectFromQueue() {
        guard delegate?.radioIsPanicSuspended() == false,
              let central,
              central.state == .poweredOn else { return }

        let decision = scheduler.nextCandidate(
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
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tryConnectFromQueue() }
        case .connect(let candidate):
            beginCentralConnection(candidate, using: central, logPrefix: "⏩ Queue connect")
        }
    }

    private func beginCentralConnection(
        _ candidate: BLEConnectionCandidate<CBPeripheral>,
        using central: CBCentralManager,
        logPrefix: String
    ) {
        guard delegate?.radioIsPanicSuspended() == false else { return }
        let peripheral = candidate.peripheral
        let peripheralID = candidate.peripheralID
        linkStateStore.beginConnecting(to: peripheral, at: Date())
        peripheral.delegate = peripheralDelegate
        let options: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ]
        central.connect(peripheral, options: options)
        scheduler.recordConnectionAttempt(at: Date())
        SecureLogger.debug("\(logPrefix): \(candidate.name) [RSSI:\(candidate.rssi)]", category: .session)

        queue.asyncAfter(deadline: .now() + TransportConfig.bleConnectTimeoutSeconds) { [weak self] in
            guard let self,
                  let state = self.linkStateStore.state(forPeripheralID: peripheralID),
                  state.isConnecting && !state.isConnected else { return }

            guard peripheral.state != .connected else {
                SecureLogger.debug("⏱️ Timeout fired but peripheral already connected: \(candidate.name)", category: .session)
                return
            }

            if self.delegate?.radioIsAppActive() == false {
                // Backgrounded: leave the connect pending. iOS never expires
                // it — the controller completes it whenever the peer comes
                // back into range, waking the app (state restoration
                // relaunches us if we were terminated). Foreground return
                // cancels stale pendings via cancelStalePendingConnects().
                SecureLogger.info("🌙 Connect timeout deferred while backgrounded, left pending for wake-on-proximity: \(candidate.name)", category: .session)
                return
            }

            SecureLogger.debug("⏱️ Timeout: \(candidate.name)", category: .session)
            central.cancelPeripheralConnection(peripheral)
            self.delegate?.radioTearDownPeripheralLink(peripheralID)
            self.scheduler.recordConnectionTimeout(peripheralID: peripheralID, at: Date())
            self.tryConnectFromQueue()
        }
    }

    // MARK: - Scheduler bookkeeping (called from the transport's delegates)

    var candidateCount: Int { scheduler.candidateCount }

    func recordConnectionSuccess(peripheralID: String) {
        scheduler.recordConnectionSuccess(peripheralID: peripheralID)
    }

    func recordConnectionFailure(peripheralID: String) {
        scheduler.recordConnectionFailure(peripheralID: peripheralID)
    }

    func recordDisconnectError(peripheralID: String, at date: Date) {
        scheduler.recordDisconnectError(peripheralID: peripheralID, at: date)
    }

    func recordRecentPeripheral(_ peripheral: CBPeripheral, peripheralID: String, at date: Date) {
        recentPeripheralCache.record(peripheral, peripheralID: peripheralID, at: date)
    }

    func pruneConnectionTimeouts(before cutoff: Date) {
        scheduler.pruneConnectionTimeouts(before: cutoff)
    }

    /// Panic wipe: drop the candidate queue, backoff state, and RSSI
    /// adaptation with the identity they served.
    func reset() {
        cancelFragmentScanPauses()
        scheduler.reset()
    }

    #if os(iOS)
    // MARK: - Background wake-on-proximity

    /// Backgrounding hands the freed connection budget to iOS as pending
    /// connects against recently seen peers: the controller completes one
    /// whenever its peer comes into range, waking (or relaunching) the app.
    /// A couple of central slots stay reserved for connects driven by live
    /// background discovery — except on the disconnect re-arm path, which
    /// may consume the slot the disconnect itself just freed (a dense mesh
    /// with 4+ remaining links would otherwise compute a zero budget and
    /// never re-arm the lost peer).
    func armPendingBackgroundConnects(
        slotReserve: Int = TransportConfig.bleBackgroundPendingConnectSlotReserve
    ) {
        queue.async { [weak self] in
            guard let self,
                  self.delegate?.radioIsPanicSuspended() == false,
                  let central = self.central,
                  central.state == .poweredOn else { return }
            let budget = TransportConfig.bleMaxCentralLinks
                - slotReserve
                - self.linkStateStore.connectedOrConnectingPeripheralCount
            let now = Date()
            let targets = self.recentPeripheralCache.reconnectTargets(now: now, limit: budget) { peripheralID in
                let state = self.linkStateStore.state(forPeripheralID: peripheralID)
                return state?.isConnected == true || state?.isConnecting == true
            }
            guard !targets.isEmpty else { return }
            for target in targets {
                // lastConnectionAttempt stays nil: an indefinite pending
                // connect has no attempt clock, and nil marks it always-stale
                // so cancelStalePendingConnects() reclaims it on foreground
                // even after a quick background→foreground bounce.
                self.linkStateStore.setPeripheralState(
                    BLEPeripheralLinkState(
                        peripheral: target.peripheral,
                        characteristic: nil,
                        isConnecting: true,
                        isConnected: false,
                        lastConnectionAttempt: nil,
                        assembler: NotificationStreamAssembler()
                    ),
                    for: target.peripheralID
                )
                target.peripheral.delegate = self.peripheralDelegate
                central.connect(target.peripheral, options: [
                    CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                    CBConnectPeripheralOptionNotifyOnNotificationKey: true
                ])
            }
            SecureLogger.info("🌙 Armed \(targets.count) pending background connect(s) for wake-on-proximity", category: .session)
        }
    }

    /// Foreground restores normal connection management: pending connects
    /// older than the connect timeout (including ones rebuilt by state
    /// restoration after a relaunch) are cancelled so live scanning and the
    /// scheduler take over. Anything still nearby is rediscovered within
    /// seconds by the allow-duplicates foreground scan.
    func cancelStalePendingConnects() {
        queue.async { [weak self] in
            guard let self, let central = self.central else { return }
            let now = Date()
            var cancelled = 0
            for state in self.linkStateStore.peripheralStates where state.isConnecting && !state.isConnected {
                let age = state.lastConnectionAttempt.map { now.timeIntervalSince($0) } ?? .infinity
                guard age > TransportConfig.bleConnectTimeoutSeconds else { continue }
                let peripheralID = state.peripheral.identifier.uuidString
                central.cancelPeripheralConnection(state.peripheral)
                self.delegate?.radioTearDownPeripheralLink(peripheralID)
                cancelled += 1
            }
            if cancelled > 0 {
                SecureLogger.info("🌅 Cancelled \(cancelled) stale pending connect(s) on foreground", category: .session)
                self.tryConnectFromQueue()
            }
        }
    }
    #endif
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


// MARK: - Scan Duty Policy

enum BLEScanDutyPlan: Equatable {
    case continuous
    case dutyCycle(onDuration: TimeInterval, offDuration: TimeInterval)
}

enum BLEScanDutyPolicy {
    static func plan(
        appIsActive: Bool,
        connectedCount: Int,
        hasRecentTraffic: Bool,
        highDegreeThreshold: Int = TransportConfig.bleHighDegreeThreshold,
        lowPowerMode: Bool = false
    ) -> BLEScanDutyPlan {
        if lowPowerMode && appIsActive && !hasRecentTraffic {
            if connectedCount >= highDegreeThreshold {
                return .dutyCycle(onDuration: 2.0, offDuration: 20.0)
            }
            return .dutyCycle(
                onDuration: TransportConfig.bleDutyOnDurationDense,
                offDuration: TransportConfig.bleDutyOffDurationDense
            )
        }

        // Duty-cycle whenever the app is active and idle—including solo and
        // 1–2 peer meshes—so idle phones don't run continuous foreground scans.
        // Recent active traffic briefly holds continuous scanning for snappy
        // convergence; background scans stay continuous because CoreBluetooth
        // already hardware-coalesces them.
        let shouldDutyCycle = appIsActive && !hasRecentTraffic

        guard shouldDutyCycle else {
            return .continuous
        }

        if connectedCount >= highDegreeThreshold {
            return .dutyCycle(
                onDuration: TransportConfig.bleDutyOnDurationDense,
                offDuration: TransportConfig.bleDutyOffDurationDense
            )
        }

        return .dutyCycle(
            onDuration: TransportConfig.bleDutyOnDuration,
            offDuration: TransportConfig.bleDutyOffDuration
        )
    }
}

// MARK: - Recent Peripheral Cache

/// Remembers recently seen bitchat peripherals so pending background connects
/// can be armed when the app leaves the foreground.
final class BLERecentPeripheralCache<Peripheral> {
    private struct Entry {
        let peripheral: Peripheral
        var lastSeen: Date
    }

    private var entries: [String: Entry] = [:]
    private let capacity: Int
    private let maxAge: TimeInterval

    init(
        capacity: Int = TransportConfig.bleRecentPeripheralCacheCap,
        maxAge: TimeInterval = TransportConfig.bleRecentPeripheralMaxAgeSeconds
    ) {
        self.capacity = capacity
        self.maxAge = maxAge
    }

    var count: Int { entries.count }

    func record(_ peripheral: Peripheral, peripheralID: String, at now: Date) {
        entries[peripheralID] = Entry(peripheral: peripheral, lastSeen: now)
        guard entries.count > capacity else { return }
        if let stalest = entries.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
            entries.removeValue(forKey: stalest.key)
        }
    }

    func reconnectTargets(
        now: Date,
        limit: Int,
        excluding: (String) -> Bool
    ) -> [(peripheralID: String, peripheral: Peripheral)] {
        let cutoff = now.addingTimeInterval(-maxAge)
        entries = entries.filter { $0.value.lastSeen >= cutoff }
        guard limit > 0 else { return [] }
        return entries
            .filter { !excluding($0.key) }
            .sorted { $0.value.lastSeen > $1.value.lastSeen }
            .prefix(limit)
            .map { (peripheralID: $0.key, peripheral: $0.value.peripheral) }
    }
}

// MARK: - Fragment Scan Pause Tracker

/// Tracks overlapping fragment-train scan pauses so scanning stays paused until
/// every active train finishes or times out, and all pending timeouts cancel
/// cleanly on stop, panic reset, or Bluetooth power-off.
struct BLEFragmentScanPauseTracker<Token: Hashable, TimeoutHandle> {
    private var activePauses: [Token: TimeoutHandle] = [:]

    var isPaused: Bool {
        !activePauses.isEmpty
    }

    var activeCount: Int {
        activePauses.count
    }

    @discardableResult
    mutating func begin(
        token: Token,
        timeoutHandle: TimeoutHandle
    ) -> (becamePaused: Bool, replacedHandle: TimeoutHandle?) {
        let wasPaused = isPaused
        let replacedHandle = activePauses.updateValue(timeoutHandle, forKey: token)
        return (becamePaused: !wasPaused, replacedHandle: replacedHandle)
    }

    mutating func end(
        token: Token
    ) -> (removedHandle: TimeoutHandle?, shouldResumeScanning: Bool) {
        guard let removed = activePauses.removeValue(forKey: token) else {
            return (nil, false)
        }
        return (removed, activePauses.isEmpty)
    }

    mutating func timeoutFired(token: Token) -> Bool {
        guard activePauses.removeValue(forKey: token) != nil else {
            return false
        }
        return activePauses.isEmpty
    }

    mutating func cancelAll() -> [TimeoutHandle] {
        let handles = Array(activePauses.values)
        activePauses.removeAll(keepingCapacity: false)
        return handles
    }
}
