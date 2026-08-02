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
    private var dutyEnabled: Bool = true
    private var dutyOnDuration: TimeInterval = TransportConfig.bleDutyOnDuration
    private var dutyOffDuration: TimeInterval = TransportConfig.bleDutyOffDuration
    private var dutyActive: Bool = false

    init(
        queue: DispatchQueue,
        linkStateStore: BLELinkStateStore,
        recentTraffic: BLERecentTrafficMonitor
    ) {
        self.queue = queue
        self.linkStateStore = linkStateStore
        self.recentTraffic = recentTraffic
    }

    // MARK: - Advertising

    static func advertisementData() -> [String: Any] {
        // No Local Name for privacy.
        [CBAdvertisementDataServiceUUIDsKey: [BLEService.serviceUUID]]
    }

    // MARK: - Scanning

    func startScanning() {
        guard delegate?.radioIsPanicSuspended() == false,
              let central,
              central.state == .poweredOn,
              !central.isScanning else { return }

        // Allow duplicates while active for faster discovery: immediate
        // discovery events instead of coalesced ones.
        let allowDuplicates = delegate?.radioIsAppActive() ?? true
        central.scanForPeripherals(
            withServices: [BLEService.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
    }

    func updateScanningDutyCycle(connectedCount: Int) {
        guard let central, central.state == .poweredOn else { return }
        // Duty cycle only when the app is active and at least one peer is
        // connected; force full-time scanning with few neighbors or very
        // recent traffic.
        let hasRecentTraffic = recentTraffic.hasTraffic(
            within: TransportConfig.bleRecentTrafficForceScanSeconds,
            now: Date()
        )
        let scanPlan = BLEScanDutyPolicy.plan(
            dutyEnabled: dutyEnabled,
            appIsActive: delegate?.radioIsAppActive() ?? true,
            connectedCount: connectedCount,
            hasRecentTraffic: hasRecentTraffic
        )

        switch scanPlan {
        case .dutyCycle(let onDuration, let offDuration):
            let durationsChanged = dutyOnDuration != onDuration || dutyOffDuration != offDuration
            dutyOnDuration = onDuration
            dutyOffDuration = offDuration

            if scanDutyTimer == nil {
                // Start with scanning ON; turn OFF after onDuration.
                let t = DispatchSource.makeTimerSource(queue: queue)
                if !central.isScanning { startScanning() }
                dutyActive = true
                t.schedule(deadline: .now() + dutyOnDuration, repeating: dutyOnDuration + dutyOffDuration)
                t.setEventHandler { [weak self] in
                    guard let self, let c = self.central else { return }
                    if self.dutyActive {
                        if c.isScanning { c.stopScan() }
                        self.dutyActive = false
                        self.queue.asyncAfter(deadline: .now() + self.dutyOffDuration) {
                            if self.central?.state == .poweredOn { self.startScanning() }
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
            // Cancel duty cycle and ensure scanning is ON for discovery.
            scanDutyTimer?.cancel()
            scanDutyTimer = nil
            if !central.isScanning { startScanning() }
        }
    }

    func stopDutyCycle() {
        scanDutyTimer?.cancel()
        scanDutyTimer = nil
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
        case .ignore, .queued:
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
