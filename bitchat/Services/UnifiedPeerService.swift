//
//  UnifiedPeerService.swift
//  bitchat
//
//  Unified peer state management combining mesh connectivity and favorites
//  This is free and unencumbered software released into the public domain.
//

import Foundation
import Combine
import SwiftUI
import CryptoKit

/// Single source of truth for peer state, combining mesh connectivity and favorites
@MainActor
class UnifiedPeerService: ObservableObject, TransportPeerEventsDelegate {
    
    // MARK: - Published Properties
    
    @Published private(set) var peers: [BitchatPeer] = []
    @Published private(set) var connectedPeerIDs: Set<String> = []
    @Published private(set) var favorites: [BitchatPeer] = []
    @Published private(set) var mutualFavorites: [BitchatPeer] = []
    
    // MARK: - Private Properties
    
    private var peerIndex: [String: BitchatPeer] = [:]
    private var fingerprintCache: [String: String] = [:]  // peerID -> fingerprint
    private let meshService: Transport
    weak var messageRouter: MessageRouter?
    private let favoritesService = FavoritesPersistenceService.shared
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init(meshService: Transport) {
        self.meshService = meshService
        
        // Subscribe to changes from both services
        setupSubscriptions()
        
        // Perform initial update
        Task { @MainActor in
            updatePeers()
        }
    }
    
    // MARK: - Setup
    
    private func setupSubscriptions() {
        // Subscribe to mesh peer updates via delegate (preferred over publishers)
        meshService.peerEventsDelegate = self
        
        // Also listen for favorite change notifications
        NotificationCenter.default.publisher(for: .favoriteStatusChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePeers()
            }
            .store(in: &cancellables)
    }

    // TransportPeerEventsDelegate
    func didUpdatePeerSnapshots(_ peers: [TransportPeerSnapshot]) {
        updatePeers()
    }
    
    // MARK: - Core Update Logic
    
    private func updatePeers() {
        let meshPeers = meshService.currentPeerSnapshots()
        // If we have no direct links at all, peers should not be marked reachable
        // "Reachable" means mesh-attached via at least one live link.
        let hasAnyConnected = meshPeers.contains { $0.isConnected }
        let favorites = favoritesService.favorites
        
        var enrichedPeers: [BitchatPeer] = []
        var connected: Set<String> = []
        var addedPeerIDs: Set<String> = []
        
        // Phase 1: Add all mesh peers (connected and reachable)
        for peerInfo in meshPeers {
            let peerID = peerInfo.id
            guard peerID != meshService.myPeerID else { continue }  // Never add self
            
            let peer = buildPeerFromMesh(
                peerInfo: peerInfo,
                favorites: favorites,
                meshAttached: hasAnyConnected
            )
            
            enrichedPeers.append(peer)
            if peer.isConnected { connected.insert(peerID) }
            addedPeerIDs.insert(peerID)
            
            // Update fingerprint cache
            if let publicKey = peerInfo.noisePublicKey {
                fingerprintCache[peerID] = publicKey.sha256Fingerprint()
            }
        }
        
        // Phase 2: Add offline favorites that we actively favorite
        for (favoriteKey, favorite) in favorites where favorite.isFavorite {
            let peerID = favoriteKey.hexEncodedString()
            
            // Skip if already added (connected peer)
            if addedPeerIDs.contains(peerID) { continue }
            
            // Skip if connected under different ID but same nickname
            let isConnectedByNickname = enrichedPeers.contains { 
                $0.nickname == favorite.peerNickname && $0.isConnected 
            }
            if isConnectedByNickname { continue }
            
            let peer = buildPeerFromFavorite(favorite: favorite, peerID: peerID)
            enrichedPeers.append(peer)
            addedPeerIDs.insert(peerID)
            
            // Update fingerprint cache
            fingerprintCache[peerID] = favoriteKey.sha256Fingerprint()
        }
        
        // Phase 3: Sort peers
        enrichedPeers.sort { lhs, rhs in
            // Connectivity rank: connected > reachable > others
            func rank(_ p: BitchatPeer) -> Int { p.isConnected ? 2 : (p.isReachable ? 1 : 0) }
            let lr = rank(lhs), rr = rank(rhs)
            if lr != rr { return lr > rr }
            // Then favorites inside same rank
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            // Finally alphabetical
            return lhs.displayName < rhs.displayName
        }
        
        // Phase 4: Build subsets and indices
        var favoritesList: [BitchatPeer] = []
        var mutualsList: [BitchatPeer] = []
        var newIndex: [String: BitchatPeer] = [:]
        
        for peer in enrichedPeers {
            newIndex[peer.id] = peer
            
            if peer.isFavorite {
                favoritesList.append(peer)
            }
            if peer.isMutualFavorite {
                mutualsList.append(peer)
            }
        }
        
        // Phase 5: Filter out offline non-mutual peers and update published properties
        let filtered = enrichedPeers.filter { p in
            p.isConnected || p.isReachable || p.isMutualFavorite
        }
        self.peers = filtered
        self.connectedPeerIDs = connected
        self.favorites = favoritesList
        self.mutualFavorites = mutualsList
        self.peerIndex = newIndex
        
        // Log summary (commented out to reduce noise)
        // let connectedCount = connected.count
        // let offlineCount = enrichedPeers.count - connectedCount
        // Peer update: \(enrichedPeers.count) total (\(connectedCount) connected, \(offlineCount) offline)
    }
    
