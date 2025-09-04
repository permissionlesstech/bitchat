import Foundation
import Combine
import SwiftUI
import SwiftTor
import Darwin

@MainActor
final class TorService: ObservableObject {
    static let shared = TorService()
    
    // Tor is now required and always enabled
    @Published var isEnabled: Bool = true
    
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isConnecting: Bool = false
    // Simple staged progress for UI (0, 33, 66, 100)
    @Published private(set) var progress: Int = 0
    
    // Underlying SwiftTor instance (manages Tor process and URLSession)
    private var tor: SwiftTor?
    private var cancellables = Set<AnyCancellable>()
    
    // Restart/stop coordination to avoid multiple TORThread instances
    private var isStopping = false
    private var restartWorkItem: DispatchWorkItem?
    private var restartInFlight = false
    private var lastRestartAt: Date = .distantPast
    private var lastState: TorState = .none
    private var lastRSSLogAt: Date = .distantPast
    private var lastRSSMB: Double = 0
    private var hasLoggedSessionConfig = false
    // Port-collision retry
    private var portRetryWorkItem: DispatchWorkItem?
    // Connectivity probe coordination
    private var connectivityProbeInFlight = false
    private var lastConnectivityProbeAt: Date = .distantPast
    private let minProbeInterval: TimeInterval = 10
    private let probeTimeout: TimeInterval = 8
    
