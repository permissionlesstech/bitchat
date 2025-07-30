import Foundation
import CoreBluetooth

/// Unified model for tracking all peer session data
/// Consolidates multiple redundant data structures into a single source of truth
class PeerSession {
    // Core identification
    let peerID: String
    var nickname: String
    
    // Bluetooth connection
    var peripheral: CBPeripheral?
    var peripheralID: String?
    var characteristic: CBCharacteristic?
    
    // Authentication and encryption
    var isAuthenticated: Bool = false
    var hasEstablishedNoiseSession: Bool = false
    var fingerprint: String?
    
    // Connection state
    var isConnected: Bool = false
    var lastSeen: Date
    
    // Protocol state
    var hasAnnounced: Bool = false
    var hasReceivedAnnounce: Bool = false
    var isActivePeer: Bool = false
    
    // Message tracking
    var lastMessageSent: Date?
    var lastMessageReceived: Date?
    var pendingMessages: [String] = []
    
    // Connection timing
    var lastConnectionTime: Date?
    var lastSuccessfulMessageTime: Date?
    var lastHeardFromPeer: Date?
    
    // Availability tracking
    var isAvailable: Bool = false
    
    // Identity binding
    var identityBinding: PeerIdentityBinding?
    
    init(peerID: String, nickname: String = "Unknown") {
        self.peerID = peerID
        self.nickname = nickname
        self.lastSeen = Date()
    }
    
    /// Update Bluetooth connection info
    func updateBluetoothConnection(peripheral: CBPeripheral?, characteristic: CBCharacteristic?) {
        self.peripheral = peripheral
        self.peripheralID = peripheral?.identifier.uuidString
        self.characteristic = characteristic
        self.isConnected = (peripheral?.state == .connected)
        if isConnected {
            self.lastSeen = Date()
        }
    }
    
    /// Update authentication state
    func updateAuthenticationState(authenticated: Bool, noiseSession: Bool) {
        self.isAuthenticated = authenticated
        self.hasEstablishedNoiseSession = noiseSession
        if authenticated {
            self.isActivePeer = true
        }
    }
    
    
    /// Check if session is stale
    var isStale: Bool {
        // Consider stale if not seen for more than 5 minutes and not connected
        return !isConnected && Date().timeIntervalSince(lastSeen) > 300
    }
    
    /// Get display status for UI
    var displayStatus: String {
        if isConnected {
            if isAuthenticated {
                return "🟢" // Connected and authenticated
            } else {
                return "🟡" // Connected but not authenticated
            }
        } else {
            return "🔴" // Not connected
        }
    }
}