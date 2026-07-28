import BitLogger
import Foundation
#if canImport(Network)
import Network
#endif

#if !canImport(Network)
private final class NWPathMonitor {
    var pathUpdateHandler: ((Any) -> Void)?

    func start(queue: DispatchQueue) {
        // Path monitoring is unavailable on this platform; nothing to do.
    }
}
#endif

// FFI declarations for Arti (Rust)
@_silgen_name("arti_start")
private func arti_start(_ dataDir: UnsafePointer<CChar>, _ socksPort: UInt16) -> Int32

#if os(iOS)
    @_silgen_name("arti_start_with_config")
    private func arti_start_with_config(
        _ dataDir: UnsafePointer<CChar>,
        _ socksPort: UInt16,
        _ configJSON: UnsafePointer<CChar>
    ) -> Int32

    @_silgen_name("arti_validate_transport_config")
    private func arti_validate_transport_config(
        _ configJSON: UnsafePointer<CChar>
    ) -> Int32

    @_silgen_name("arti_set_diagnostics_enabled")
    private func arti_set_diagnostics_enabled(_ enabled: Int32) -> Int32

    @_silgen_name("arti_next_diagnostic")
    private func arti_next_diagnostic(
        _ buf: UnsafeMutablePointer<CChar>,
        _ len: Int32
    ) -> Int32
#endif

@_silgen_name("arti_stop")
private func arti_stop() -> Int32

@_silgen_name("arti_is_running")
private func arti_is_running() -> Int32

@_silgen_name("arti_bootstrap_progress")
private func arti_bootstrap_progress() -> Int32

@_silgen_name("arti_bootstrap_summary")
private func arti_bootstrap_summary(_ buf: UnsafeMutablePointer<CChar>, _ len: Int32) -> Int32

/// One-shot gate for the SOCKS probe's continuation.
///
/// The connection's state handler and the probe's own timeout both run on the
/// global concurrent queue, so the plain flag they used to share could let both
/// of them resume the same continuation. Resuming a checked continuation twice
/// traps, which turns a probe answering at the wrong moment into a crash.
private final class ProbeContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Arti-based Tor integration for BitChat.
/// - Boots a local Arti client and exposes a SOCKS5 proxy
///   on 127.0.0.1:socksPort. All app networking should await readiness and
///   route via this proxy. Fails closed by default when Tor is unavailable.
@MainActor
public final class TorManager: ObservableObject {
    public static let shared = TorManager()

    // SOCKS endpoint where Arti listens
    let socksHost: String = "127.0.0.1"
    let socksPort: Int = 39050

    // State
    @Published private(set) public var isReady: Bool = false
    @Published private(set) var isStarting: Bool = false
    @Published private(set) var lastError: Error?
    @Published private(set) var bootstrapProgress: Int = 0
    @Published private(set) public var bootstrapSummary: String = ""
    @Published private(set) public var transportDiagnostic: String?
    @Published private(set) public var transportStatus: TorTransportStatus = .idle
    /// True once a bootstrap attempt has spent its whole deadline without
    /// completing.
    ///
    /// This separates "still starting" from "not getting through", which are
    /// indistinguishable from `isStarting` alone. The second is what a network
    /// that blocks Tor looks like from inside the app, and without it the UI
    /// says "starting tor…" indefinitely while nothing is happening. Cleared on
    /// each new start attempt.
    @Published private(set) public var bootstrapDidStall: Bool = false

    // Internal readiness trackers
    private var socksReady: Bool = false { didSet { recomputeReady() } }
    private var restarting: Bool = false
    private var routeConfiguration = TorRouteConfiguration()
    private var routeCandidates: [TorTransport] = []
    private var routeIndex = 0
    private var attemptedTransports: [TorTransport] = []
    private var hasConnectedTransportProxy = false
    private let pluggableTransportController: PluggableTransportControlling

    // Whether the app must enforce Tor for all connections (fail-closed).
    public var torEnforced: Bool {
        #if BITCHAT_DEV_ALLOW_CLEARNET
        return false
        #else
        return true
        #endif
    }

    // Returns true only when Tor is actually up (or dev fallback is compiled).
    var networkPermitted: Bool {
        if torEnforced { return isReady }
        return true
    }

