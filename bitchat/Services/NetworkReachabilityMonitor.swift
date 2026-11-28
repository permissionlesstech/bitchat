import Foundation
import Combine
import BitLogger
#if canImport(Network)
import Network
#endif

/// Coarse, conservative network-reachability signal used to gate Tor bootstrap
/// and Nostr relay connections.
///
/// Policy (deliberately conservative):
/// - Reports `false` only when the OS says there is *no* usable interface at
///   all (`NWPath.Status.unsatisfied`). A flaky-but-present link stays
///   `true` because Tor tolerates intermittent connectivity, and tearing down
///   on the first hiccup would cost more battery/latency than it saves.
/// - Transitions are debounced (see `ReachabilityDebounce`) so path flapping
///   does not thrash Tor/relay startup.
/// - Starts optimistic (`true`) so nothing is ever suppressed before the first
///   path evaluation arrives.
///
/// BLE mesh must never consult this monitor — the mesh works fully offline.
@MainActor
protocol NetworkReachabilityMonitoring: AnyObject {
    /// Current debounced coarse reachability.
    var isReachable: Bool { get }
    /// Emits the debounced reachability whenever it changes (main-actor).
    var reachabilityPublisher: AnyPublisher<Bool, Never> { get }
    /// Emits when the underlying network path recovers from a brief blip or
    /// switches interfaces (e.g. Wi-Fi ↔ Cellular) while `isReachable` stays
    /// `true`. Lets relay managers clear transient DNS/backoff failures
    /// without disrupting already-healthy sockets.
    var pathDidChangePublisher: AnyPublisher<Void, Never> { get }
    /// Begin monitoring. Idempotent.
    func start()
    /// Stop monitoring and discard pending debounce work. Idempotent.
    func stop()
}

extension NetworkReachabilityMonitoring {
    var pathDidChangePublisher: AnyPublisher<Void, Never> {
        Empty().eraseToAnyPublisher()
    }
}

/// Coarse fingerprint of active satisfied network interfaces so Wi-Fi ↔
/// Cellular transitions can be detected without flapping on unrelated path
/// metadata changes.
struct NetworkInterfaceSignature: Equatable {
    let usesWiFi: Bool
    let usesCellular: Bool
    let usesWired: Bool
    let usesOther: Bool

    #if canImport(Network)
    init(path: NWPath) {
        self.usesWiFi = path.usesInterfaceType(.wifi)
        self.usesCellular = path.usesInterfaceType(.cellular)
        self.usesWired = path.usesInterfaceType(.wiredEthernet)
        self.usesOther = path.usesInterfaceType(.other)
    }
    #endif

    init(usesWiFi: Bool = false, usesCellular: Bool = false, usesWired: Bool = false, usesOther: Bool = false) {
        self.usesWiFi = usesWiFi
        self.usesCellular = usesCellular
        self.usesWired = usesWired
        self.usesOther = usesOther
    }
}

/// Pure debounce/decision logic for reachability, split out so it can be
/// unit-tested without the Network framework or real timers.
///
/// A candidate state only becomes the committed state once it has been stable
/// (uninterrupted) for `interval`. Any observation matching the committed state
/// cancels a pending opposite change, which is what makes flapping a no-op.
struct ReachabilityDebounce {
    let interval: TimeInterval
    private(set) var committed: Bool
    private var pending: (value: Bool, since: Date)?

    init(interval: TimeInterval, initial: Bool) {
        self.interval = interval
        self.committed = initial
    }

    /// Whether a change is currently waiting out the debounce window.
    var hasPendingChange: Bool { pending != nil }

    /// Time left before the pending change may commit, or `nil` when nothing
    /// is pending. Lets callers schedule a flush at the true deadline instead
    /// of a full interval from "now" (duplicate observations must not push
    /// the deadline out).
    func pendingRemaining(at now: Date) -> TimeInterval? {
        guard let pending else { return nil }
        return max(0, interval - now.timeIntervalSince(pending.since))
    }

    /// Feed a raw observation. Returns the new committed value if it changed,
    /// otherwise `nil`.
    mutating func observe(reachable: Bool, at now: Date) -> Bool? {
        if reachable == committed {
            // Already in this state — cancel any pending opposite change.
            pending = nil
            return nil
        }
        // Differs from committed: (re)arm the pending change, preserving the
        // timestamp if we're already waiting on this same target value.
        if pending?.value != reachable {
            pending = (reachable, now)
        }
        return commitIfAged(at: now)
    }

