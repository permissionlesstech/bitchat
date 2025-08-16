//
// PeerStateManager.swift
// bitchat
//
// Manages peer states, favorites, and blocked users
// This is free and unencumbered software released into the public domain.
//

import Foundation
import SwiftUI

/// Manages all peer-related state
class PeerStateManager: ObservableObject {
    @Published var connectedPeers: [String] = []
    @Published var allPeers: [BitchatPeer] = []
    @Published var favorites: Set<String> = []  // Fingerprints
    @Published var blocked: Set<String> = []    // Fingerprints
    
    private var peerIndex: [String: BitchatPeer] = [:]
    private var peerIDToFingerprint: [String: String] = [:]
    
    weak var meshService: SimplifiedBluetoothService?
    
    init(meshService: SimplifiedBluetoothService? = nil) {
        self.meshService = meshService
        loadFavorites()
        loadBlocked()
    }
    
    // MARK: - Peer Management
    
    /// Update peer list
    func updatePeers(_ peers: [BitchatPeer]) {
        allPeers = peers
        
        // Build index for fast lookups
        var uniquePeers: [String: BitchatPeer] = [:]
        for peer in peers {
            if uniquePeers[peer.id] == nil {
                uniquePeers[peer.id] = peer
            }
        }
        peerIndex = uniquePeers
        
        // Update connected peers
        connectedPeers = peers.filter { $0.isConnected }.map { $0.id }
        
        // Update fingerprint mappings
        for peer in peers {
            if let fingerprint = meshService?.getPeerFingerprint(peer.id) {
                peerIDToFingerprint[peer.id] = fingerprint
            }
        }
    }
    
    /// Get peer by ID
    func getPeer(by id: String) -> BitchatPeer? {
        return peerIndex[id]
    }
    
    /// Get peer ID for nickname
    func getPeerID(for nickname: String) -> String? {
        for peer in allPeers {
            if peer.displayName == nickname || peer.nickname == nickname {
                return peer.id
            }
        }
        return nil
    }
    
    /// Check if peer is online
    func isOnline(_ peerID: String) -> Bool {
        return connectedPeers.contains(peerID)
    }
    
    // MARK: - Favorites Management
    
    /// Toggle favorite status
    func toggleFavorite(_ peerID: String) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }
        
        if favorites.contains(fingerprint) {
            favorites.remove(fingerprint)
            updateSocialIdentity(fingerprint: fingerprint, isFavorite: false)
        } else {
            favorites.insert(fingerprint)
            blocked.remove(fingerprint)  // Can't be both favorite and blocked
            updateSocialIdentity(fingerprint: fingerprint, isFavorite: true)
        }
        
        saveFavorites()
    }
    
    /// Check if peer is favorite
    func isFavorite(_ peerID: String) -> Bool {
        guard let fingerprint = getFingerprint(for: peerID) else { return false }
        return favorites.contains(fingerprint)
    }
    
    // MARK: - Blocked Management
    
    /// Toggle blocked status
    func toggleBlocked(_ peerID: String) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }
        
        if blocked.contains(fingerprint) {
            blocked.remove(fingerprint)
            updateSocialIdentity(fingerprint: fingerprint, isBlocked: false)
        } else {
            blocked.insert(fingerprint)
            favorites.remove(fingerprint)  // Can't be both favorite and blocked
            updateSocialIdentity(fingerprint: fingerprint, isBlocked: true)
        }
        
        saveBlocked()
    }
    
    /// Check if peer is blocked
    func isBlocked(_ peerID: String) -> Bool {
        guard let fingerprint = getFingerprint(for: peerID) else { return false }
        return blocked.contains(fingerprint)
    }
    
    // MARK: - Fingerprint Management
    
    /// Get fingerprint for peer ID
    func getFingerprint(for peerID: String) -> String? {
        if let cached = peerIDToFingerprint[peerID] {
            return cached
        }
        
        if let fingerprint = meshService?.getPeerFingerprint(peerID) {
            peerIDToFingerprint[peerID] = fingerprint
            return fingerprint
        }
        
        return nil
    }
    
    // MARK: - Private Methods
    
    private func updateSocialIdentity(fingerprint: String, isFavorite: Bool? = nil, isBlocked: Bool? = nil) {
        if var identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprint) {
            if let isFavorite = isFavorite {
                identity.isFavorite = isFavorite
            }
            if let isBlocked = isBlocked {
                identity.isBlocked = isBlocked
            }
            SecureIdentityStateManager.shared.updateSocialIdentity(identity)
        } else {
            let nickname = allPeers.first { peer in
                getFingerprint(for: peer.id) == fingerprint
            }?.displayName ?? "Unknown"
            
            let identity = SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: nickname,
                trustLevel: .unknown,
                isFavorite: isFavorite ?? false,
                isBlocked: isBlocked ?? false,
                notes: nil
            )
            SecureIdentityStateManager.shared.updateSocialIdentity(identity)
        }
    }
    
    private func loadFavorites() {
        let identities = SecureIdentityStateManager.shared.getAllSocialIdentities()
        favorites = Set(identities.filter { $0.isFavorite }.map { $0.fingerprint })
    }
    
    private func saveFavorites() {
        // Handled by SecureIdentityStateManager
    }
    
    private func loadBlocked() {
        let identities = SecureIdentityStateManager.shared.getAllSocialIdentities()
        blocked = Set(identities.filter { $0.isBlocked }.map { $0.fingerprint })
    }
    
    private func saveBlocked() {
        // Handled by SecureIdentityStateManager
    }
}