    private var didStart = false
    // shutdownCompletely() resets `didStart` asynchronously (after Arti has
    // actually stopped). A startIfNeeded() arriving in that window must not be
    // dropped — it is recorded here and honored when the shutdown finishes.
    private var shutdownsInFlight = 0
    private var startPendingAfterShutdown = false
    private var bootstrapMonitorStarted = false
    // Fences the detached poll loop: shutdown, dormancy, and restart each bump
    // this, so a loop from a previous attempt cannot run out its deadline and
    // report a stall over state that a newer lifecycle event already owns.
    private var bootstrapGeneration = 0
    private var pathMonitor: NWPathMonitor?
    private var isAppForeground: Bool = true
    private var lastRestartAt: Date? = nil
    private var startedAt: Date? = nil  // Tracks initial startup time for grace period
    private(set) var allowAutoStart: Bool = false

    private init() {
        let controller = IPtProxyTransportController()
        pluggableTransportController = controller
        controller.eventHandler = { [weak self] event in
            self?.handlePluggableTransportEvent(event)
        }
        enableArtiDiagnosticsInDebugBuilds()
    }

    /// Arti's own log output is otherwise discarded, which makes a bootstrap
    /// that hangs indistinguishable from one that never started. Debug builds
    /// only: the bridge is compiled into the library but stays off unless it
    /// is switched on here, so release builds never emit it.
    private func enableArtiDiagnosticsInDebugBuilds() {
        #if os(iOS) && DEBUG
        _ = arti_set_diagnostics_enabled(1)
        #endif
    }

    /// Drain the sanitized lines Arti produced since the last tick.
    ///
    /// Rust keeps only each event's target, level, and leading plain words, so
    /// no bridge line, relay identity, or peer address reaches the log.
    private func drainArtiDiagnostics() {
        #if os(iOS) && DEBUG
        var buf = [CChar](repeating: 0, count: 256)
        // Bounded so a chatty second cannot monopolize the poll loop.
        for _ in 0..<64 {
            guard arti_next_diagnostic(&buf, Int32(buf.count)) > 0 else { return }
            SecureLogger.debug("Arti: \(String(cString: buf))", category: .session)
        }
        #endif
    }

    // MARK: - Public API

    public func configureTransport(_ configuration: TorRouteConfiguration) {
        guard configuration != routeConfiguration else { return }
        routeConfiguration = configuration
        routeCandidates.removeAll()
        routeIndex = 0
        attemptedTransports.removeAll()

        guard didStart || isStarting || isReady else {
            transportStatus = .idle
            return
        }

        // A transport change is a full Tor boundary: old circuits and relay
        // sockets must not survive onto a newly selected route.
        startPendingAfterShutdown = allowAutoStart && isAppForeground
        shutdownCompletely(preserveRouteRestart: true)
    }

