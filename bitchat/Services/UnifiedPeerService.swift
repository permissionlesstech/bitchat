//
//  UnifiedPeerService.swift
//  bitchat
//
//  Unified peer state management combining mesh connectivity and favorites
//  This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation
import Combine
import SwiftUI
import CryptoKit

/// Single source of truth for peer state, combining mesh connectivity and favorites
@MainActor
final class UnifiedPeerService: ObservableObject, TransportPeerEventsDelegate {
    
    // MARK: - Published Properties
    
    @Published private(set) var bitchatPeers: [BitchatPeer] = []
    @Published private(set) var connectedPeers: Set<Peer> = []
    @Published private(set) var favorites: [BitchatPeer] = []
    @Published private(set) var mutualFavorites: [BitchatPeer] = []
    
    // MARK: - Private Properties
    
    private var bitchatPeerIndex: [Peer: BitchatPeer] = [:]
    private var fingerprintCache: [Peer: String] = [:]
    private let meshService: Transport
    private let identityManager: SecureIdentityStateManagerProtocol
    weak var messageRouter: MessageRouter?
    private let favoritesService = FavoritesPersistenceService.shared
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init(meshService: Transport, identityManager: SecureIdentityStateManagerProtocol) {
        self.meshService = meshService
        self.identityManager = identityManager
        
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
        
        var enrichedBitchatPeers: [BitchatPeer] = []
        var connected: Set<Peer> = []
        var addedPeers: Set<Peer> = []
        
        // Phase 1: Add all mesh peers (connected and reachable)
        for peerInfo in meshPeers {
            let peer = Peer(str: peerInfo.id)
            guard peer != meshService.myPeer else { continue }  // Never add self
            
            let bitchatPeer = buildPeerFromMesh(
                peerInfo: peerInfo,
                favorites: favorites,
                meshAttached: hasAnyConnected
            )
            
            enrichedBitchatPeers.append(bitchatPeer)
            if bitchatPeer.isConnected { connected.insert(peer) }
            addedPeers.insert(peer)
            
            // Update fingerprint cache
            if let publicKey = peerInfo.noisePublicKey {
                fingerprintCache[peer] = publicKey.sha256Fingerprint()
            }
        }
        
        // Phase 2: Add offline favorites that we actively favorite
        for (favoriteKey, favorite) in favorites where favorite.isFavorite {
            let peer = Peer(str: favoriteKey.hexEncodedString())
            
            // Skip if already added (connected peer)
            if addedPeers.contains(peer) { continue }
            
            // Skip if connected under different ID but same nickname
            let isConnectedByNickname = enrichedBitchatPeers.contains { 
                $0.nickname == favorite.peerNickname && $0.isConnected 
            }
            if isConnectedByNickname { continue }
            
            let bitchatPeer = buildPeerFromFavorite(favorite: favorite, peer: peer)
            enrichedBitchatPeers.append(bitchatPeer)
            addedPeers.insert(peer)
            
            // Update fingerprint cache
            fingerprintCache[peer] = favoriteKey.sha256Fingerprint()
        }
        
        // Phase 3: Sort peers
        enrichedBitchatPeers.sort { lhs, rhs in
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
        var newIndex: [Peer: BitchatPeer] = [:]
        
        for bitchatPeer in enrichedBitchatPeers {
            newIndex[Peer(str: bitchatPeer.id)] = bitchatPeer
            
            if bitchatPeer.isFavorite {
                favoritesList.append(bitchatPeer)
            }
            if bitchatPeer.isMutualFavorite {
                mutualsList.append(bitchatPeer)
            }
        }
        
        // Phase 5: Filter out offline non-mutual peers and update published properties
        let filtered = enrichedBitchatPeers.filter { p in
            p.isConnected || p.isReachable || p.isMutualFavorite
        }
        self.bitchatPeers = filtered
        self.connectedPeers = connected
        self.favorites = favoritesList
        self.mutualFavorites = mutualsList
        self.bitchatPeerIndex = newIndex
        
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
        let isVerified = fingerprint.map { identityManager.isVerified(fingerprint: $0) } ?? false
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
        }
        
        return peer
    }
    
