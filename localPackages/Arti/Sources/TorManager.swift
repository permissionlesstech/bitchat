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

@_silgen_name("arti_stop")
private func arti_stop() -> Int32

@_silgen_name("arti_is_running")
private func arti_is_running() -> Int32

@_silgen_name("arti_bootstrap_progress")
private func arti_bootstrap_progress() -> Int32

@_silgen_name("arti_bootstrap_summary")
private func arti_bootstrap_summary(_ buf: UnsafeMutablePointer<CChar>, _ len: Int32) -> Int32

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
    @Published private(set) var bootstrapSummary: String = ""
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
    private var wipeDataDirectoryOnShutdown = false
    private var bootstrapMonitorStarted = false
    // Fences detached lifecycle tasks (start, bootstrap poll, SOCKS probe):
    // shutdown, dormancy, and restart each bump this, so work from a previous
    // attempt cannot overwrite state owned by a newer lifecycle event.
    private var bootstrapGeneration = 0
    private var pathMonitor: NWPathMonitor?
    private var isAppForeground: Bool = true
    private var lastRestartAt: Date? = nil
    private var startedAt: Date? = nil  // Tracks initial startup time for grace period
    private(set) var allowAutoStart: Bool = false

    private let artiExecutor = ArtiLifecycleExecutor()

    private struct ReadyWaiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }
    private var readyWaiters: [UUID: ReadyWaiter] = [:]

    private init() {}

    // MARK: - Public API

    public func startIfNeeded() {
        guard allowAutoStart else { return }
        guard isAppForeground else { return }
        if shutdownsInFlight > 0 {
            SecureLogger.debug("TorManager: startIfNeeded() deferred - shutdown in flight", category: .session)
            startPendingAfterShutdown = true
            return
        }
        guard !didStart else { return }
        didStart = true
        isStarting = true
        bootstrapDidStall = false
        startedAt = Date()  // Track startup time for grace period
        SecureLogger.debug("TorManager: startIfNeeded() - startedAt set", category: .session)
        lastError = nil
        NotificationCenter.default.post(name: .TorWillStart, object: nil)
        bootstrapGeneration += 1
        let generation = bootstrapGeneration
        startArti(generation: generation)
        startPathMonitorIfNeeded()
    }

    public func setAppForeground(_ foreground: Bool) {
        isAppForeground = foreground
    }

    public func isForeground() -> Bool { isAppForeground }

    nonisolated
    // Default matches the bootstrap monitor deadline (75s); a shorter wait here
    // reports "not ready" while Arti is still legitimately bootstrapping.
    public func awaitReady(timeout: TimeInterval = 75.0) async -> Bool {
        let alreadyPermitted: Bool = await MainActor.run {
            if self.isAppForeground { self.startIfNeeded() }
            return self.networkPermitted
        }
        if alreadyPermitted { return true }
        guard timeout > 0 else { return false }

        let waiterID = UUID()
        let cancellationFlag = AtomicOnceFlag()
        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }
                    if cancellationFlag.isSet {
                        continuation.resume(returning: false)
                        return
                    }
                    if self.networkPermitted {
                        continuation.resume(returning: true)
                        return
                    }
                    let timeoutTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        guard !Task.isCancelled, let self else { return }
                        if let pending = self.readyWaiters.removeValue(forKey: waiterID) {
                            pending.continuation.resume(returning: self.networkPermitted)
                        }
                    }
                    self.readyWaiters[waiterID] = ReadyWaiter(
                        continuation: continuation,
                        timeoutTask: timeoutTask
                    )
                }
            }
        } onCancel: {
            _ = cancellationFlag.trySet()
            Task { @MainActor [weak self] in
                self?.cancelReadyWaiter(id: waiterID)
            }
        }
    }

    private func cancelReadyWaiter(id: UUID) {
        guard let pending = readyWaiters.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: false)
    }

    private func resumeAllReadyWaiters() {
        guard !readyWaiters.isEmpty else { return }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters.values {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    // MARK: - Filesystem

    nonisolated func dataDirectoryURL() -> URL? {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = base.appendingPathComponent("bitchat/arti", isDirectory: true)
            return dir
        } catch {
            return nil
        }
    }

    // MARK: - Arti Integration

    private func startArti(generation: Int) {
        guard let dirURL = dataDirectoryURL() else {
            isStarting = false
            lastError = NSError(domain: "TorManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data directory"])
            return
        }
        let host = socksHost
        let port = socksPort
        let executor = artiExecutor

        // Run directory creation and Arti FFI startup off the main actor on
        // the serialized lifecycle executor so launch/foreground recovery never
        // stalls UI rendering and cannot race shutdown or panic wipe.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let outcome = await executor.start(
                dirURL: dirURL,
                socksPort: UInt16(port),
                isStillCurrent: {
                    await MainActor.run {
                        self.bootstrapGeneration == generation
                    }
                }
            )

            switch outcome {
            case .superseded:
                return
            case .failed(let result):
                SecureLogger.error("TorManager: arti_start failed rc=\(result)", category: .session)
                await MainActor.run {
                    guard generation == self.bootstrapGeneration else { return }
                    self.isStarting = false
                    self.lastError = NSError(domain: "TorManager", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Arti start failed"])
                }
                return
            case .alreadyRunning:
                SecureLogger.info("TorManager: Arti already running", category: .session)
            case .started:
                SecureLogger.info("TorManager: arti_start OK (SOCKS \(host):\(port))", category: .session)
            }

            let stillCurrent: Bool = await MainActor.run {
                guard generation == self.bootstrapGeneration else { return false }
                self.startBootstrapMonitor(generation: generation)
                return true
            }
            guard stillCurrent else { return }

            // Probe SOCKS readiness off-main for BOTH newly started and
            // already-running Arti instances (fenced to this bootstrap
            // generation) so `socksReady` cannot remain stuck at `false`
            // after dormancy or an overlapping restart.
            let ready = await self.waitForSocksReady(port: port, timeout: 60.0)
            await MainActor.run {
                guard generation == self.bootstrapGeneration else { return }
                self.socksReady = ready
                if ready {
                    SecureLogger.info("TorManager: SOCKS ready at \(self.socksHost):\(self.socksPort)", category: .session)
                } else {
                    self.lastError = NSError(domain: "TorManager", code: -14, userInfo: [NSLocalizedDescriptionKey: "SOCKS not reachable"])
                    SecureLogger.error("TorManager: SOCKS not reachable (timeout)", category: .session)
                }
            }
        }
    }

    nonisolated private func waitForSocksReady(port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var attempts = 0
        while Date() < deadline {
            if arti_is_running() == 0 {
                return false
            }
            if await Self.probeSocksOnce(port: port) {
                return true
            }
            attempts += 1
            // Probe quickly for the first second, then ease to 1s intervals so
            // slow or blocked networks do not spam loopback sockets.
            let sleepNs: UInt64 = attempts < 4 ? 250_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: sleepNs)
        }
        return false
    }

    nonisolated private static func probeSocksOnce(port socksPort: Int) async -> Bool {
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

            let resumed = AtomicOnceFlag()
            let resumeOnce: @Sendable (Bool) -> Void = { value in
                guard resumed.trySet() else { return }
                cont.resume(returning: value)
            }

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
        _ = socksPort
        return false
        #endif
    }

    // MARK: - Bootstrap Monitoring

    private func startBootstrapMonitor(generation: Int) {
        guard !bootstrapMonitorStarted else { return }
        bootstrapMonitorStarted = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.bootstrapPollLoop(generation: generation)
        }
    }

    nonisolated private func bootstrapPollLoop(generation: Int) async {
        let deadline = Date().addingTimeInterval(75)
        var didComplete = false
        var lastPublishedProgress: Int?
        var lastPublishedSummary: String?

        while Date() < deadline {
            let progress = Int(arti_bootstrap_progress())
            let summary = Self.readBootstrapSummary()

            if progress != lastPublishedProgress || summary != lastPublishedSummary || progress >= 100 {
                lastPublishedProgress = progress
                lastPublishedSummary = summary
                let stillCurrent: Bool = await MainActor.run {
                    guard generation == self.bootstrapGeneration else { return false }
                    if self.bootstrapProgress != progress {
                        self.bootstrapProgress = progress
                    }
                    if self.bootstrapSummary != summary {
                        self.bootstrapSummary = summary
                    }
                    if progress >= 100, self.isStarting {
                        self.isStarting = false
                    }
                    self.recomputeReady()
                    return true
                }
                guard stillCurrent else { return }
            } else {
                let stillCurrent: Bool = await MainActor.run {
                    generation == self.bootstrapGeneration
                }
                guard stillCurrent else { return }
            }

            if progress >= 100 {
                didComplete = true
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Running out the deadline is a reportable outcome, not silence. The
        // loop previously just ended, leaving `isStarting` true forever, so a
        // blocked network was indistinguishable from a slow one. A deliberate
        // shutdown mid-bootstrap is not a stall, hence the generation check.
        if !didComplete {
            await MainActor.run {
                guard generation == self.bootstrapGeneration else { return }
                if self.isStarting { self.isStarting = false }
                if !self.bootstrapDidStall { self.bootstrapDidStall = true }
                SecureLogger.warning(
                    "TorManager: bootstrap did not complete within its deadline (progress=\(self.bootstrapProgress)); network may be blocking Tor",
                    category: .session
                )
                NotificationCenter.default.post(name: .TorBootstrapDidStall, object: nil)
            }
        }
    }

    nonisolated private static func readBootstrapSummary() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let len = arti_bootstrap_summary(&buf, Int32(buf.count))
        if len > 0 {
            return String(cString: buf)
        }
        return ""
    }

    // MARK: - Foreground/Background

    public func ensureRunningOnForeground() {
        if !allowAutoStart { return }
        SecureLogger.debug("TorManager: ensureRunningOnForeground() started", category: .session)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let claimed: Bool = await MainActor.run {
                if self.isStarting || self.restarting { return false }
                self.restarting = true
                return true
            }
            if !claimed { return }

            // Check if already ready
            let alreadyReady = await MainActor.run { self.isReady }
            if alreadyReady {
                await MainActor.run { self.restarting = false }
                return
            }

            // Arti doesn't support dormant/wake (it's a no-op stub), so always do full restart
            await self.restartArti()
            await MainActor.run { self.restarting = false }
        }
    }

    public func goDormantOnBackground() {
        // Arti doesn't support real dormant mode, so just mark as not ready.
        // iOS will suspend the runtime anyway. On foreground we do a full restart.
        // Clear isStarting so foreground recovery can proceed if bootstrap was interrupted.
        SecureLogger.debug("TorManager: goDormantOnBackground() called", category: .session)
        bootstrapGeneration += 1
        isReady = false
        socksReady = false
        isStarting = false
    }

    public func shutdownCompletely() {
        SecureLogger.debug("TorManager: shutdownCompletely() called", category: .session)
        startPendingAfterShutdown = false
        bootstrapGeneration += 1
        // Mark not-ready synchronously so no caller awaiting Tor readiness can
        // observe `networkPermitted == true` while Arti is tearing down.
        isReady = false
        socksReady = false
        bootstrapProgress = 0
        bootstrapSummary = ""
        isStarting = false
        shutdownsInFlight += 1
        let executor = artiExecutor
        Task.detached { [weak self] in
            guard let self = self else { return }
            await executor.stop(maxPolls: 50)

            await MainActor.run {
                self.isReady = false
                self.socksReady = false
                self.bootstrapProgress = 0
                self.bootstrapSummary = ""
                self.isStarting = false
                self.didStart = false
                self.restarting = false
                self.bootstrapMonitorStarted = false
                // Note: Don't clear startedAt here - it will be set fresh on next startIfNeeded()
                // Clearing it here races with startup and defeats the grace period
                self.shutdownsInFlight -= 1
                if self.shutdownsInFlight == 0 && self.wipeDataDirectoryOnShutdown {
                    self.wipeDataDirectoryOnShutdown = false
                    self.removeDataDirectoryOnDisk()
                }
                if self.shutdownsInFlight == 0 && self.startPendingAfterShutdown {
                    self.startPendingAfterShutdown = false
                    SecureLogger.debug("TorManager: honoring start deferred during shutdown", category: .session)
                    self.startIfNeeded()
                }
            }
        }
    }

    /// Panic-wipe hook: removes `Application Support/bitchat/arti` (guard
    /// nodes, state, consensus cache). If Arti is starting, running, or
    /// shutting down, defers removal until serialized `arti_stop()` finishes so
    /// SQLite/state files are deleted cleanly before any post-panic restart.
    public func wipeStateDirectoryForPanic() {
        if shutdownsInFlight > 0 || isStarting || didStart || arti_is_running() != 0 {
            wipeDataDirectoryOnShutdown = true
            if shutdownsInFlight == 0 {
                shutdownCompletely()
            }
            return
        }
        removeDataDirectoryOnDisk()
    }

    private func removeDataDirectoryOnDisk() {
        guard let dir = dataDirectoryURL() else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    nonisolated private func restartArti() async {
        SecureLogger.debug("TorManager: restartArti() starting", category: .session)
        let executor = await MainActor.run { () -> ArtiLifecycleExecutor in
            NotificationCenter.default.post(name: .TorWillRestart, object: nil)
            self.bootstrapGeneration += 1
            self.isReady = false
            self.socksReady = false
            self.bootstrapProgress = 0
            self.bootstrapSummary = ""
            self.isStarting = true
            self.bootstrapDidStall = false
            self.lastRestartAt = Date()
            return self.artiExecutor
        }

        await executor.stop(maxPolls: 40)

        await MainActor.run {
            self.bootstrapMonitorStarted = false
            self.didStart = false
            self.startIfNeeded()
        }
    }

    private func recomputeReady() {
        let ready = socksReady && bootstrapProgress >= 100
        if ready != isReady {
            if !ready {
                SecureLogger.debug("TorManager: isReady -> false (socksReady=\(socksReady), bootstrap=\(bootstrapProgress))", category: .session)
            }
            isReady = ready
            if ready {
                resumeAllReadyWaiters()
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
        SecureLogger.debug("TorManager: pokeTorOnPathChange() - Arti not ready, initiating recovery", category: .session)
        ensureRunningOnForeground()
    }
}

private actor ArtiLifecycleExecutor {
    enum StartOutcome: Sendable {
        case started
        case alreadyRunning
        case superseded
        case failed(Int32)
    }

    func start(
        dirURL: URL,
        socksPort: UInt16,
        isStillCurrent: @Sendable () async -> Bool
    ) async -> StartOutcome {
        guard await isStillCurrent() else {
            return .superseded
        }
        if arti_is_running() != 0 {
            return .alreadyRunning
        }
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let rc = dirURL.path.withCString { dptr in
            arti_start(dptr, socksPort)
        }
        return rc == 0 ? .started : .failed(rc)
    }

    func stop(maxPolls: Int) async {
        _ = arti_stop()
        var waited = 0
        while arti_is_running() != 0 && waited < maxPolls {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
    }
}

private final class AtomicOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !flag else { return false }
        flag = true
        return true
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