    public func resetTransportForPanic() {
        routeConfiguration = TorRouteConfiguration()
        routeCandidates.removeAll()
        routeIndex = 0
        attemptedTransports.removeAll()
        transportStatus = .idle
        pluggableTransportController.stop()
        // Arti's own directories go too, not just IPtProxy's. A bridged route
        // caches the bridge descriptors it fetched keyed by the bridge line
        // that produced them, so leaving those behind left the user's private
        // obfs4 bridges recoverable from disk after a wipe meant to remove
        // them. Removing the parent covers direct Tor's guard state as well,
        // which is its own linkable record of who this device is.
        //
        // Arti is asked to stop first so it is not writing the files back out
        // as they go. A shutdown already in flight owns the stop, so this
        // narrows that window rather than closing it.
        _ = arti_stop()
        for directory in [dataDirectoryURL(), pluggableTransportStateDirectoryURL()] {
            guard let directory else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    public func retryTransportSequence() {
        guard allowAutoStart, isAppForeground else { return }
        routeCandidates.removeAll()
        routeIndex = 0
        attemptedTransports.removeAll()
        if didStart || arti_is_running() != 0 {
            startPendingAfterShutdown = true
            shutdownCompletely(preserveRouteRestart: true)
        } else {
            transportStatus = .idle
            startIfNeeded()
        }
    }

    public func startIfNeeded() {
        guard allowAutoStart else { return }
        guard isAppForeground else { return }
        if shutdownsInFlight > 0 {
            SecureLogger.debug("TorManager: startIfNeeded() deferred - shutdown in flight", category: .session)
            startPendingAfterShutdown = true
            return
        }
        guard !didStart else { return }
        if routeCandidates.isEmpty {
            routeCandidates = TorRoutePlanner.candidates(for: routeConfiguration)
            routeIndex = 0
            attemptedTransports.removeAll()
        }
        guard routeCandidates.indices.contains(routeIndex) else {
            isStarting = false
            transportStatus = TorTransportStatus(
                transport: nil,
                lifecycle: .failed,
                attempted: attemptedTransports
            )
            return
        }
        didStart = true
        isStarting = true
        bootstrapDidStall = false
        transportDiagnostic = nil
        hasConnectedTransportProxy = false
        let transport = routeCandidates[routeIndex]
        transportStatus = TorTransportStatus(
            transport: transport,
            lifecycle: .starting,
            attempted: attemptedTransports
        )
        startedAt = Date()  // Track startup time for grace period
        SecureLogger.debug("TorManager: startIfNeeded() - startedAt set", category: .session)
        lastError = nil
        NotificationCenter.default.post(name: .TorWillStart, object: nil)
        ensureFilesystemLayout()
        startArti()
        startPathMonitorIfNeeded()
    }

    public func setAppForeground(_ foreground: Bool) {
        isAppForeground = foreground
    }

    public func isForeground() -> Bool { isAppForeground }

    nonisolated
    // The default covers one complete Auto sequence plus the bounded
    // stop/start transitions between its routes, and is derived from the same
    // ceilings the manager enforces so the two cannot drift apart. Callers
    // remain fail-closed while the manager changes transports, so expiring
    // early buys nothing and abandons a bootstrap that is still working.
    public func awaitReady(timeout: TimeInterval = TorTransport.fullSequenceDeadline) async -> Bool {
        await MainActor.run {
            if self.isAppForeground { self.startIfNeeded() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        if await MainActor.run(body: { self.networkPermitted }) { return true }
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if await MainActor.run(body: { self.networkPermitted }) { return true }
        }
        return await MainActor.run(body: { self.networkPermitted })
    }

    // MARK: - Filesystem

    func dataDirectoryURL(for transport: TorTransport? = nil) -> URL? {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = base.appendingPathComponent("bitchat/arti", isDirectory: true)
            switch transport {
            case .obfs4:
                return dir.appendingPathComponent("obfs4", isDirectory: true)
            case .snowflake:
                return dir.appendingPathComponent("snowflake", isDirectory: true)
            case .direct, .none:
                return dir
            }
        } catch {
            return nil
        }
    }

    func pluggableTransportStateDirectoryURL() -> URL? {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return base.appendingPathComponent("bitchat/pt_state", isDirectory: true)
        } catch {
            return nil
        }
    }

    private func ensureFilesystemLayout() {
        guard let dir = dataDirectoryURL() else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            // Non-fatal; Arti will surface errors during start if paths are missing
        }
    }

    // MARK: - Arti Integration

    private func startArti() {
        guard routeCandidates.indices.contains(routeIndex) else {
            failCurrentTransport(
                NSError(domain: "TorManager", code: -15, userInfo: [NSLocalizedDescriptionKey: "No transport available"]),
                stalled: false
            )
            return
        }
        let transport = routeCandidates[routeIndex]
        guard let dir = dataDirectoryURL(for: transport)?.path else {
            failCurrentTransport(
                NSError(domain: "TorManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data directory"]),
                stalled: false
            )
            return
        }

        // Check if already running
        if arti_is_running() != 0 {
            SecureLogger.info("TorManager: Arti already running", category: .session)
            beginBootstrapObservation(for: transport)
            return
        }

