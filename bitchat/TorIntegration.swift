import Foundation
import TorManager
import SwiftUI
#if os(iOS)
import UIKit
#endif

extension TorManager {
    // Provide a single shared instance with a cache directory for Tor state.
    static let shared: TorManager = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tor", isDirectory: true)
        return TorManager(directory: dir)
    }()
}

// Observable class to track Tor status and preferences
class TorSettings: ObservableObject {
    static let shared = TorSettings()
    
    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: "torEnabled") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "torEnabled")
        }
    }
    
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false

    // Internal state guards
    private var hasStartedTor: Bool = false
    private var isShuttingDown: Bool = false
    private var lastBackgroundTime: Date?
    
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
    
    private init() {
        // Check initial connection status
        updateConnectionStatus()
        
        #if os(iOS)
        // Listen for background/foreground transitions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
    }
    
    #if os(iOS)
    @objc private func appDidEnterBackground() {
        lastBackgroundTime = Date()
        
        // Start background task to handle TOR cleanup if needed
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "TorBackgroundCleanup") { [weak self] in
            self?.endBackgroundTask()
        }
    }
    
    @objc private func appWillEnterForeground() {
        endBackgroundTask()
        
        // Check if we've been in background for a significant time
        if let backgroundTime = lastBackgroundTime,
           Date().timeIntervalSince(backgroundTime) > 300 { // 5 minutes
            // App was backgrounded for a long time, more likely TOR daemon was killed
            DispatchQueue.main.async { [weak self] in
                self?.verifyTorConnection()
            }
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    #endif
    

    func updateConnectionStatus() {
        let connected = TorManager.shared.connected && self.isEnabled && TorManager.shared.torSocks5ProxyConf != nil
        if Thread.isMainThread {
            self.isConnected = connected
        } else {
            DispatchQueue.main.async { [connected] in
                self.isConnected = connected
            }
        }
    }
    
    // Actively test TOR connection status, especially after backgrounding
    func verifyTorConnection() {
        guard isEnabled else {
            DispatchQueue.main.async {
                self.isConnected = false
                self.isConnecting = false
            }
            return
        }
        
        // First check basic TorManager status
        let basicCheck = TorManager.shared.connected && TorManager.shared.torSocks5ProxyConf != nil
        
        if !basicCheck {
            DispatchQueue.main.async {
                self.isConnected = false
                if self.isEnabled && !self.isConnecting {
                    // TOR daemon appears dead, restart it
                    self.startTor()
                }
            }
            return
        }
        
        // Perform an active connectivity test through TOR
        testTorConnectivity { [weak self] isWorking in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if isWorking {
                    self.isConnected = true
                    self.isConnecting = false
                } else {
                    self.isConnected = false
                    if self.isEnabled && !self.isConnecting {
                        // TOR is not working properly, restart it
                        self.restartTor()
                    }
                }
            }
        }
    }
    
    // Test TOR connectivity by making a simple request through the proxy
    private func testTorConnectivity(completion: @escaping (Bool) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        
        // Use TOR proxy configuration
        if let conf = TorManager.shared.torSocks5ProxyConf {
            config.connectionProxyDictionary = conf
        } else {
            config.connectionProxyDictionary = [
                kCFProxyTypeKey: kCFProxyTypeSOCKS,
                kCFStreamPropertySOCKSVersion: kCFStreamSocketSOCKSVersion5,
                kCFStreamPropertySOCKSProxyHost: "127.0.0.1",
                kCFStreamPropertySOCKSProxyPort: 9050
            ]
        }
        
        let session = URLSession(configuration: config)
        
        // Test with a simple HTTP request to a reliable endpoint
        guard let url = URL(string: "https://check.torproject.org/api/ip") else {
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let task = session.dataTask(with: request) { data, response, error in
            let isWorking = error == nil && 
                           (response as? HTTPURLResponse)?.statusCode == 200 &&
                           data != nil
            completion(isWorking)
        }
        
        task.resume()
        
        // Fallback timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            task.cancel()
            completion(false)
        }
    }
    
    @MainActor func toggleTor() {
        isEnabled.toggle()
        if isEnabled {
            // If Tor thread is already up, we don't need to start it again. Just reconnect via Tor.
            if TorManager.shared.connected {
                isConnecting = false
                isConnected = true
                NostrRelayManager.shared.resetAllConnections()
            } else {
                startTor()
            }
        } else {
            // Do not fully stop the Tor thread when user disables; just disable routing
            disableTorRouting()
        }
    }
    
    func startTor() {
        // Avoid duplicate starts in this process
        if isConnecting || hasStartedTor || TorManager.shared.connected { return }

        // Indicate connecting on the main thread
        isConnecting = true
        isConnected = false

        // Mark that we've attempted to start Tor in this process to avoid multiple TORThread instances
        hasStartedTor = true

        TorManager.shared.start { [weak self] error in
            // Ensure UI state updates happen on the main thread
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isConnecting = false
                if let error = error {
                    print("TorManager failed to start: \(error)")
                    self.isEnabled = false
                    self.isConnected = false
                    // Allow retry in case of failure
                    self.hasStartedTor = false
                } else {
                    print("TorManager started successfully")
                    // Only mark connected if the user still wants Tor enabled
                    if self.isEnabled {
                        self.isConnected = true
                        self.isConnecting = false
                        // Reconnect Nostr websockets through Tor
                        NostrRelayManager.shared.resetAllConnections()
                    } else {
                        // User toggled off while Tor was starting; keep Tor thread alive
                        // Just mark disabled and leave routing over clearnet
                        self.isConnected = false
                        self.isConnecting = false
                        // Leave hasStartedTor = true so we don't try to start another TORThread
                    }
                }
            }
        }

        // Do not block the main thread; connection updates will arrive via the callback above
    }
    
    // Restart TOR when it's detected as dead
    @MainActor func restartTor() {
        guard isEnabled && !isConnecting else { return }
        
        print("Restarting TOR due to detected connection failure")
        
        // Stop the current TOR instance
        if hasStartedTor {
            TorManager.shared.stop()
            hasStartedTor = false
        }
        
        // Reset state
        isConnected = false
        isConnecting = false
        
        // Start TOR again after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startTor()
        }
    }
    
    @MainActor func stopTor() {
        // If Tor was never started in this process or already disconnected, just ensure state and relays
        if !hasStartedTor && !TorManager.shared.connected {
            isConnected = false
            isConnecting = false
            NostrRelayManager.shared.resetAllConnections()
            return
        }

        TorManager.shared.stop()
        isConnected = false
        isConnecting = false
        // Allow a future start in this process
        hasStartedTor = false
        // Reconnect Nostr websockets without Tor
        NostrRelayManager.shared.resetAllConnections()
    }
    // Called when user disables Tor in UI: do not fully stop the Tor thread.
    // We only disable routing via Tor by reconnecting transports without proxy.
    @MainActor func disableTorRouting() {
        isEnabled = false
        isConnecting = false
        // Do not call TorManager.shared.stop() here to avoid creating/destroying TORThread repeatedly
        // Reconnect Nostr websockets without Tor
        NostrRelayManager.shared.resetAllConnections()
    }

    // Called once on application shutdown to fully stop Tor
    @MainActor func shutdownTor() {
        guard hasStartedTor || TorManager.shared.connected else { return }
        isShuttingDown = true
        TorManager.shared.stop()
        isConnected = false
        isConnecting = false
        hasStartedTor = false
        isShuttingDown = false
    }
}

// Extension to provide Tor-enabled URLSession
extension URLSession {
    static func torEnabledSession() -> URLSession {
        let config = URLSessionConfiguration.default
        if TorSettings.shared.isEnabled {
            if TorManager.shared.connected, let conf = TorManager.shared.torSocks5ProxyConf {
                config.connectionProxyDictionary = conf
            } else {
                // Fallback to default Tor proxy settings if enabled but not fully connected/configured
                config.connectionProxyDictionary = [
                    kCFProxyTypeKey: kCFProxyTypeSOCKS,
                    kCFStreamPropertySOCKSVersion: kCFStreamSocketSOCKSVersion5,
                    kCFStreamPropertySOCKSProxyHost: "127.0.0.1",
                    kCFStreamPropertySOCKSProxyPort: 9050
                ]
            }
        }
        return URLSession(configuration: config)
    }
}
