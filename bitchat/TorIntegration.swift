import Foundation
import TorManager
import SwiftUI

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
    
    private init() {
        // Check initial connection status
        updateConnectionStatus()
    }
    

    func updateConnectionStatus() {
        let connected = TorManager.shared.connected && self.isEnabled
        if Thread.isMainThread {
            self.isConnected = connected
        } else {
            DispatchQueue.main.async { [connected] in
                self.isConnected = connected
            }
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
        if TorSettings.shared.isEnabled && TorManager.shared.connected {
            config.connectionProxyDictionary = TorManager.shared.torSocks5ProxyConf
        }
        return URLSession(configuration: config)
    }
}
