import Foundation
import Combine
import SwiftUI
import SwiftTor

@MainActor
final class TorService: ObservableObject {
    static let shared = TorService()
    
    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: "torEnabled") {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "torEnabled") }
    }
    
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isConnecting: Bool = false
    
    // Underlying SwiftTor instance (manages Tor process and URLSession)
    private var tor: SwiftTor?
    private var cancellables = Set<AnyCancellable>()
    
    // Restart/stop coordination to avoid multiple TORThread instances
    private var isStopping = false
    private var restartWorkItem: DispatchWorkItem?
    
    private init() {}
    
    func startIfEnabled() {
        guard isEnabled, !isStopping else { return }
        if tor == nil { startTor() } else { updateConnectionFlags(from: tor?.state ?? .none) }
    }
    
    func toggle() {
        isEnabled.toggle()
        if isEnabled {
            startTor()
        } else {
            // Cleanly stop Tor thread and reconnect without Tor
            stopTor()
            NostrRelayManager.shared.resetAllConnections()
        }
    }
    
    func startTor() {
        guard tor == nil, !isStopping else { return }
        isConnecting = true
        isConnected = false
        
        let instance = SwiftTor(start: true)
        self.tor = instance
        
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
        guard let tor = tor else { startTor(); return }
        guard !isStopping else { return }
        isStopping = true
        isConnecting = true
        isConnected = false
        
        // Stop current Tor thread
        tor.tor.resign()
        tor.started = false
        
        // Coalesce restarts and wait briefly for TORThread to fully teardown
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Reinitialize the underlying TorHelper and start
            if let st = self.tor {
                st.tor = TorHelper()
                st.start()
            } else {
                self.tor = SwiftTor(start: true)
            }
            self.isStopping = false
        }
        restartWorkItem = work
        // Give TORThread time to fully cancel before starting a new one
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
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
    }
    
    private func updateConnectionFlags(from state: TorState) {
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
        if isEnabled {
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
            return URLSession(configuration: config)
        }
        return URLSession(configuration: .default)
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
