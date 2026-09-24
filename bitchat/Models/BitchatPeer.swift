import Foundation
import CoreBluetooth
import BitFoundation

/// Represents a peer in the BitChat network with all associated metadata
struct BitchatPeer: Equatable {
    let peerID: PeerID // Hex-encoded peer ID
    let noisePublicKey: Data
    let nickname: String
    let isConnected: Bool
    let isReachable: Bool
    
    // Favorite-related properties
    var favoriteStatus: FavoritesPersistenceService.FavoriteRelationship?
    
    // Nostr identity (if known)
    var nostrPublicKey: String?

    /// Device-local alias (petname). Never sent over the wire; when set it
    /// outranks the peer-claimed `nickname` for display only.
    var localPetname: String?
    
    // Connection state
    enum ConnectionState {
        case bluetoothConnected
        case meshReachable      // Seen via mesh recently, not directly connected
        case nostrAvailable     // Mutual favorite, reachable via Nostr
        case offline            // Not connected via any transport
    }
    
    var connectionState: ConnectionState {
        if isConnected {
            return .bluetoothConnected
        } else if isReachable {
            return .meshReachable
        } else if favoriteStatus?.isMutual == true, reachableNostrPublicKey != nil {
            // Mutual favorites can communicate via Nostr when offline — but
            // only with a stored recipient key. NostrTransport applies the
            // same rule when computing reachable peers; without a key,
            // "available" would be a lie, and the DM header's
            // "end-to-end encrypted" caption keys off this state.
            return .nostrAvailable
        } else {
            return .offline
        }
    }

    /// The Nostr key a private envelope would actually be sealed to, if any.
    var reachableNostrPublicKey: String? {
        nostrPublicKey ?? favoriteStatus?.peerNostrPublicKey
    }
    
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
        if let localPetname, !localPetname.isEmpty {
            return localPetname
        }
        return nickname.isEmpty ? String(peerID.id.prefix(8)) : nickname
    }
    
    var statusIcon: String {
        switch connectionState {
        case .bluetoothConnected:
            return "📻" // Radio icon for mesh connection
        case .meshReachable:
            return "📡" // Antenna for mesh reachable
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
        peerID: PeerID,
        noisePublicKey: Data,
        nickname: String,
        lastSeen _: Date = Date(),
        isConnected: Bool = false,
        isReachable: Bool = false,
        localPetname: String? = nil
    ) {
        self.peerID = peerID
        self.noisePublicKey = noisePublicKey
        self.nickname = nickname
        self.isConnected = isConnected
        self.isReachable = isReachable
        self.localPetname = localPetname
        
        // Load favorite status - will be set later by the manager
        self.favoriteStatus = nil
        self.nostrPublicKey = nil
    }
    
    static func == (lhs: BitchatPeer, rhs: BitchatPeer) -> Bool {
        lhs.peerID == rhs.peerID
    }
}