    // MARK: - Peer Building Helpers
    
    private func buildPeerFromMesh(
        peerInfo: TransportPeerSnapshot,
        favorites: [Data: FavoritesPersistenceService.FavoriteRelationship],
        meshAttached: Bool
    ) -> BitchatPeer {
        // Determine reachability based on lastSeen and identity trust
        let now = Date()
        let fingerprint = peerInfo.noisePublicKey?.sha256Fingerprint()
        let isVerified = fingerprint.map { SecureIdentityStateManager.shared.isVerified(fingerprint: $0) } ?? false
        let isFav = peerInfo.noisePublicKey.flatMap { favorites[$0]?.isFavorite } ?? false
        let retention: TimeInterval = (isVerified || isFav) ? TransportConfig.bleReachabilityRetentionVerifiedSeconds : TransportConfig.bleReachabilityRetentionUnverifiedSeconds
        // A peer is reachable if we recently saw them AND we are attached to the mesh
        let withinRetention = now.timeIntervalSince(peerInfo.lastSeen) <= retention
        let isReachable = peerInfo.isConnected ? true : (withinRetention && meshAttached)

        var peer = BitchatPeer(
            id: peerInfo.id,
            noisePublicKey: peerInfo.noisePublicKey ?? Data(),
            nickname: peerInfo.nickname,
            lastSeen: peerInfo.lastSeen,
            isConnected: peerInfo.isConnected,
            isReachable: isReachable
        )
        
        // Check for favorite status
        if let noiseKey = peerInfo.noisePublicKey,
           let favoriteStatus = favorites[noiseKey] {
            peer.favoriteStatus = favoriteStatus
            peer.nostrPublicKey = favoriteStatus.peerNostrPublicKey
        } else {
            // Check by nickname for reconnected peers
            let favoriteByNickname = favorites.values.first { 
                $0.peerNickname == peerInfo.nickname 
            }
            
            if let favorite = favoriteByNickname,
               let noiseKey = peerInfo.noisePublicKey {
                SecureLogger.log(
                    "🔄 Found favorite for '\(peerInfo.nickname)' by nickname, updating noise key",
                    category: SecureLogger.session,
                    level: .debug
                )
                
                // Update the favorite's key in persistence
                favoritesService.updateNoisePublicKey(
                    from: favorite.peerNoisePublicKey,
                    to: noiseKey,
                    peerNickname: peerInfo.nickname
                )
                
                // Get updated favorite
                peer.favoriteStatus = favoritesService.getFavoriteStatus(for: noiseKey)
                peer.nostrPublicKey = peer.favoriteStatus?.peerNostrPublicKey ?? favorite.peerNostrPublicKey
            }
        }
        
        return peer
    }
    
    private func buildPeerFromFavorite(
        favorite: FavoritesPersistenceService.FavoriteRelationship,
        peerID: String
    ) -> BitchatPeer {
        var peer = BitchatPeer(
            id: peerID,
            noisePublicKey: favorite.peerNoisePublicKey,
            nickname: favorite.peerNickname,
            lastSeen: favorite.lastUpdated,
            isConnected: false,
            isReachable: false
        )
        
        peer.favoriteStatus = favorite
        peer.nostrPublicKey = favorite.peerNostrPublicKey
        
        return peer
    }
    
    // MARK: - Public Methods
    
    /// Get peer by ID
    func getPeer(by id: String) -> BitchatPeer? {
        return peerIndex[id]
    }
    
    /// Get peer ID for nickname
    func getPeerID(for nickname: String) -> String? {
        for peer in peers {
            if peer.displayName == nickname || peer.nickname == nickname {
                return peer.id
            }
        }
        return nil
    }
    
    /// Check if peer is online
    func isOnline(_ peerID: String) -> Bool {
        return connectedPeerIDs.contains(peerID)
    }
    
    /// Check if peer is blocked
    func isBlocked(_ peerID: String) -> Bool {
        // Get fingerprint
        guard let fingerprint = getFingerprint(for: peerID) else { return false }
        
        // Check SecureIdentityStateManager for block status
        if let identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprint) {
            return identity.isBlocked
        }
        