    /// Public helper: probe Tor connectivity and recover if needed.
    /// - Parameters:
    ///   - trigger: For logging context (who asked for probe)
    ///   - completion: Called with true if connectivity OK, false if recovery attempted
    func checkTorConnectivityAndRecoverIfNeeded(trigger: String, completion: ((Bool) -> Void)? = nil) {
        // Throttle probes
        let now = Date()
        if connectivityProbeInFlight { return }
        if now.timeIntervalSince(lastConnectivityProbeAt) < minProbeInterval { return }
        connectivityProbeInFlight = true
        lastConnectivityProbeAt = now
        probeTorConnectivity(timeout: probeTimeout) { [weak self] ok in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.connectivityProbeInFlight = false
                if ok {
                    SecureLogger.log("TorService: connectivity probe OK", category: SecureLogger.session, level: .debug)
                    completion?(true)
                } else {
                    SecureLogger.log("TorService: connectivity probe FAILED — restarting Tor", category: SecureLogger.session, level: .error)
                    // Restart tor; NostrRelayManager reset will be triggered once Tor transitions to connected
                    self.restartTor()
                    completion?(false)
                }
            }
        }
    }
    
    private init() {
        // Force-enable tor regardless of any previous persisted setting
        UserDefaults.standard.set(true, forKey: "torEnabled")
    }
    
    func startIfEnabled() {
        // Always start; Tor is required
        guard !isStopping else { return }
        if tor == nil { startTor() } else { updateConnectionFlags(from: tor?.state ?? .none) }
    }
    
    func startTor() {
        guard tor == nil, !isStopping else { return }
        isConnecting = true
        isConnected = false
        progress = 0
        if let mb = MemoryUtil.residentSizeMB() {
            SecureLogger.log("TorService: startTor() app RSS=\(mb) MB", category: SecureLogger.session, level: .debug)
        } else {
            SecureLogger.log("TorService: startTor() app RSS unavailable", category: SecureLogger.session, level: .debug)
        }
        
        // Preflight: ensure our listener ports are free; if not, delay and retry instead of failing at 10%
        var socksPort = 19050
        #if targetEnvironment(simulator)
        socksPort = 19052
        #endif
        let dnsPort = 12345
        if !isLocalPortAvailable(socksPort) || !isLocalPortAvailable(dnsPort) {
            SecureLogger.log("TorService: required ports busy (SOCKS \(socksPort) or DNS \(dnsPort)); retrying shortly…",
                             category: SecureLogger.session, level: .warning)
            portRetryWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.startTor() }
            portRetryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
            return
        }

        let instance = SwiftTor(start: true)
        self.tor = instance
        SecureLogger.log("TorService: SwiftTor instance created; starting TOR thread", category: SecureLogger.session, level: .info)
        
        // Observe Tor state changes
        instance.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                self.updateConnectionFlags(from: state)
            }
            .store(in: &cancellables)
    }

    // Attempt to bind the requested local TCP port to detect if it's already in use.
    // Returns true if the port appears free (bind succeeds then immediately closes), false if in use or on error.
    private func isLocalPortAvailable(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return false }
        var yes: Int32 = 1
        _ = withUnsafePointer(to: &yes) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 1) { p in
                setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, p, socklen_t(MemoryLayout<Int32>.size))
            }
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            return ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                bind(sock, p, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let ok = (result == 0)
        // If we managed to bind, immediately close; the port will be free for Tor to claim.
        if ok {
            _ = close(sock)
            return true
        } else {
            _ = close(sock)
            return false
        }
    }
    
    /// Safely restart Tor avoiding multiple TORThread instances.
    func restartTor() {
        // Avoid overlapping restarts or restarts while connecting/stopping
        guard !restartInFlight else { return }
        guard !isStopping else { return }
        guard !isConnecting else { return }
        lastRestartAt = Date()
        restartInFlight = true
        isStopping = true
        isConnecting = true
        isConnected = false
        progress = max(progress, 33)

        // Cleanly stop and fully release prior Tor instance
        restartWorkItem?.cancel()
        cancellables.removeAll()
        if let st = tor {
            st.tor.resign()
            st.started = false
        }
        tor = nil
        SecureLogger.log("TorService: restartTor() tearing down previous instance", category: SecureLogger.session, level: .info)

        // Wait longer to ensure previous TORThread tears down
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isStopping = false
            self.restartInFlight = false
            self.startTor()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
    
    func stopTor() {
        // Clean stop of Tor thread and clear observers
        restartWorkItem?.cancel()
        cancellables.removeAll()
        if let st = tor {
            st.tor.resign()
            st.started = false
        }
        tor = nil
        isConnecting = false
        isConnected = false
        isStopping = false
        progress = 0
        if let mb = MemoryUtil.residentSizeMB() {
            SecureLogger.log("TorService: stopTor() app RSS=\(mb) MB", category: SecureLogger.session, level: .debug)
        }
        // Proactively drop any Nostr sockets while Tor is down
        NostrRelayManager.shared.disconnect()
    }
    
    private func updateConnectionFlags(from state: TorState) {
        // Map TorState to simple staged progress for chat (bootstrapped-like)
        switch state {
        case .started:
            if progress < 10 { progress = 10 } // conn
        case .refreshing:
            if progress < 90 { progress = 90 } // ap_handshake_done
        case .connected:
            progress = 100 // done
            // Log RSS on transition and occasionally if it changes significantly
            if let mb = MemoryUtil.residentSizeMB() {
                let now = Date()
                if lastState != .connected || now.timeIntervalSince(lastRSSLogAt) > 30 || abs(mb - lastRSSMB) > 10 {
                    SecureLogger.log("TorService: connected; app RSS=\(mb) MB", category: SecureLogger.session, level: .info)
                    lastRSSLogAt = now
                    lastRSSMB = mb
                }
            }
        case .stopped, .none:
            if !isEnabled { progress = 0 }
            // Log one-time when transitioning away from connected
            if lastState == .connected {
                if let mb = MemoryUtil.residentSizeMB() {
                    SecureLogger.log("TorService: stopped; app RSS=\(mb) MB", category: SecureLogger.session, level: .info)
                }
            }
        }
        lastState = state
        switch state {
        case .connected:
            let wasConnected = isConnected
            isConnected = true
            isConnecting = false
            if !wasConnected {
                // Reconnect Nostr websockets through Tor
                NostrRelayManager.shared.resetAllConnections()
            }
        case .started:
            isConnecting = true
            isConnected = false
        case .stopped, .none, .refreshing:
            isConnected = false
        }
    }
    
    /// Returns the URLSession to use for network/WebSocket traffic respecting Tor setting.
    func networkSession() -> URLSession {
        // Always route via Tor SOCKS proxy
        var port = 19050
        #if targetEnvironment(simulator)
        port = 19052
        #endif
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [
            kCFProxyTypeKey: kCFProxyTypeSOCKS,
            kCFStreamPropertySOCKSVersion: kCFStreamSocketSOCKSVersion5,
            kCFStreamPropertySOCKSProxyHost: "127.0.0.1",
            kCFStreamPropertySOCKSProxyPort: port
        ] as [AnyHashable: Any]
        if !hasLoggedSessionConfig {
            SecureLogger.log("TorService: using SOCKS proxy 127.0.0.1:\(port) for all HTTP/WebSocket", category: SecureLogger.session, level: .info)
            hasLoggedSessionConfig = true
        }
        return URLSession(configuration: config)
    }
    
    // MARK: - Health probe
    private func probeTorConnectivity(timeout: TimeInterval = 8, completion: @escaping (Bool) -> Void) {
        // Use Tor-enabled session regardless of state, to test proxy path

        let session = networkSession()
        guard let url = URL(string: "https://check.torproject.org/api/ip") else { completion(false); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let lock = DispatchQueue(label: "TorService.probe.lock")
        var finished = false
        func finish(_ ok: Bool) {
            lock.sync {
                if finished { return }
                finished = true
                completion(ok)
            }
        }

        let task = session.dataTask(with: request) { data, response, error in
            let ok = (error == nil) && (response as? HTTPURLResponse)?.statusCode == 200 && (data?.isEmpty == false)
            Task { @MainActor in finish(ok) }
        }
        task.resume()
        // Fallback timeout guard (non-cancelling, returns false if not completed earlier)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2) {
            Task { @MainActor in finish(false) }
        }
    }
    
    /// Call when app resumes from background to ensure Tor is actually routing.
    func verifyTorOnResume() {
        guard isEnabled else { return }
        guard !isStopping else { return }
        // If Tor is already connected, do not probe/restart unnecessarily
        if isConnected { return }
        // Don't probe while connecting; give Tor time to come up
        guard !isConnecting else { return }
        // Throttle restarts to at most once per 10 seconds
        if Date().timeIntervalSince(lastRestartAt) < 10 { return }
        probeTorConnectivity { [weak self] ok in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if ok {
                    if !NostrRelayManager.shared.isConnected {
                        NostrRelayManager.shared.resetAllConnections()
                    }
                } else {
                    self.restartTor()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        NostrRelayManager.shared.resetAllConnections()
                    }
                }
            }
        }
    }
    
    /// Optional one-shot health check shortly after resume
    func scheduleActiveHealthCheck() {
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.verifyTorOnResume()
        }
    }
}

extension URLSession {
    /// Convenience to get a Tor-enabled session if available
    @MainActor static func torEnabledSession() -> URLSession {
        return TorService.shared.networkSession()
    }
}
