import Foundation
import Combine
import SwiftUI
import SwiftTor

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
        let task = session.dataTask(with: request) { data, response, error in
            let ok = (error == nil) && (response as? HTTPURLResponse)?.statusCode == 200 && (data?.isEmpty == false)
            completion(ok)
        }
        task.resume()
        // Fallback timeout guard (non-cancelling, returns false if not completed earlier)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2) {
            completion(false)
        }
    }
    
    /// Call when app resumes from background to ensure Tor is actually routing.
    func verifyTorOnResume() {
        guard isEnabled else { return }
        guard !isStopping else { return }
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