        let result: Int32
        switch transport {
        case .direct:
            pluggableTransportController.stop()
            result = dir.withCString { dptr in
                arti_start(dptr, UInt16(socksPort))
            }

        case .obfs4, .snowflake:
            #if os(iOS)
            guard let ptDirectory = pluggableTransportStateDirectoryURL() else {
                failCurrentTransport(PluggableTransportError.stateDirectory, stalled: false)
                return
            }
            do {
                let ptAddress = try pluggableTransportController.start(
                    transport,
                    stateDirectory: ptDirectory
                )
                transportDiagnostic = transport == .snowflake
                    ? "snowflake listener ready; configuring tor handoff"
                    : "obfs4 listener ready; configuring tor handoff"
                SecureLogger.info(
                    "TorManager: \(transport.rawValue) listener started",
                    category: .session
                )
                let bridgeLines = transport == .obfs4
                    ? routeConfiguration.obfs4BridgeLines
                    : SnowflakeDefaults.bridgeLines
                let configuration = ArtiTransportConfiguration(
                    transport: transport,
                    bridgeLines: bridgeLines,
                    ptSocksAddress: ptAddress
                )
                let encoded = try JSONEncoder().encode(configuration)
                guard let json = String(data: encoded, encoding: .utf8) else {
                    throw PluggableTransportError.start
                }
                result = dir.withCString { dptr in
                    json.withCString { configPointer in
                        guard arti_validate_transport_config(configPointer) == 0 else {
                            return -5
                        }
                        return arti_start_with_config(
                            dptr,
                            UInt16(socksPort),
                            configPointer
                        )
                    }
                }
            } catch {
                pluggableTransportController.stop()
                failCurrentTransport(error, stalled: false)
                return
            }
            #else
            failCurrentTransport(PluggableTransportError.unavailable, stalled: false)
            return
            #endif
        }

        if result != 0 {
            SecureLogger.error("TorManager: arti_start failed rc=\(result)", category: .session)
            pluggableTransportController.stop()
            failCurrentTransport(
                NSError(domain: "TorManager", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Arti start failed"]),
                stalled: false
            )
            return
        }

        SecureLogger.info(
            "TorManager: Arti task launched; waiting for SOCKS \(socksHost):\(socksPort)",
            category: .session
        )
        beginBootstrapObservation(for: transport)
    }