        return false
    }
    
    /// Toggle favorite status
    func toggleFavorite(_ peerID: String) {
        guard let peer = getPeer(by: peerID) else { 
            SecureLogger.log("⚠️ Cannot toggle favorite - peer not found: \(peerID)", 
                           category: SecureLogger.session, level: .warning)
            return 
        }
        
        let wasFavorite = peer.isFavorite
        
        // Get the actual nickname for logging and saving
        var actualNickname = peer.nickname
        
        // Debug logging to understand the issue
        SecureLogger.log("🔍 Toggle favorite - peer.nickname: '\(peer.nickname)', peer.displayName: '\(peer.displayName)', peerID: \(peerID)", 
                       category: SecureLogger.session, level: .debug)
        
        if actualNickname.isEmpty {
            // Try to get from mesh service's current peer list
            if let meshPeerNickname = meshService.peerNickname(peerID: peerID) {
                actualNickname = meshPeerNickname
                SecureLogger.log("🔍 Got nickname from mesh service: '\(actualNickname)'", 
                               category: SecureLogger.session, level: .debug)
            }
        }
        
        // Use displayName as fallback (which shows ID prefix if nickname is empty)
        let finalNickname = actualNickname.isEmpty ? peer.displayName : actualNickname
        
        if wasFavorite {
            // Remove favorite
            favoritesService.removeFavorite(peerNoisePublicKey: peer.noisePublicKey)
        } else {
            // Get or derive peer's Nostr public key if not already known
            var peerNostrKey = peer.nostrPublicKey
            if peerNostrKey == nil {
                // Try to get from NostrIdentityBridge association
                peerNostrKey = NostrIdentityBridge.getNostrPublicKey(for: peer.noisePublicKey)
            }
            
            // Add favorite
            favoritesService.addFavorite(
                peerNoisePublicKey: peer.noisePublicKey,
                peerNostrPublicKey: peerNostrKey,
                peerNickname: finalNickname
            )
        }
        
        // Log the final nickname being saved
        SecureLogger.log("⭐️ Toggled favorite for '\(finalNickname)' (peerID: \(peerID), was: \(wasFavorite), now: \(!wasFavorite))",
                       category: SecureLogger.session, level: .debug)
        
        // Send favorite notification to the peer via router (mesh or Nostr)
        if let router = messageRouter {
            router.sendFavoriteNotification(to: peerID, isFavorite: !wasFavorite)
        } else {
            // Fallback to mesh-only if router not yet wired
            meshService.sendFavoriteNotification(to: peerID, isFavorite: !wasFavorite)
        }
        
        // Force update of peers to reflect the change
        updatePeers()
        
        // Force UI update by notifying SwiftUI directly
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    /// Toggle blocked status
    func toggleBlocked(_ peerID: String) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }
        
        // Get or create social identity
        var identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprint)
            ?? SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: getPeer(by: peerID)?.displayName ?? "Unknown",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        
        // Toggle blocked status
        identity.isBlocked = !identity.isBlocked
        
        // Can't be both favorite and blocked
        if identity.isBlocked {
            identity.isFavorite = false
            // Also remove from favorites service
            if let peer = getPeer(by: peerID) {
                favoritesService.removeFavorite(peerNoisePublicKey: peer.noisePublicKey)
            }
        }
        
        SecureIdentityStateManager.shared.updateSocialIdentity(identity)
    }
    
    /// Get fingerprint for peer ID
    func getFingerprint(for peerID: String) -> String? {
        // Check cache first
        if let cached = fingerprintCache[peerID] {
            return cached
        }
        
        // Try to get from mesh service
        if let fingerprint = meshService.getFingerprint(for: peerID) {
            fingerprintCache[peerID] = fingerprint
            return fingerprint
        }
        
        // Try to get from peer's public key
        if let peer = getPeer(by: peerID) {
            let fingerprint = peer.noisePublicKey.sha256Fingerprint()
            fingerprintCache[peerID] = fingerprint
            return fingerprint
        }
        
        return nil
    }
    
    // MARK: - Compatibility Methods (for easy migration)
    
    var allPeers: [BitchatPeer] { peers }
    var connectedPeers: [String] { Array(connectedPeerIDs) }
    var favoritePeers: Set<String> { 
        Set(favorites.compactMap { getFingerprint(for: $0.id) })
    }
    var blockedUsers: Set<String> {
        Set(peers.compactMap { peer in
            isBlocked(peer.id) ? getFingerprint(for: peer.id) : nil
        })
    }
}

// MARK: - Helper Extensions

extension Data {
    func sha256Fingerprint() -> String {
        // Implementation matches existing fingerprint generation in NoiseEncryptionService
        let hash = SHA256.hash(data: self)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
