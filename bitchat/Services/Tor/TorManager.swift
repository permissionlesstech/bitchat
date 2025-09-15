import BitLogger
import Foundation
import Network
import Darwin

// Declare C entrypoint for Tor when statically linked from an xcframework.
@_silgen_name("tor_main")
private func tor_main_c(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

// Preferred: tiny C glue that uses Tor's embedding API (tor_api.h)
@_silgen_name("tor_host_start")
private func tor_host_start(_ dataDir: UnsafePointer<CChar>, _ socksAddr: UnsafePointer<CChar>, _ controlAddr: UnsafePointer<CChar>, _ shutdownFast: Int32) -> Int32
@_silgen_name("tor_host_shutdown")
private func tor_host_shutdown() -> Int32
@_silgen_name("tor_host_restart")
private func tor_host_restart(_ dataDir: UnsafePointer<CChar>, _ socksAddr: UnsafePointer<CChar>, _ controlAddr: UnsafePointer<CChar>, _ shutdownFast: Int32) -> Int32
@_silgen_name("tor_host_is_running")
private func tor_host_is_running() -> Int32

/// Minimal Tor integration scaffold.
/// - Boots a local Tor client (once integrated) and exposes a SOCKS5 proxy
///   on 127.0.0.1:socksPort. All app networking should await readiness and
///   route via this proxy. Fails closed by default when Tor is unavailable.
/// - Drop-in ready: add your Tor framework and complete `startTor()`.
@MainActor
final class TorManager: ObservableObject {
    static let shared = TorManager()

    // SOCKS endpoint where the embedded Tor should listen.
    let socksHost: String = "127.0.0.1"
    let socksPort: Int = 39050

    // Optional ControlPort for debugging/diagnostics once Tor is integrated.
    let controlHost: String = "127.0.0.1"
    let controlPort: Int = 39051

    // State
    // True only when SOCKS is reachable AND bootstrap has reached 100%.
    @Published private(set) var isReady: Bool = false
    @Published private(set) var isStarting: Bool = false
    @Published private(set) var lastError: Error?
    @Published private(set) var bootstrapProgress: Int = 0
    @Published private(set) var bootstrapSummary: String = ""
    
    // Internal readiness trackers
    private var socksReady: Bool = false { didSet { recomputeReady() } }
    private var restarting: Bool = false

    // Whether the app must enforce Tor for all connections (fail-closed).
    // This is the default. For local development, you may compile with
    // `-DBITCHAT_DEV_ALLOW_CLEARNET` to temporarily allow direct network.
    var torEnforced: Bool {
        #if BITCHAT_DEV_ALLOW_CLEARNET
        return false
        #else
        return true
        #endif
    }

    // Returns true only when Tor is actually up (or dev fallback is compiled).
    var networkPermitted: Bool {
        if torEnforced { return isReady }
        // Dev bypass allows network even if Tor is not running
        return true
    }

    private var didStart = false
    private var controlMonitorStarted = false
    private var pathMonitor: NWPathMonitor?
    private var isAppForeground: Bool = true
    private var isDormant: Bool = false
    private var lastRestartAt: Date? = nil
    // Global policy gate: only allow Tor to start when true
    private(set) var allowAutoStart: Bool = false

    private init() {}

    // MARK: - Public API

    func startIfNeeded() {
        // Respect global start policy
        guard allowAutoStart else { return }
        // Do not start in background; caller should wait for foreground
        guard isAppForeground else { return }
        guard !didStart else { return }
        didStart = true
        isDormant = false
        isStarting = true
        lastError = nil
        // Announce initial start so UI can show a status message
        NotificationCenter.default.post(name: .TorWillStart, object: nil)
        ensureFilesystemLayout()
        startTor()
        startPathMonitorIfNeeded()
    }

    /// Called by app lifecycle to indicate foreground/background state.
    func setAppForeground(_ foreground: Bool) {
        isAppForeground = foreground
    }

    /// Foreground state accessor for other @MainActor clients.
    func isForeground() -> Bool { isAppForeground }

    /// Await Tor bootstrap to readiness. Returns true if network is permitted (Tor ready or dev bypass).
    /// Nonisolated to avoid blocking the main actor during waits.
    nonisolated func awaitReady(timeout: TimeInterval = 25.0) async -> Bool {
        // Only start Tor if we're in foreground; otherwise just wait for it
        await MainActor.run {
            if self.isAppForeground { self.startIfNeeded() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        // Early exit if network already permitted
        if await MainActor.run(body: { self.networkPermitted }) { return true }
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            if await MainActor.run(body: { self.networkPermitted }) { return true }
        }
        return await MainActor.run(body: { self.networkPermitted })
    }

    // MARK: - Filesystem (torrc + data dir)

    func dataDirectoryURL() -> URL? {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = base.appendingPathComponent("bitchat/tor", isDirectory: true)
            return dir
        } catch {
            return nil
        }
    }

    func torrcURL() -> URL? {
        dataDirectoryURL()?.appendingPathComponent("torrc")
    }

    private func ensureFilesystemLayout() {
        guard let dir = dataDirectoryURL() else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Always (re)write torrc at launch so DataDirectory is correct for this container
            if let torrc = torrcURL() {
                try torrcTemplate().data(using: .utf8)?.write(to: torrc, options: .atomic)
            }
        } catch {
            // Non-fatal; Tor will surface errors during start if paths are missing
        }
    }

    /// Minimal, safe torrc for an embedded client.
    func torrcTemplate() -> String {
        var lines: [String] = []
        if let dir = dataDirectoryURL()?.path {
            lines.append("DataDirectory \(dir)")
        }
        lines.append("ClientOnly 1")
        lines.append("SOCKSPort \(socksHost):\(socksPort)")
        lines.append("ControlPort \(controlHost):\(controlPort)")
        lines.append("CookieAuthentication 1")
        lines.append("AvoidDiskWrites 1")
        lines.append("MaxClientCircuitsPending 8")
        lines.append("ShutdownWaitLength 0")
        // Keep defaults for guard/exit selection to preserve anonymity properties
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Integration Hook

    /// Start the embedded Tor. This stub intentionally compiles without any Tor dependency.
    /// Integrate your Tor framework here and set `isReady = true` once bootstrapped.
    private func startTor() {
        // Prefer the embedding API wrapper which cleanly supports restart.
        // Avoid fallback to prevent accidental second instances in-process.
        if startTorViaEmbedAPI() { return }

        #if BITCHAT_DEV_ALLOW_CLEARNET
        // Dev bypass: permit network immediately (no Tor). Use ONLY for local development.
        self.isReady = true
        self.isStarting = false
        #else
        // Production default: fail closed until Tor framework is dropped in and bootstraps.
        self.isReady = false
        self.isStarting = false
        #endif
    }

    // MARK: - Embed API path (owning controller FD + clean restart)
    private func startTorViaEmbedAPI() -> Bool {
        guard let dir = dataDirectoryURL()?.path else { return false }
        let socks = "\(socksHost):\(socksPort)"
        let control = "\(controlHost):\(controlPort)"
        var started = false
        // If already running (per C glue), treat as started
        if tor_host_is_running() != 0 {
            SecureLogger.info("TorManager: embed reports already running", category: .session)
            return true
        }
        dir.withCString { dptr in
            socks.withCString { sptr in
                control.withCString { cptr in
                    let rc = tor_host_start(dptr, sptr, cptr, 1)
                    started = (rc == 0)
                    if rc != 0 {
                        SecureLogger.error("TorManager: tor_host_start failed rc=\(rc)", category: .session)
                    } else {
                        SecureLogger.info("TorManager: tor_host_start OK (\(socks), control \(control))", category: .session)
                    }
                }
            }
        }
        if !started { return false }

        // Start monitors and probe readiness
        startControlMonitorIfNeeded()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ready = await self.waitForSocksReady(timeout: 60.0)
            await MainActor.run {
                self.socksReady = ready
                if ready {
                    SecureLogger.info("TorManager: SOCKS ready at \(self.socksHost):\(self.socksPort) [embed]", category: .session)
                } else {
                    self.lastError = NSError(domain: "TorManager", code: -14, userInfo: [NSLocalizedDescriptionKey: "Tor SOCKS not reachable after embed start"])
                    SecureLogger.error("TorManager: SOCKS not reachable (timeout) [embed]", category: .session)
                }
            }
        }
        return true
    }
    /// Probe the local SOCKS port until it's ready or a timeout elapses.
    private func waitForSocksReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probeSocksOnce() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func probeSocksOnce() async -> Bool {
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

            // Failsafe timeout to avoid hanging if no callback occurs
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                resumeOnce(false)
                conn.cancel()
            }

            conn.start(queue: DispatchQueue.global(qos: .utility))
        }
    }

    // MARK: - Dynamic loader path (no Swift module required)

    /// Attempt to locate an embedded tor framework binary and launch Tor via `tor_run_main`.
    /// Returns true if the attempt started and port probing was scheduled.
    private func startTorViaDlopen() -> Bool {
        guard let fwURL = frameworkBinaryURL() else {
            SecureLogger.warning("TorManager: no embedded tor framework found", category: .session)
            return false
        }

        // Load the library
        let mode = RTLD_NOW | RTLD_LOCAL
        SecureLogger.info("TorManager: dlopen(\(fwURL.lastPathComponent))…", category: .session)
        guard let handle = dlopen(fwURL.path, mode) else {
            let err = String(cString: dlerror())
            self.lastError = NSError(domain: "TorManager", code: -10, userInfo: [NSLocalizedDescriptionKey: "dlopen failed: \(err)"])
            self.isStarting = false
            return false
        }

        // Resolve tor_main(argc, argv)
        typealias TorMainType = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        guard let sym = dlsym(handle, "tor_main") else {
            // Keep handle open but report error
            let err = String(cString: dlerror())
            self.lastError = NSError(domain: "TorManager", code: -11, userInfo: [NSLocalizedDescriptionKey: "dlsym tor_main failed: \(err)"])
            self.isStarting = false
            return false
        }
        let torMain = unsafeBitCast(sym, to: TorMainType.self)
        self._dlHandle = handle

        // Prepare args: tor -f <torrc>
        var argv: [String] = ["tor"]
        if let torrc = torrcURL()?.path {
            argv.append(contentsOf: ["-f", torrc])
        }
        // Run Tor on a background thread to avoid blocking the main actor
        SecureLogger.info("TorManager: launching tor_main with torrc", category: .session)
        let argc = Int32(argv.count)
        DispatchQueue.global(qos: .utility).async {
            // Build stable C argv in this thread
            let cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            let cArgv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cStrings.count + 1)
            for i in 0..<cStrings.count { cArgv[i] = cStrings[i] }
            cArgv[cStrings.count] = nil

            _ = torMain(argc, cArgv)

            // Free args after exit (Tor usually never returns)
            for ptr in cStrings.compactMap({ $0 }) { free(ptr) }
            cArgv.deallocate()
        }

        // Start control-port monitor and probe readiness asynchronously
        startControlMonitorIfNeeded()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ready = await self.waitForSocksReady(timeout: 60.0)
            await MainActor.run {
                self.socksReady = ready
                if !ready {
                    self.lastError = NSError(domain: "TorManager", code: -12, userInfo: [NSLocalizedDescriptionKey: "Tor SOCKS not reachable after dlopen start"])
                    SecureLogger.error("TorManager: SOCKS not reachable (timeout)", category: .session)
                } else {
                    SecureLogger.info("TorManager: SOCKS ready at \(self.socksHost):\(self.socksPort)", category: .session)
                }
                // isStarting will be cleared when bootstrap reaches 100%
            }
        }

        return true
    }

    private var _dlHandle: UnsafeMutableRawPointer?

    private func frameworkBinaryURL() -> URL? {
        // Try common embedded locations for the framework binary name
        let candidates = [
            "tor-nolzma.framework/tor-nolzma",
            "Tor.framework/Tor",
        ]
        if let base = Bundle.main.privateFrameworksURL {
            for rel in candidates {
                let url = base.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        // For macOS apps, also try Contents/Frameworks explicitly
        #if os(macOS)
        if let appURL = Bundle.main.bundleURL as URL?,
           let frameworksURL = Optional(appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)) {
            for rel in candidates {
                let url = frameworksURL.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        #endif
        return nil
    }

    // MARK: - Static-link path (no module import)
    private func startTorViaLinkedSymbol() -> Bool {
        // Attempt to start tor_run_main directly (statically linked). If the
        // symbol is not present at link-time, builds will fail — which is
        // expected when the xcframework is absent.
        var argv: [String] = ["tor"]
        if let torrc = torrcURL()?.path { argv.append(contentsOf: ["-f", torrc]) }

        SecureLogger.info("TorManager: starting tor_main (static)", category: .session)
        let argc = Int32(argv.count)
        DispatchQueue.global(qos: .utility).async {
            // Build stable C argv in this thread
            let cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            let cArgv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cStrings.count + 1)
            for i in 0..<cStrings.count { cArgv[i] = cStrings[i] }
            cArgv[cStrings.count] = nil

            _ = tor_main_c(argc, cArgv)

            // If tor_main ever returns, free memory
            for ptr in cStrings.compactMap({ $0 }) { free(ptr) }
            cArgv.deallocate()
        }

        // Start control monitor early
        startControlMonitorIfNeeded()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ready = await self.waitForSocksReady(timeout: 60.0)
            await MainActor.run {
                self.socksReady = ready
                if ready {
                    SecureLogger.info("TorManager: SOCKS ready at \(self.socksHost):\(self.socksPort)", category: .session)
                } else {
                    self.lastError = NSError(domain: "TorManager", code: -13, userInfo: [NSLocalizedDescriptionKey: "Tor SOCKS not reachable after static start"])
                    SecureLogger.error("TorManager: SOCKS not reachable (timeout)", category: .session)
                }
                // isStarting will be cleared when bootstrap reaches 100%
            }
        }
        return true
    }
    
    // MARK: - ControlPort monitoring (bootstrap progress)
    private func startControlMonitorIfNeeded() {
        guard !controlMonitorStarted else { return }
        controlMonitorStarted = true
        // Use a simple GETINFO poll on all platforms to avoid long-lived blocking streams
        Task.detached(priority: .utility) { [weak self] in
            await self?.bootstrapPollLoop()
        }
    }

    private func controlMonitorLoop() async {}

    private func tryControlSessionOnce() async -> Bool { false }

    // iOS: Poll GETINFO periodically to track bootstrap progress without long-lived control readers.
    private func bootstrapPollLoop() async {
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            if let info = await controlGetBootstrapInfo() {
                await MainActor.run {
                    self.bootstrapProgress = info.progress
                    self.bootstrapSummary = info.summary
                    if info.progress >= 100 { self.isStarting = false }
                    self.recomputeReady()
                }
                if info.progress >= 100 { break }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func controlGetBootstrapInfo() async -> (progress: Int, summary: String)? {
        guard let text = await controlExchange(lines: ["GETINFO status/bootstrap-phase"], timeout: 2.0) else { return nil }
        var progress = self.bootstrapProgress
        var summary = self.bootstrapSummary
        // Search entire response for PROGRESS and SUMMARY tokens
        // Typical: "250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=75 TAG=... SUMMARY=\"...\"\r\n250 OK\r\n"
        let tokens = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").split(separator: " ")
        for t in tokens {
            if t.hasPrefix("PROGRESS=") {
                progress = Int(t.split(separator: "=").last ?? "0") ?? progress
            } else if t.hasPrefix("SUMMARY=") {
                let raw = String(t.dropFirst("SUMMARY=".count))
                summary = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return (progress, summary)
    }

    // MARK: - Foreground recovery and control helpers

    func ensureRunningOnForeground() {
        // Respect global start policy
        if !allowAutoStart { return }
        // iOS can suspend Tor harshly; the most reliable approach for
        // embedding is to restart Tor every time we become active.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // Claim the restart under MainActor to avoid races
            let claimed: Bool = await MainActor.run {
                if self.isStarting || self.restarting { return false }
                self.restarting = true
                return true
            }
            if !claimed { return }
            if await self.resumeTorIfPossible() {
                await MainActor.run {
                    self.restarting = false
                    self.isStarting = false
                }
                return
            }
            await self.restartTor()
            await MainActor.run { self.restarting = false }
        }
    }

    func goDormantOnBackground() {
        // Prefer Tor's DORMANT mode so we can resume on foreground without a full restart.
        // If the control port is unreachable, fall back to a hard shutdown.
        Task.detached { [weak self] in
            guard let self = self else { return }
            let signaled = await self.controlSendSignal("DORMANT")
            if signaled {
                SecureLogger.info("TorManager: signalled DORMANT", category: .session)
                await MainActor.run {
                    self.isDormant = true
                    self.isReady = false
                    self.socksReady = false
                    self.isStarting = false
                }
                return
            }

            SecureLogger.warning("TorManager: DORMANT signal failed; shutting down", category: .session)
            _ = tor_host_shutdown()
            await MainActor.run {
                self.isDormant = false
                self.isReady = false
                self.socksReady = false
                self.bootstrapProgress = 0
                self.bootstrapSummary = ""
                self.isStarting = false
                self.didStart = false
                // Allow control monitor to start anew on next start
                self.controlMonitorStarted = false
            }
        }
    }

    private func restartTor() async {
        await MainActor.run {
            // Announce restart so UI can notify the user
            NotificationCenter.default.post(name: .TorWillRestart, object: nil)
            self.isReady = false
            self.socksReady = false
            self.bootstrapProgress = 0
            self.bootstrapSummary = ""
            self.isStarting = true
            self.isDormant = false
            self.lastRestartAt = Date()
        }
        // Prefer clean shutdown via owning controller FD; join the tor thread
        _ = tor_host_shutdown()
        // As a fallback, try control signal if needed (harmless if tor already down)
        _ = await controlSendSignal("SHUTDOWN")
        // Allow Tor thread to fully terminate before re-starting.
        var waited = 0
        while tor_host_is_running() != 0 && waited < 40 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            waited += 1
        }
        if waited >= 40 {
            SecureLogger.warning("TorManager: tor_host_is_running still true before restart", category: .session)
        }
        // Allow control monitor and start logic to reinitialize cleanly
        await MainActor.run {
            self.controlMonitorStarted = false
            self.didStart = false
        }
        // Now start fresh
        await MainActor.run { self.startIfNeeded() }
    }

    private func recomputeReady() {
        let ready = socksReady && bootstrapProgress >= 100
        if ready != isReady {
            isReady = ready
            if ready {
                // Broadcast readiness so clients can rebuild sessions and reconnect
                NotificationCenter.default.post(name: .TorDidBecomeReady, object: nil)
            }
        }
    }

    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let queue = DispatchQueue(label: "TorPathMonitor")
        monitor.pathUpdateHandler = { [weak self] _ in
            // On any path change, poke Tor/recover (hop to main actor).
            Task { @MainActor in
                guard let self = self else { return }
                // Avoid waking Tor while app is backgrounded; we'll handle on .active
                if self.isAppForeground {
                    self.pokeTorOnPathChange()
                }
            }
        }
        monitor.start(queue: queue)
    }

    private func pokeTorOnPathChange() {
        // If a restart just happened, avoid thrashing
        if let last = lastRestartAt, Date().timeIntervalSince(last) < 3.0 {
            return
        }
        // If we're starting or restarting, do nothing and let that complete
        if isStarting || restarting { return }
        Task.detached(priority: .userInitiated) {
            let ok = await self.controlPingBootstrap()
            if ok {
                _ = await self.controlSendSignal("ACTIVE")
                return
            }
            // If bootstrapping is underway, let it finish
            let stillBootstrapping = await MainActor.run { self.socksReady && self.bootstrapProgress < 100 }
            if stillBootstrapping { return }
            // As a last resort, restart
            await self.ensureRunningOnForeground()
        }
    }

    // Lightweight control: authenticate and GETINFO bootstrap-phase.
    private func controlPingBootstrap(timeout: TimeInterval = 3.0) async -> Bool {
        let data = await controlExchange(lines: ["GETINFO status/bootstrap-phase"], timeout: timeout)
        guard let text = data else { return false }
        return text.contains("status/bootstrap-phase")
    }

    private func controlSendSignal(_ signal: String, timeout: TimeInterval = 3.0) async -> Bool {
        let text = await controlExchange(lines: ["SIGNAL \(signal)"], timeout: timeout)
        return (text?.contains("250")) == true
    }

    private func resumeTorIfPossible() async -> Bool {
        let wasDormant = await MainActor.run { self.isDormant }
        let pendingReady = await MainActor.run { self.socksReady && !self.isReady }
        let needsWake = wasDormant || pendingReady
        if !needsWake {
            return false
        }

        let activated = await controlSendSignal("ACTIVE")
        let pinged = await controlPingBootstrap(timeout: 3.0)
        if !activated && !pinged {
            SecureLogger.warning("TorManager: ACTIVE signal failed", category: .session)
            return false
        }

        if let info = await controlGetBootstrapInfo() {
            await MainActor.run {
                self.bootstrapProgress = info.progress
                self.bootstrapSummary = info.summary
            }
        }

        await MainActor.run {
            self.isDormant = false
            self.isStarting = true
            self.socksReady = false
        }

        let firstReady = await waitForSocksReady(timeout: 12.0)
        if firstReady {
            await MainActor.run {
                self.socksReady = true
                self.isStarting = false
            }
            SecureLogger.info("TorManager: resumed Tor via ACTIVE signal", category: .session)
            return true
        }

        if pinged {
            let secondReady = await waitForSocksReady(timeout: 20.0)
            await MainActor.run {
                self.socksReady = secondReady
                self.isStarting = !secondReady
            }
            if secondReady {
                SecureLogger.info("TorManager: resumed Tor after extended wait", category: .session)
                return true
            }
        } else {
            await MainActor.run { self.isStarting = false }
        }

        SecureLogger.warning("TorManager: ACTIVE resume failed; will restart", category: .session)
        return false
    }

    private func controlExchange(lines: [String], timeout: TimeInterval) async -> String? {
        guard let cookiePath = dataDirectoryURL()?.appendingPathComponent("control_auth_cookie"),
              let cookie = try? Data(contentsOf: cookiePath) else { return nil }
        let cookieHex = cookie.map { String(format: "%02X", $0) }.joined()

        let queue = DispatchQueue(label: "TorControl", qos: .userInitiated)
        let params = NWParameters.tcp
        guard let port = NWEndpoint.Port(rawValue: UInt16(controlPort)) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        let conn = NWConnection(to: endpoint, using: params)

        var resultText = ""
        var completed = false
        func send(_ text: String) {
            let data = (text + "\r\n").data(using: .utf8) ?? Data()
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
        func receiveLoop(deadline: Date) async {
            while Date() < deadline {
                let ok: Bool = await withCheckedContinuation { cont in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                        if let data = data, !data.isEmpty, let s = String(data: data, encoding: .utf8) {
                            resultText.append(s)
                        }
                        if isComplete || error != nil { completed = true }
                        cont.resume(returning: true)
                    }
                }
                if !ok || completed { break }
                // Small delay to avoid tight loop
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        conn.start(queue: queue)
        // Send immediately; NWConnection will queue until ready
        send("AUTHENTICATE \(cookieHex)")
        // Send requested lines
        for line in lines { send(line) }
        // Ask tor to close
        send("QUIT")
        await receiveLoop(deadline: Date().addingTimeInterval(timeout))
        conn.cancel()
        return resultText
    }
}

// MARK: - Start policy configuration
extension TorManager {
    @MainActor
    func setAutoStartAllowed(_ allow: Bool) {
        allowAutoStart = allow
    }

    @MainActor
    func isAutoStartAllowed() -> Bool { allowAutoStart }
}
