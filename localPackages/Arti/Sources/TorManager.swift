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

@_silgen_name("arti_go_dormant")
private func arti_go_dormant() -> Int32

@_silgen_name("arti_wake")
private func arti_wake() -> Int32

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
    private var bootstrapMonitorStarted = false
    private var pathMonitor: NWPathMonitor?
    private var isAppForeground: Bool = true
    private var isDormant: Bool = false
    private var lastRestartAt: Date? = nil
    private var startedAt: Date? = nil  // Tracks initial startup time for grace period
    private(set) var allowAutoStart: Bool = false

    private init() {}

    // MARK: - Public API

    public func startIfNeeded() {
        guard allowAutoStart else { return }
        guard isAppForeground else { return }
        guard !didStart else { return }
        didStart = true
        isDormant = false
        isStarting = true
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
    public func awaitReady(timeout: TimeInterval = 25.0) async -> Bool {
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

    func dataDirectoryURL() -> URL? {
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
        guard let dir = dataDirectoryURL()?.path else {
            isStarting = false
            lastError = NSError(domain: "TorManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data directory"])
            return
        }

        // Check if already running
        if arti_is_running() != 0 {
            SecureLogger.info("TorManager: Arti already running", category: .session)
            startBootstrapMonitor()
            return
        }

        let result = dir.withCString { dptr in
            arti_start(dptr, UInt16(socksPort))
        }

        if result != 0 {
            SecureLogger.error("TorManager: arti_start failed rc=\(result)", category: .session)
            isStarting = false
            lastError = NSError(domain: "TorManager", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Arti start failed"])
            return
        }

        SecureLogger.info("TorManager: arti_start OK (SOCKS \(socksHost):\(socksPort))", category: .session)
        startBootstrapMonitor()

        // Start SOCKS readiness probe
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ready = await self.waitForSocksReady(timeout: 60.0)
            await MainActor.run {
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

    private func waitForSocksReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeSocksOnce() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
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

            var resumed = false
            let resumeOnce: (Bool) -> Void = { value in
                if !resumed {
                    resumed = true
                    cont.resume(returning: value)
                }
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
        return false
        #endif
    }

    // MARK: - Bootstrap Monitoring

    private func startBootstrapMonitor() {
        guard !bootstrapMonitorStarted else { return }
        bootstrapMonitorStarted = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.bootstrapPollLoop()
        }
    }

    private func bootstrapPollLoop() async {
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            let progress = Int(arti_bootstrap_progress())
            let summary = getBootstrapSummary()

            await MainActor.run {
                self.bootstrapProgress = progress
                self.bootstrapSummary = summary
                if progress >= 100 { self.isStarting = false }
                self.recomputeReady()
            }

            if progress >= 100 { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
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
        Task { @MainActor in
            self.isReady = false
            self.socksReady = false
            self.isStarting = false
        }
    }

    public func shutdownCompletely() {
        SecureLogger.debug("TorManager: shutdownCompletely() called", category: .session)
        Task.detached { [weak self] in
            guard let self = self else { return }
            _ = arti_stop()

            // Wait for shutdown
            var waited = 0
            while arti_is_running() != 0 && waited < 50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }

            await MainActor.run {
                self.isDormant = false
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
            }
        }
    }

    private func restartArti() async {
        SecureLogger.debug("TorManager: restartArti() starting", category: .session)
        await MainActor.run {
            NotificationCenter.default.post(name: .TorWillRestart, object: nil)
            self.isReady = false
            self.socksReady = false
            self.bootstrapProgress = 0
            self.bootstrapSummary = ""
            self.isStarting = true
            self.isDormant = false
            self.lastRestartAt = Date()
        }

        _ = arti_stop()

        // Wait for stop
        var waited = 0
        while arti_is_running() != 0 && waited < 40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        await MainActor.run {
            self.bootstrapMonitorStarted = false
            self.didStart = false
        }

        await MainActor.run { self.startIfNeeded() }
    }

    private func recomputeReady() {
        let ready = socksReady && bootstrapProgress >= 100
        if ready != isReady {
            if !ready {
                SecureLogger.debug("TorManager: isReady -> false (socksReady=\(socksReady), bootstrap=\(bootstrapProgress))", category: .session)
            }
            isReady = ready
            if ready {
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

// MARK: - Start policy configuration
extension TorManager {
    @MainActor
    public func setAutoStartAllowed(_ allow: Bool) {
        allowAutoStart = allow
    }

    @MainActor
    public func isAutoStartAllowed() -> Bool { allowAutoStart }
}
