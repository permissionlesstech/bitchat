import Foundation
import CoreBluetooth

/// Represents a peer in the BitChat network with all associated metadata
struct BitchatPeer: Identifiable, Equatable {
    let id: String // Hex-encoded peer ID
    let noisePublicKey: Data
    let nickname: String
    let lastSeen: Date
    let isConnected: Bool
    
    // Favorite-related properties
    var favoriteStatus: FavoritesPersistenceService.FavoriteRelationship?
    
    // Nostr identity (if known)
    var nostrPublicKey: String?
    
    // Connection state
    enum ConnectionState {
        case bluetoothConnected
        case relayConnected     // Connected via mesh relay (another peer)
        case nostrAvailable     // Mutual favorite, reachable via Nostr
        case offline            // Not connected via any transport
    }
    
    var connectionState: ConnectionState {
        if isConnected {
            return .bluetoothConnected
        } else if isRelayConnected {
            return .relayConnected
        } else if favoriteStatus?.isMutual == true {
            // Mutual favorites can communicate via Nostr when offline
            return .nostrAvailable
        } else {
            return .offline
        }
    }
    
    var isRelayConnected: Bool = false  // Set by PeerManager based on session state
    
    var isFavorite: Bool {
        favoriteStatus?.isFavorite ?? false
    }
    
    var isMutualFavorite: Bool {
        favoriteStatus?.isMutual ?? false
    }
    
    var theyFavoritedUs: Bool {
        favoriteStatus?.theyFavoritedUs ?? false
    }
    
    // Display helpers
    var displayName: String {
        nickname.isEmpty ? String(id.prefix(8)) : nickname
    }
    
    var statusIcon: String {
        switch connectionState {
        case .bluetoothConnected:
            return "📻" // Radio icon for mesh connection
        case .relayConnected:
            return "🔗" // Chain link for relay connection
        case .nostrAvailable:
            return "🌐" // Purple globe for Nostr
        case .offline:
            if theyFavoritedUs && !isFavorite {
                return "🌙" // Crescent moon - they favorited us but we didn't reciprocate
            } else {
                return ""
            }
        }
    }
    
    // Initialize from mesh service data
    init(
        id: String,
        noisePublicKey: Data,
        nickname: String,
        lastSeen: Date = Date(),
        isConnected: Bool = false,
        isRelayConnected: Bool = false
    ) {
        self.id = id
        self.noisePublicKey = noisePublicKey
        self.nickname = nickname
        self.lastSeen = lastSeen
        self.isConnected = isConnected
        self.isRelayConnected = isRelayConnected
        
        // Load favorite status - will be set later by the manager
        self.favoriteStatus = nil
        self.nostrPublicKey = nil
    }
    
    static func == (lhs: BitchatPeer, rhs: BitchatPeer) -> Bool {
        lhs.id == rhs.id
    }
}