    private func buildPeerFromFavorite(
        favorite: FavoritesPersistenceService.FavoriteRelationship,
        peer: Peer
    ) -> BitchatPeer {
        var peer = BitchatPeer(
            id: peer.id,
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
    
    func getBitchatPeer(for peer: Peer) -> BitchatPeer? {
        return bitchatPeerIndex[peer]
    }
    
    /// Get peer for nickname
    func getPeer(for nickname: String) -> Peer? {
        for bitchatPeer in bitchatPeers where bitchatPeer.displayName == nickname || bitchatPeer.nickname == nickname {
            return Peer(str: bitchatPeer.id)
        }
        return nil
    }
    
    /// Check if peer is online
    func isOnline(_ peer: Peer) -> Bool {
        return connectedPeers.contains(peer)
    }
    
    /// Check if peer is blocked
    func isBlocked(_ peer: Peer) -> Bool {
        // Get fingerprint
        guard let fingerprint = getFingerprint(for: peer) else { return false }
        
        // Check SecureIdentityStateManager for block status
        if let identity = identityManager.getSocialIdentity(for: fingerprint) {
            return identity.isBlocked
        }
        
        return false
    }
    
    /// Toggle favorite status
    func toggleFavorite(_ peer: Peer) {
        guard let bitchatPeer = getBitchatPeer(for: peer) else {
            SecureLogger.warning("⚠️ Cannot toggle favorite - peer not found: \(peer.id)", category: .session)
            return
        }
        
        let wasFavorite = bitchatPeer.isFavorite
        
        // Get the actual nickname for logging and saving
        var actualNickname = bitchatPeer.nickname
        
        // Debug logging to understand the issue
        SecureLogger.debug("🔍 Toggle favorite - peer.nickname: '\(bitchatPeer.nickname)', peer.displayName: '\(bitchatPeer.displayName)', peerID: \(peer.id)", category: .session)
        
        if actualNickname.isEmpty {
            // Try to get from mesh service's current peer list
            if let meshPeerNickname = meshService.peerNickname(peer: peer) {
                actualNickname = meshPeerNickname
                SecureLogger.debug("🔍 Got nickname from mesh service: '\(actualNickname)'", category: .session)
            }
        }
        
        // Use displayName as fallback (which shows ID prefix if nickname is empty)
        let finalNickname = actualNickname.isEmpty ? bitchatPeer.displayName : actualNickname
        
        if wasFavorite {
            // Remove favorite
            favoritesService.removeFavorite(peerNoisePublicKey: bitchatPeer.noisePublicKey)
        } else {
            // Get or derive peer's Nostr public key if not already known
            var peerNostrKey = bitchatPeer.nostrPublicKey
            if peerNostrKey == nil {
                // Try to get from NostrIdentityBridge association
                peerNostrKey = NostrIdentityBridge.getNostrPublicKey(for: bitchatPeer.noisePublicKey)
            }
            
            // Add favorite
            favoritesService.addFavorite(
                peerNoisePublicKey: bitchatPeer.noisePublicKey,
                peerNostrPublicKey: peerNostrKey,
                peerNickname: finalNickname
            )
        }
        
        // Log the final nickname being saved
        SecureLogger.debug("⭐️ Toggled favorite for '\(finalNickname)' (peerID: \(peer.id), was: \(wasFavorite), now: \(!wasFavorite))", category: .session)
        
        // Send favorite notification to the peer via router (mesh or Nostr)
        if let router = messageRouter {
            router.sendFavoriteNotification(to: peer, isFavorite: !wasFavorite)
        } else {
            // Fallback to mesh-only if router not yet wired
            meshService.sendFavoriteNotification(to: peer, isFavorite: !wasFavorite)
        }
        
        // Force update of peers to reflect the change
        updatePeers()
        
        // Force UI update by notifying SwiftUI directly
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    /// Toggle blocked status
    func toggleBlocked(_ peer: Peer) {
        guard let fingerprint = getFingerprint(for: peer) else { return }
        
        // Get or create social identity
        var identity = identityManager.getSocialIdentity(for: fingerprint)
            ?? SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: getBitchatPeer(for: peer)?.displayName ?? "Unknown",
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
            if let bitchatPeer = getBitchatPeer(for: peer) {
                favoritesService.removeFavorite(peerNoisePublicKey: bitchatPeer.noisePublicKey)
            }
        }
        
        identityManager.updateSocialIdentity(identity)
    }
    
    /// Get fingerprint for peer ID
    func getFingerprint(for peer: Peer) -> String? {
        // Check cache first
        if let cached = fingerprintCache[peer] {
            return cached
        }
        
        // Try to get from mesh service
        if let fingerprint = meshService.getFingerprint(for: peer) {
            fingerprintCache[peer] = fingerprint
            return fingerprint
        }
        
        // Try to get from peer's public key
        if let bitchatPeer = getBitchatPeer(for: peer) {
            let fingerprint = bitchatPeer.noisePublicKey.sha256Fingerprint()
            fingerprintCache[Peer(str: bitchatPeer.id)] = fingerprint
            return fingerprint
        }
        
        return nil
    }
    
    // MARK: - Compatibility Methods (for easy migration)
    
    var favoritePeers: Set<String> { 
        Set(favorites.compactMap { getFingerprint(for: Peer(str: $0.id)) })
    }
    var blockedUsers: Set<String> {
        Set(bitchatPeers.compactMap { batchPeer in
            isBlocked(Peer(str: batchPeer.id)) ? getFingerprint(for: Peer(str: batchPeer.id)) : nil
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
