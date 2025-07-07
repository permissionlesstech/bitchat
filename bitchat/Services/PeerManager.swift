//
//  PeerManager.swift
//  bitchat
//
//  Manages peer discovery and transport selection
//

import Foundation

/// Manages which transport to use for each peer
final class PeerManager {
    
    // MARK: - Singleton
    
    static let shared = PeerManager()
    
    // MARK: - Properties
    
    /// Maps peerID to preferred transport type
    private var peerTransportMap: [String: TransportType] = [:]
    
    /// Maps peerID to last seen time on each transport
    private var peerTransportVisibility: [String: [TransportType: Date]] = [:]
    
    /// Maps peerID to RSSI on each transport
    private var peerTransportRSSI: [String: [TransportType: Int]] = [:]
    
    /// Thread safety
    private let queue = DispatchQueue(label: "bitchat.peermanager", attributes: .concurrent)
    
    // MARK: - Public Methods
    
    /// Selects the best transport for communicating with a peer
    /// - Parameter peerID: The peer's device ID
    /// - Returns: The recommended transport type, or nil if peer not found
    func selectTransport(for peerID: String) -> TransportType? {
        queue.sync {
            // First check if we have a preferred transport
            if let preferred = peerTransportMap[peerID],
               isTransportStillValid(preferred, for: peerID) {
                return preferred
            }
            
            // Otherwise, select based on current visibility
            guard let visibility = peerTransportVisibility[peerID] else {
                return nil
            }
            
            // Filter to transports seen in last 30 seconds
            let recentTransports = visibility.filter { (_, lastSeen) in
                Date().timeIntervalSince(lastSeen) < 30
            }
            
            guard !recentTransports.isEmpty else {
                return nil
            }
            
            // If only one transport, use it
            if recentTransports.count == 1 {
                return recentTransports.first?.key
            }
            
            // Multiple transports available - apply selection logic
            
            // 1. Prefer Bluetooth for power efficiency
            if recentTransports[.bluetooth] != nil {
                // Check RSSI if available
                if let rssi = peerTransportRSSI[peerID]?[.bluetooth],
                   rssi > -80 { // Good signal
                    return .bluetooth
                }
            }
            
            // 2. Use WiFi Direct if Bluetooth signal is poor or unavailable
            if recentTransports[.wifiDirect] != nil {
                return .wifiDirect
            }
            
            // 3. Fallback to any available transport
            return recentTransports.keys.first
        }
    }
    
    /// Updates peer visibility when seen on a transport
    /// - Parameters:
    ///   - peerID: The peer's device ID
    ///   - transport: The transport where peer was seen
    ///   - rssi: Optional signal strength
    func updatePeerVisibility(peerID: String, on transport: TransportType, rssi: Int? = nil) {
        queue.async(flags: .barrier) {
            // Update visibility timestamp
            if self.peerTransportVisibility[peerID] == nil {
                self.peerTransportVisibility[peerID] = [:]
            }
            self.peerTransportVisibility[peerID]?[transport] = Date()
            
            // Update RSSI if provided
            if let rssi = rssi {
                if self.peerTransportRSSI[peerID] == nil {
                    self.peerTransportRSSI[peerID] = [:]
                }
                self.peerTransportRSSI[peerID]?[transport] = rssi
            }
            
            // Update preferred transport if this is the first sighting
            if self.peerTransportMap[peerID] == nil {
                self.peerTransportMap[peerID] = transport
            }
        }
    }
    
    /// Records successful message delivery to update transport preference
    /// - Parameters:
    ///   - peerID: The peer's device ID
    ///   - transport: The transport that successfully delivered
    func recordSuccessfulDelivery(to peerID: String, via transport: TransportType) {
        queue.async(flags: .barrier) {
            self.peerTransportMap[peerID] = transport
            self.updatePeerVisibility(peerID: peerID, on: transport)
        }
    }
    
    /// Records failed delivery to potentially switch transports
    /// - Parameters:
    ///   - peerID: The peer's device ID
    ///   - transport: The transport that failed
    func recordFailedDelivery(to peerID: String, via transport: TransportType) {
        queue.async(flags: .barrier) {
            // If this was the preferred transport, clear it
            if self.peerTransportMap[peerID] == transport {
                self.peerTransportMap[peerID] = nil
            }
        }
    }
    
    /// Gets all known peers across all transports
    /// - Returns: Set of all peer IDs
    func getAllKnownPeers() -> Set<String> {
        queue.sync {
            Set(peerTransportVisibility.keys)
        }
    }
    
    /// Gets peers visible on a specific transport
    /// - Parameter transport: The transport to check
    /// - Returns: Array of peer IDs visible on that transport
    func getPeers(on transport: TransportType) -> [String] {
        queue.sync {
            peerTransportVisibility.compactMap { (peerID, visibility) in
                if let lastSeen = visibility[transport],
                   Date().timeIntervalSince(lastSeen) < 30 {
                    return peerID
                }
                return nil
            }
        }
    }
    
    /// Checks if we can bridge between transports
    /// - Returns: true if this device sees peers on multiple transports
    func canBridge() -> Bool {
        queue.sync {
            let transportsWithPeers = TransportType.allCases.filter { transport in
                !getPeers(on: transport).isEmpty
            }
            return transportsWithPeers.count > 1
        }
    }
    
    /// Gets the recommended route for a message to an unknown peer
    /// - Parameter destinationID: The ultimate destination
    /// - Returns: Next hop peer ID and transport, or nil if no route
    func getRoute(to destinationID: String) -> (peerID: String, transport: TransportType)? {
        // For now, we don't have routing tables
        // In the future, we could implement distance vector routing
        return nil
    }
    
    /// Clears stale peer data
    func cleanupStalePeers() {
        queue.async(flags: .barrier) {
            let staleTimeout: TimeInterval = 300 // 5 minutes
            let now = Date()
            
            // Remove peers not seen in 5 minutes
            self.peerTransportVisibility = self.peerTransportVisibility.compactMapValues { visibility in
                let activeTransports = visibility.filter { (_, lastSeen) in
                    now.timeIntervalSince(lastSeen) < staleTimeout
                }
                return activeTransports.isEmpty ? nil : activeTransports
            }
            
            // Clean up other maps
            let activePeers = Set(self.peerTransportVisibility.keys)
            self.peerTransportMap = self.peerTransportMap.filter { activePeers.contains($0.key) }
            self.peerTransportRSSI = self.peerTransportRSSI.filter { activePeers.contains($0.key) }
        }
    }
    
    // MARK: - Private Methods
    
    private func isTransportStillValid(_ transport: TransportType, for peerID: String) -> Bool {
        guard let lastSeen = peerTransportVisibility[peerID]?[transport] else {
            return false
        }
        return Date().timeIntervalSince(lastSeen) < 30
    }
    
    // MARK: - Debug
    
    func debugPrintState() {
        queue.sync {
            print("=== PeerManager State ===")
            print("Known peers: \(peerTransportVisibility.count)")
            for (peerID, visibility) in peerTransportVisibility {
                print("  \(peerID):")
                for (transport, lastSeen) in visibility {
                    let ago = Int(Date().timeIntervalSince(lastSeen))
                    let rssi = peerTransportRSSI[peerID]?[transport] ?? 0
                    print("    \(transport): \(ago)s ago, RSSI: \(rssi)")
                }
                if let preferred = peerTransportMap[peerID] {
                    print("    Preferred: \(preferred)")
                }
            }
            print("Can bridge: \(canBridge())")
            print("======================")
        }
    }
}