    /// Watch the attempt that was just launched.
    ///
    /// Both halves belong together: the poll loop reports progress and decides
    /// whether a route is blocked, and the probe decides when the SOCKS
    /// listener is actually carrying traffic. Starting the monitor without the
    /// probe leaves readiness with no writer at all.
    private func beginBootstrapObservation(for transport: TorTransport) {
        startBootstrapMonitor()

        // Start SOCKS readiness probe
        let generation = bootstrapGeneration
        // Deliberately past the poll loop's ceiling so that loop is the one
        // that reports the outcome: it can tell a route that stopped advancing
        // from one that is merely slow, and a bare probe timeout cannot.
        let probeTimeout = transport.bootstrapDeadline + 5
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ready = await self.waitForSocksReady(
                timeout: probeTimeout,
                generation: generation
            )
            await MainActor.run {
                guard generation == self.bootstrapGeneration else { return }
                self.socksReady = ready
                if ready {
                    SecureLogger.info("TorManager: SOCKS ready at \(self.socksHost):\(self.socksPort)", category: .session)
                } else {
                    SecureLogger.error("TorManager: SOCKS not reachable (timeout)", category: .session)
                    if self.transportDiagnostic == nil {
                        self.transportDiagnostic = "tor did not become ready before the timeout"
                    }
                    self.failCurrentTransport(
                        NSError(
                            domain: "TorManager",
                            code: -14,
                            userInfo: [NSLocalizedDescriptionKey: "SOCKS not reachable"]
                        ),
                        stalled: true
                    )
                }
            }
        }
    }

    private func waitForSocksReady(
        timeout: TimeInterval,
        generation: Int
    ) async -> Bool {
        // Arti binds the listener only once bootstrap has returned, so every
        // probe before that is a guaranteed refusal. Skipping them removes a
        // rejected loopback connection every couple of seconds for the whole
        // bootstrap and leaves room to poll four times as often once the
        // listener can exist, which is what turns readiness around in half a
        // second rather than up to three.
        let pollInterval: TimeInterval = 0.5
        var remainingForegroundTime = timeout
        while remainingForegroundTime > 0 {
            let state = await MainActor.run {
                (
                    isCurrent: generation == self.bootstrapGeneration,
                    isForeground: self.isAppForeground
                )
            }
            guard state.isCurrent, !Task.isCancelled else { return false }
            if !state.isForeground {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return false
                }
                continue
            }
            if arti_bootstrap_progress() >= 100, await probeSocksOnce() { return true }
            remainingForegroundTime -= pollInterval
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(pollInterval * 1_000_000_000)
                )
            } catch {
                return false
            }
        }
        return false
    }

    private func probeSocksOnce() async -> Bool {
        #if canImport(Network)
        await withCheckedContinuation { cont in
            let params = NWParameters.tcp
            let host = NWEndpoint.Host.ipv4(.loopback)
            guard let port = NWEndpoint.Port(rawValue: UInt16(socksPort)) else {
                cont.resume(returning: false)
                return
            }
            let endpoint = NWEndpoint.hostPort(host: host, port: port)
            let conn = NWConnection(to: endpoint, using: params)

            let gate = ProbeContinuationGate(cont)
            let resumeOnce: (Bool) -> Void = { gate.resume($0) }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(true)
                    conn.cancel()
                case .failed, .cancelled:
                    resumeOnce(false)
                    conn.cancel()
                default:
                    break
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                resumeOnce(false)
                conn.cancel()
            }

            conn.start(queue: DispatchQueue.global(qos: .utility))
        }
        #else
        return false
        #endif
    }

    // MARK: - Bootstrap Monitoring

    private func startBootstrapMonitor() {
        guard !bootstrapMonitorStarted else { return }
        bootstrapMonitorStarted = true
        bootstrapGeneration += 1
        let generation = bootstrapGeneration
        Task.detached(priority: .utility) { [weak self] in
            await self?.bootstrapPollLoop(generation: generation)
        }
    }

    private func bootstrapPollLoop(generation: Int) async {
        let activeRoute = routeCandidates.indices.contains(routeIndex)
            ? routeCandidates[routeIndex]
            : .direct
        let timeout = activeRoute.bootstrapDeadline
        let stallWindow = activeRoute.bootstrapStallWindow
        var remainingForegroundSeconds = Int(timeout.rounded(.up))
        var didComplete = false
        // A bootstrap that is still advancing is not a stall. Snowflake pulls
        // the directory over a lossy WebRTC hop and can take minutes on a cold
        // cache, so the ceiling above only bounds the wait; giving up early is
        // driven by progress standing still.
        var secondsSinceProgress = 0
        var highWaterProgress = -1
        var stoppedAdvancing = false
        while true {
            guard generation == bootstrapGeneration else { return }
            if !isAppForeground {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            drainArtiDiagnostics()
            let summary = getBootstrapSummary()
            if arti_is_running() == 0 {
                self.bootstrapSummary = summary
                let diagnostic = sanitizedBootstrapDiagnostic(summary)
                self.transportDiagnostic = diagnostic
                SecureLogger.error(
                    "TorManager: Arti stopped during bootstrap (\(diagnostic))",
                    category: .session
                )
                failCurrentTransport(
                    NSError(
                        domain: "TorManager",
                        code: -16,
                        userInfo: [NSLocalizedDescriptionKey: diagnostic]
                    ),
                    stalled: false
                )
                return
            }
            let progress = Int(arti_bootstrap_progress())
            let summaryChanged = self.bootstrapSummary != summary

            self.bootstrapProgress = progress
            self.bootstrapSummary = summary
            if summaryChanged,
               let diagnostic = transportStageDiagnostic(summary) {
                self.transportDiagnostic = diagnostic
                SecureLogger.info(
                    "TorManager: \(diagnostic)",
                    category: .session
                )
            }
            if progress >= 100 { self.isStarting = false }
            self.recomputeReady()

            // A route that is already carrying traffic is finished, whatever
            // the reported percentage says. Without this, any failure to
            // observe completion tears down a working Tor, which is a far
            // worse outcome than a stall that goes unreported. Reading Arti's
            // counter first is what makes this exit publish a completed
            // bootstrap instead of leaving the last stale percentage behind,
            // which held the app fail-closed over a live SOCKS listener.
            if socksReady {
                didComplete = true
                break
            }

            switch TorBootstrapWaitPolicy.outcome(
                progress: progress,
                highWaterProgress: highWaterProgress,
                secondsSinceProgress: secondsSinceProgress,
                remainingSeconds: remainingForegroundSeconds,
                stallWindow: stallWindow
            ) {
            case .ready:
                didComplete = true
            case .stalled:
                stoppedAdvancing = true
            case .ceilingReached:
                break
            case .keepWaiting:
                if progress > highWaterProgress {
                    highWaterProgress = progress
                    secondsSinceProgress = 0
                } else {
                    secondsSinceProgress += 1
                }
                remainingForegroundSeconds -= 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            break
        }

        // Running out the deadline is a reportable outcome, not silence. The
        // loop previously just ended, leaving `isStarting` true forever, so a
        // blocked network was indistinguishable from a slow one. A deliberate
        // shutdown mid-bootstrap is not a stall, hence the generation check.
        if !didComplete {
            guard generation == bootstrapGeneration else { return }
            // The last second before the deadline is the most informative one.
            drainArtiDiagnostics()
            // Naming which of the two happened matters: a bootstrap killed at
            // the ceiling while still climbing is a slow route, not a blocked
            // one, and saying "network may be blocking Tor" for it sends the
            // reader after the wrong problem.
            SecureLogger.warning(
                stoppedAdvancing
                    ? "TorManager: bootstrap stopped advancing at \(self.bootstrapProgress)% for \(stallWindow)s; network may be blocking Tor"
                    : "TorManager: bootstrap reached its \(Int(timeout))s ceiling while still advancing (progress=\(self.bootstrapProgress)%)",
                category: .session
            )
            if transportDiagnostic == nil {
                transportDiagnostic = "tor did not become ready before the timeout"
            }
            failCurrentTransport(
                NSError(
                    domain: "TorManager",
                    code: -17,
                    userInfo: [NSLocalizedDescriptionKey: "Tor bootstrap stalled"]
                ),
                stalled: true
            )
        }
    }

    private func getBootstrapSummary() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let len = arti_bootstrap_summary(&buf, Int32(buf.count))
        if len > 0 {
            return String(cString: buf)
        }
        return ""
    }

    private func sanitizedBootstrapDiagnostic(_ summary: String) -> String {
        switch summary {
        case "Error: Tor configuration failed":
            return "tor configuration failed"
        case "Error: local SOCKS listener failed":
            return "the local tor proxy could not start"
        case "Error: Tor bootstrap failed":
            return "tor bootstrap failed"
        default:
            return "tor stopped before becoming ready"
        }
    }

    private func transportStageDiagnostic(_ summary: String) -> String? {
        guard routeCandidates.indices.contains(routeIndex) else { return nil }
        let transport = routeCandidates[routeIndex]
        guard transport != .direct else { return nil }

        switch summary {
        case "Transport proxy configured":
            return "tor handoff to \(transport.rawValue) configured; waiting for proxy connection"
        case "Tor opened transport proxy":
            return "tor opened \(transport.rawValue); connecting to its local listener"
        case "Connected to transport listener":
            return "\(transport.rawValue) received tor's bridge request; finding a proxy"
        default:
            return nil
        }
    }

    private func handlePluggableTransportEvent(_ event: PluggableTransportEvent) {
        let transport: TorTransport
        switch event {
        case .connected(let value),
             .recoverableFailure(let value),
             .stopped(let value):
            transport = value
        }
        let activeTransport = routeCandidates.indices.contains(routeIndex)
            ? routeCandidates[routeIndex]
            : nil

        switch TorTransportEventPolicy.outcome(
            for: event,
            activeTransport: activeTransport,
            isStarting: isStarting,
            isReady: isReady,
            hasConnectedProxy: hasConnectedTransportProxy,
            artiIsRunning: arti_is_running() != 0
        ) {
        case .ignore:
            return
        case .proxyConnected:
            hasConnectedTransportProxy = true
            transportDiagnostic = "\(transport.rawValue) proxy connected; bootstrapping tor"
            SecureLogger.info(
                "TorManager: \(transport.rawValue) proxy connected",
                category: .session
            )
        case .proxyRetrying:
            let diagnostic = "\(transport.rawValue) could not connect to a proxy; retrying"
            guard transportDiagnostic != diagnostic else { return }
            transportDiagnostic = diagnostic
            SecureLogger.warning(
                "TorManager: \(transport.rawValue) proxy discovery failed; retrying",
                category: .session
            )
        case .ignoreStopWhileArtiOwnsRoute:
            // IPtProxy delivers transport callbacks on its own thread. A
            // delayed stop from the previous use of the process-wide
            // controller is indistinguishable from a stop for a new use of the
            // same method. Arti remains the lifecycle authority: if the active
            // transport really stopped, its task exits or its bounded
            // bootstrap deadline expires.
            SecureLogger.debug(
                "TorManager: ignored \(transport.rawValue) stop callback while Arti owns the active route",
                category: .session
            )
        case .routeStopped:
            let diagnostic = "\(transport.rawValue) stopped unexpectedly"
            transportDiagnostic = diagnostic
            SecureLogger.error(
                "TorManager: \(transport.rawValue) stopped unexpectedly",
                category: .session
            )
            failCurrentTransport(
                NSError(
                    domain: "TorManager",
                    code: -18,
                    userInfo: [NSLocalizedDescriptionKey: diagnostic]
                ),
                stalled: false
            )
        }
    }

    private func failCurrentTransport(_ error: Error, stalled: Bool) {
        guard routeCandidates.indices.contains(routeIndex) else {
            isStarting = false
            lastError = error
            transportStatus = TorTransportStatus(
                transport: nil,
                lifecycle: .failed,
                attempted: attemptedTransports
            )
            return
        }

        let failedTransport = routeCandidates[routeIndex]
        if attemptedTransports.last != failedTransport {
            attemptedTransports.append(failedTransport)
        }
        lastError = error
        bootstrapDidStall = stalled

        let canAdvance = routeConfiguration.mode == .auto
            && routeCandidates.indices.contains(routeIndex + 1)
        if canAdvance {
            routeIndex += 1
            let next = routeCandidates[routeIndex]
            transportStatus = TorTransportStatus(
                transport: next,
                lifecycle: .starting,
                attempted: attemptedTransports
            )
            startPendingAfterShutdown = true
            shutdownCompletely(preserveRouteRestart: true)
            return
        }

        isStarting = false
        transportStatus = TorTransportStatus(
            transport: failedTransport,
            lifecycle: stalled ? .stalled : .failed,
            attempted: attemptedTransports
        )
        startPendingAfterShutdown = false
        if stalled {
            NotificationCenter.default.post(name: .TorBootstrapDidStall, object: nil)
        }
        shutdownCompletely(preserveRouteRestart: true)
    }

    // MARK: - Foreground/Background

    public func ensureRunningOnForeground() {
        let action = TorLifecyclePolicy.foregroundRecoveryAction(
            autoStartAllowed: allowAutoStart,
            isForeground: isAppForeground,
            isReady: isReady,
            isRestarting: restarting,
            shutdownInFlight: shutdownsInFlight > 0,
            artiIsRunning: arti_is_running() != 0
        )
        switch action {
        case .none:
            return
        case .continueCurrentAttempt:
            SecureLogger.debug(
                "TorManager: foreground resumed existing Arti attempt",
                category: .session
            )
        case .deferUntilShutdownCompletes:
            startPendingAfterShutdown = true
            SecureLogger.debug(
                "TorManager: foreground start deferred until shutdown completes",
                category: .session
            )
        case .restart:
            SecureLogger.debug(
                "TorManager: foreground found no active Arti attempt; restarting",
                category: .session
            )
            restarting = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.restartArti()
                self.restarting = false
            }
        }
    }

    public func goDormantOnBackground() {
        // iOS suspends the in-process Arti and IPtProxy runtimes together. Keep
        // their shared attempt intact so a quick app switch cannot stop only
        // the pluggable transport and strand Arti in bootstrap.
        SecureLogger.debug(
            "TorManager: backgrounded; preserving active Tor attempt",
            category: .session
        )
    }

    public func shutdownCompletely() {
        shutdownCompletely(preserveRouteRestart: false)
    }

    private func shutdownCompletely(preserveRouteRestart: Bool) {
        SecureLogger.debug("TorManager: shutdownCompletely() called", category: .session)
        if !preserveRouteRestart {
            startPendingAfterShutdown = false
            routeCandidates.removeAll()
            routeIndex = 0
            attemptedTransports.removeAll()
            transportStatus = .idle
            transportDiagnostic = nil
        }
        bootstrapGeneration += 1
        if shutdownsInFlight > 0 {
            SecureLogger.debug(
                "TorManager: shutdown already in flight; coalescing request",
                category: .session
            )
            return
        }
        shutdownsInFlight += 1
        Task.detached { [weak self] in
            guard let self = self else { return }
            _ = arti_stop()
            await MainActor.run {
                self.pluggableTransportController.stop()
            }

            await MainActor.run {
                self.isReady = false
                self.socksReady = false
                self.bootstrapProgress = 0
                self.bootstrapSummary = ""
                self.isStarting = false
                self.hasConnectedTransportProxy = false
                self.didStart = false
                self.restarting = false
                self.bootstrapMonitorStarted = false
                if !preserveRouteRestart {
                    self.transportStatus = .idle
                }
                // Note: Don't clear startedAt here - it will be set fresh on next startIfNeeded()
                // Clearing it here races with startup and defeats the grace period
                self.shutdownsInFlight -= 1
                if self.shutdownsInFlight == 0 && self.startPendingAfterShutdown {
                    self.startPendingAfterShutdown = false
                    SecureLogger.debug("TorManager: honoring start deferred during shutdown", category: .session)
                    self.startIfNeeded()
                }
            }
        }
    }

    private func restartArti() async {
        SecureLogger.debug("TorManager: restartArti() starting", category: .session)
        await MainActor.run {
            NotificationCenter.default.post(name: .TorWillRestart, object: nil)
            self.bootstrapGeneration += 1
            self.isReady = false
            self.socksReady = false
            self.bootstrapProgress = 0
            self.bootstrapSummary = ""
            self.isStarting = true
            self.bootstrapDidStall = false
            self.hasConnectedTransportProxy = false
            self.lastRestartAt = Date()
        }

        _ = await Task.detached(priority: .userInitiated) {
            arti_stop()
        }.value
        await MainActor.run {
            self.pluggableTransportController.stop()
        }

        await MainActor.run {
            self.bootstrapMonitorStarted = false
            self.didStart = false
        }

        await MainActor.run { self.startIfNeeded() }
    }

    private func recomputeReady() {
        let resolved = TorReadinessPolicy.resolve(
            socksReady: socksReady,
            publishedProgress: bootstrapProgress,
            liveProgress: { Int(arti_bootstrap_progress()) }
        )
        if bootstrapProgress != resolved.progress {
            bootstrapProgress = resolved.progress
        }
        let ready = resolved.isReady
        if ready != isReady {
            if !ready {
                SecureLogger.debug("TorManager: isReady -> false (socksReady=\(socksReady), bootstrap=\(bootstrapProgress))", category: .session)
            }
            isReady = ready
            if ready {
                transportDiagnostic = nil
                if routeCandidates.indices.contains(routeIndex) {
                    let transport = routeCandidates[routeIndex]
                    routeConfiguration.lastSuccessfulTransport = transport
                    UserDefaults.standard.set(
                        transport.rawValue,
                        forKey: TorTransportStorageKeys.lastSuccessfulTransport
                    )
                    transportStatus = TorTransportStatus(
                        transport: transport,
                        lifecycle: .ready,
                        attempted: attemptedTransports
                    )
                }
                NotificationCenter.default.post(name: .TorDidBecomeReady, object: nil)
            }
        }
    }

    private func startPathMonitorIfNeeded() {
        #if canImport(Network)
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let queue = DispatchQueue(label: "TorPathMonitor")
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.isAppForeground {
                    self.pokeTorOnPathChange()
                }
            }
        }
        monitor.start(queue: queue)
        #endif
    }

    private func pokeTorOnPathChange() {
        // Skip if we recently restarted
        if let last = lastRestartAt, Date().timeIntervalSince(last) < 3.0 {
            SecureLogger.debug("TorManager: pokeTorOnPathChange() skipped - recent restart", category: .session)
            return
        }
        // Skip during initial startup grace period (15s) to avoid race conditions
        if let started = startedAt, Date().timeIntervalSince(started) < 15.0 {
            SecureLogger.debug("TorManager: pokeTorOnPathChange() skipped - startup grace period (\(Int(Date().timeIntervalSince(started)))s)", category: .session)
            return
        }
        if isStarting || restarting {
            SecureLogger.debug("TorManager: pokeTorOnPathChange() skipped - isStarting=\(isStarting) restarting=\(restarting)", category: .session)
            return
        }
        if isReady { return }
        if transportStatus.lifecycle == .failed || transportStatus.lifecycle == .stalled {
            routeCandidates.removeAll()
            routeIndex = 0
            attemptedTransports.removeAll()
        }
        SecureLogger.debug("TorManager: pokeTorOnPathChange() - Arti not ready, initiating recovery", category: .session)
        ensureRunningOnForeground()
    }
}

// MARK: - Start policy configuration
extension TorManager {
    @MainActor
    public func setAutoStartAllowed(_ allow: Bool) {
        allowAutoStart = allow
    }

    @MainActor
    public func isAutoStartAllowed() -> Bool { allowAutoStart }
}