    /// Called from a timer to commit a pending change once it has aged past
    /// `interval`. Returns the new committed value if it changed, else `nil`.
    mutating func flush(at now: Date) -> Bool? {
        commitIfAged(at: now)
    }

    private mutating func commitIfAged(at now: Date) -> Bool? {
        guard let pending else { return nil }
        guard now.timeIntervalSince(pending.since) >= interval else { return nil }
        committed = pending.value
        self.pending = nil
        return committed
    }
}

/// `NWPathMonitor`-backed reachability. All state lives on the main actor; the
/// background path callback hops here before touching the debounce.
@MainActor
final class NWPathReachabilityMonitor: NetworkReachabilityMonitoring {
    private let subject: CurrentValueSubject<Bool, Never>
    private let pathChangeSubject = PassthroughSubject<Void, Never>()
    private var debounce: ReachabilityDebounce
    private var flushWorkItem: DispatchWorkItem?
    private var lastSatisfiedInterfaceSignature: NetworkInterfaceSignature?
    private var started = false
    private let now: () -> Date

    #if canImport(Network)
    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "chat.bitchat.reachability")
    #endif

    init(debounceInterval: TimeInterval = 2.5, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.debounce = ReachabilityDebounce(interval: debounceInterval, initial: true)
        self.subject = CurrentValueSubject(true)
    }

    var isReachable: Bool { subject.value }

    var reachabilityPublisher: AnyPublisher<Bool, Never> {
        subject.removeDuplicates().dropFirst().eraseToAnyPublisher()
    }

    var pathDidChangePublisher: AnyPublisher<Void, Never> {
        pathChangeSubject.eraseToAnyPublisher()
    }

    func start() {
        guard !started else { return }
        started = true
        #if canImport(Network)
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            // Conservative: only "no interface at all" counts as unreachable.
            let reachable = path.status != .unsatisfied
            let signature = reachable ? NetworkInterfaceSignature(path: path) : nil
            Task { @MainActor in
                self?.ingest(reachable: reachable, interfaceSignature: signature)
            }
        }
        monitor.start(queue: monitorQueue)
        #else
        // No Network framework: never suppress startup.
        #endif
    }

    func stop() {
        guard started else { return }
        started = false
        flushWorkItem?.cancel()
        flushWorkItem = nil
        lastSatisfiedInterfaceSignature = nil
        #if canImport(Network)
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
        #endif
    }

    /// Feed an observation into the debounce and publish committed changes.
    /// Exposed internally so higher layers/tests could drive it if needed.
    func ingest(reachable: Bool, interfaceSignature: NetworkInterfaceSignature? = nil) {
        let hadPendingDrop = debounce.hasPendingChange && debounce.committed
        flushWorkItem?.cancel()
        flushWorkItem = nil
        if let committed = debounce.observe(reachable: reachable, at: now()) {
            if committed {
                lastSatisfiedInterfaceSignature = interfaceSignature
            } else {
                lastSatisfiedInterfaceSignature = nil
            }
            publish(committed)
        } else if debounce.hasPendingChange {
            scheduleFlush()
        } else if reachable && debounce.committed {
            // Still committed-reachable, but either a brief (<debounce) offline
            // blip just cleared or the active interface changed (e.g. Wi-Fi ↔
            // Cellular). Notify listeners so failed/DNS-blacklisted relays can
            // retry immediately instead of waiting out the 10-minute cooldown.
            var interfaceChanged = false
            if let interfaceSignature {
                if let previous = lastSatisfiedInterfaceSignature, previous != interfaceSignature {
                    interfaceChanged = true
                }
                lastSatisfiedInterfaceSignature = interfaceSignature
            }
            if hadPendingDrop || interfaceChanged {
                SecureLogger.debug(
                    "NWPathReachabilityMonitor: path recovered/switched (pendingDrop=\(hadPendingDrop), interfaceChanged=\(interfaceChanged))",
                    category: .session
                )
                pathChangeSubject.send(())
            }
        }
    }

    private func scheduleFlush() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let committed = self.debounce.flush(at: self.now()) {
                if !committed {
                    self.lastSatisfiedInterfaceSignature = nil
                }
                self.publish(committed)
            }
        }
        flushWorkItem = work
        // Fire at the pending change's real deadline (pending.since + interval):
        // duplicate path updates re-enter here and must not restart the window.
        let delay = debounce.pendingRemaining(at: now()) ?? debounce.interval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func publish(_ reachable: Bool) {
        SecureLogger.info("NWPathReachabilityMonitor: network reachable -> \(reachable)", category: .session)
        subject.send(reachable)
    }
}
