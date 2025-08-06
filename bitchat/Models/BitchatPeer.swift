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

// MARK: - Peer Manager

/// Manages the collection of peers and their states
@MainActor
class PeerManager: ObservableObject {
    @Published var peers: [BitchatPeer] = []
    @Published var favorites: [BitchatPeer] = []
    @Published var mutualFavorites: [BitchatPeer] = []
    
    private let meshService: BluetoothMeshService
    private let favoritesService = FavoritesPersistenceService.shared
    
    init(meshService: BluetoothMeshService) {
        self.meshService = meshService
        updatePeers()
        
        // Listen for updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFavoriteChanged),
            name: .favoriteStatusChanged,
            object: nil
        )
    }
    
    @objc private func handleFavoriteChanged() {
        SecureLogger.log("⭐ Favorite status changed notification received, updating peers", 
                        category: SecureLogger.session, level: .debug)
        updatePeers()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func updatePeers() {
        // Reduce log verbosity - only log when count changes
        let previousCount = peers.count
        
        // Get current mesh peers
        let meshPeers = meshService.getPeerNicknames()
        
        // Build peer list
        var allPeers: [BitchatPeer] = []
        var connectedNicknames: Set<String> = []
        var addedPeerIDs: Set<String> = []
        
        // Add connected mesh peers (only if actually connected or relay connected)
        for (peerID, nickname) in meshPeers {
            guard let noiseKey = Data(hexString: peerID) else { continue }
            
            // Safety check: Never add our own peer ID
            if peerID == meshService.myPeerID {
                SecureLogger.log("⚠️ Skipping self peer ID \(peerID) in peer list", 
                               category: SecureLogger.session, level: .warning)
                continue
            }
            
            // Check if this peer is actually connected (not just known via relay)
            let isConnected = meshService.isPeerConnected(peerID)
            let isKnown = meshService.isPeerKnown(peerID)
            // In a mesh network, a peer can only be relay-connected if:
            // 1. We know about them (have received announce)
            // 2. We're not directly connected
            // 3. There are other peers that could relay (mesh peer count > 2)
            // For now, disable relay detection until we have proper relay tracking
            let isRelayConnected = false
            
            // Debug logging for relay connection detection
            if isKnown && !isConnected {
                SecureLogger.log("Peer \(nickname) (\(peerID)): isConnected=\(isConnected), isKnown=\(isKnown), isRelayConnected=\(isRelayConnected)", 
                               category: SecureLogger.session, level: .debug)
            }
            
            // Skip disconnected peers unless they're favorites (handled later)
            if !isConnected && !isRelayConnected {
                continue
            }
            
            if isConnected || isRelayConnected {
                connectedNicknames.insert(nickname)
            }
            
            // Track that we've added this peer ID
            addedPeerIDs.insert(peerID)
            
            var peer = BitchatPeer(
                id: peerID,
                noisePublicKey: noiseKey,
                nickname: nickname,
                isConnected: isConnected,
                isRelayConnected: isRelayConnected
            )
            // Set favorite status - check both by current noise key and by nickname
            if let favoriteStatus = favoritesService.getFavoriteStatus(for: noiseKey) {
                peer.favoriteStatus = favoriteStatus
                peer.nostrPublicKey = favoriteStatus.peerNostrPublicKey
            } else {
                // Check if we have a favorite for this nickname (peer may have reconnected with new ID)
                let favoriteByNickname = favoritesService.favorites.values.first { $0.peerNickname == nickname }
                if let favorite = favoriteByNickname {
                    SecureLogger.log("🔄 Found favorite for '\(nickname)' by nickname, updating noise key", 
                                    category: SecureLogger.session, level: .info)
                    // Update the favorite's noise key to match the current connection
                    favoritesService.updateNoisePublicKey(from: favorite.peerNoisePublicKey, to: noiseKey, peerNickname: nickname)
                    // Get the updated favorite with the new key
                    peer.favoriteStatus = favoritesService.getFavoriteStatus(for: noiseKey)
                    peer.nostrPublicKey = peer.favoriteStatus?.peerNostrPublicKey ?? favorite.peerNostrPublicKey
                }
            }
            allPeers.append(peer)
        }
        
        // Add offline favorites (only those not currently connected/relay-connected AND that we actively favorite)
        SecureLogger.log("📋 Processing \(favoritesService.favorites.count) favorite relationships (connected/relay nicknames: \(connectedNicknames))", 
                        category: SecureLogger.session, level: .info)
        
        for (favoriteKey, favorite) in favoritesService.favorites {
            let favoriteID = favorite.peerNoisePublicKey.hexEncodedString()
            
            // Skip if this peer is already connected or relay-connected (by nickname)
            if connectedNicknames.contains(favorite.peerNickname) {
                SecureLogger.log("  - Skipping '\(favorite.peerNickname)' (key: \(favoriteKey.hexEncodedString())) - already connected/relay-connected", 
                                category: SecureLogger.session, level: .debug)
                continue
            }
            
            // Skip if we already added a peer with this ID (prevents duplicates)
            if addedPeerIDs.contains(favoriteID) {
                SecureLogger.log("  - Skipping '\(favorite.peerNickname)' - peer ID already added", 
                                category: SecureLogger.session, level: .debug)
                continue
            }
            
            // Only add peers that WE favorite (not just ones who favorite us)
            if !favorite.isFavorite {
                SecureLogger.log("  - Skipping '\(favorite.peerNickname)' - we don't favorite them (they favorite us: \(favorite.theyFavoritedUs))", 
                                category: SecureLogger.session, level: .debug)
                continue
            }
            
            // Add this favorite as an offline peer
            SecureLogger.log("  - Adding offline favorite '\(favorite.peerNickname)' (key: \(favoriteKey.hexEncodedString()), ID: \(favoriteID), mutual: \(favorite.isMutual))", 
                            category: SecureLogger.session, level: .info)
            
            var peer = BitchatPeer(
                id: favoriteID,
                noisePublicKey: favorite.peerNoisePublicKey,
                nickname: favorite.peerNickname,
                isConnected: false
            )
            // Set favorite status
            peer.favoriteStatus = favorite
            peer.nostrPublicKey = favorite.peerNostrPublicKey
            addedPeerIDs.insert(favoriteID)  // Track that we've added this ID
            allPeers.append(peer)
        }
        
        // Filter out "Unknown" peers unless they are favorites or have a favorite relationship
        allPeers = allPeers.filter { peer in
            !(peer.displayName == "Unknown" && peer.favoriteStatus == nil)
        }
        
        // Sort: Connected first (direct then relay), then favorites, then alphabetical
        allPeers.sort { lhs, rhs in
            // Direct connections first
            if lhs.isConnected != rhs.isConnected {
                return lhs.isConnected
            }
            // Then relay connections
            if lhs.isRelayConnected != rhs.isRelayConnected {
                return lhs.isRelayConnected
            }
            // Then favorites
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite
            }
            // Finally alphabetical
            return lhs.displayName < rhs.displayName
        }
        
        // Single pass to compute all subsets and counts
        var favorites: [BitchatPeer] = []
        var mutualFavorites: [BitchatPeer] = []
        var connectedCount = 0
        var offlineCount = 0
        
        for peer in allPeers {
            if peer.isFavorite {
                favorites.append(peer)
            }
            if peer.isMutualFavorite {
                mutualFavorites.append(peer)
            }
            if peer.isConnected {
                connectedCount += 1
            } else {
                offlineCount += 1
            }
        }
        
        // Final safety check: ensure no duplicate IDs
        var finalPeers: [BitchatPeer] = []
        var seenIDs: Set<String> = []
        for peer in allPeers {
            if !seenIDs.contains(peer.id) {
                seenIDs.insert(peer.id)
                finalPeers.append(peer)
            } else {
                SecureLogger.log("⚠️ Removing duplicate peer ID in final check: \(peer.id) (\(peer.displayName))", 
                               category: SecureLogger.session, level: .warning)
            }
        }
        
        self.peers = finalPeers
        self.favorites = favorites
        self.mutualFavorites = mutualFavorites
        
        // Always log favorites debug info when there are favorites
        if favoritesService.favorites.count > 0 {
            SecureLogger.log("📊 Peer list update: \(allPeers.count) total (\(connectedCount) connected, \(offlineCount) offline), \(favorites.count) favorites, \(mutualFavorites.count) mutual", 
                            category: SecureLogger.session, level: .info)
            
            // Log each peer's status
            for peer in allPeers {
                // Use the actual statusIcon from the peer which accounts for relay connections
                let statusIcon: String
                switch peer.connectionState {
                case .bluetoothConnected:
                    statusIcon = "🟢"
                case .relayConnected:
                    statusIcon = "🔗"
                case .nostrAvailable:
                    statusIcon = "🌐"
                case .offline:
                    statusIcon = "🔴"
                }
                let favoriteIcon = peer.isMutualFavorite ? "💕" : (peer.isFavorite ? "⭐" : (peer.theyFavoritedUs ? "🌙" : ""))
                SecureLogger.log("  \(statusIcon) \(peer.displayName) (ID: \(peer.id.prefix(8))...) \(favoriteIcon)", 
                                category: SecureLogger.session, level: .debug)
            }
        } else if previousCount != allPeers.count {
            // Only log non-favorite updates if count changed
            SecureLogger.log("✅ Updated peer list: \(allPeers.count) total peers", 
                            category: SecureLogger.session, level: .info)
        }
    }
    
    func toggleFavorite(_ peer: BitchatPeer) {
        if peer.isFavorite {
            favoritesService.removeFavorite(peerNoisePublicKey: peer.noisePublicKey)
        } else {
            favoritesService.addFavorite(
                peerNoisePublicKey: peer.noisePublicKey,
                peerNostrPublicKey: peer.nostrPublicKey,
                peerNickname: peer.nickname
            )
        }
        updatePeers()
    }
}