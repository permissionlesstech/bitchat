//
// SecureIdentityStateManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

class SecureIdentityStateManager {
    static let shared = SecureIdentityStateManager()
    
    private let keychain = KeychainManager.shared
    private let cacheKey = "bitchat.identityCache.v2"
    private let encryptionKeyName = "identityCacheEncryptionKey"
    
    // In-memory state
    private var ephemeralSessions: [String: EphemeralIdentity] = [:]
    private var cryptographicIdentities: [String: CryptographicIdentity] = [:]
    private var cache: IdentityCache = IdentityCache()
    
    // Pending actions before handshake
    private var pendingActions: [String: PendingActions] = [:]
    
    // Thread safety
    private let queue = DispatchQueue(label: "bitchat.identity.state", attributes: .concurrent)
    
    // Encryption key
    private let encryptionKey: SymmetricKey
    
    private init() {
        // Generate or retrieve encryption key from keychain
        let loadedKey: SymmetricKey
        
        // Try to load from keychain
        if let keyData = keychain.getIdentityKey(forKey: encryptionKeyName) {
            loadedKey = SymmetricKey(data: keyData)
        }
        // Generate new key if needed
        else {
            loadedKey = SymmetricKey(size: .bits256)
            let keyData = loadedKey.withUnsafeBytes { Data($0) }
            // Save to keychain
            _ = keychain.saveIdentityKey(keyData, forKey: encryptionKeyName)
        }
        
        self.encryptionKey = loadedKey
        
        // Load identity cache on init
        loadIdentityCache()
    }
    
    // MARK: - Secure Loading/Saving
    
    func loadIdentityCache() {
        guard let encryptedData = keychain.getIdentityKey(forKey: cacheKey) else {
            // No existing cache, start fresh
            return
        }
        
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            let decryptedData = try AES.GCM.open(sealedBox, using: encryptionKey)
            cache = try JSONDecoder().decode(IdentityCache.self, from: decryptedData)
        } catch {
            // Log error but continue with empty cache
            SecurityLogger.log("Failed to load identity cache", category: SecurityLogger.security, level: .error)
        }
    }
    
    func saveIdentityCache() {
        do {
            let data = try JSONEncoder().encode(cache)
            let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
            _ = keychain.saveIdentityKey(sealedBox.combined!, forKey: cacheKey)
        } catch {
            SecurityLogger.log("Failed to save identity cache", category: SecurityLogger.security, level: .error)
        }
    }
    
    // MARK: - Identity Resolution
    
    func resolveIdentity(peerID: String, claimedNickname: String) -> IdentityHint {
        queue.sync {
            // Check if we have candidates based on nickname
            if let fingerprints = cache.nicknameIndex[claimedNickname] {
                if fingerprints.count == 1 {
                    return .likelyKnown(fingerprint: fingerprints.first!)
                } else {
                    return .ambiguous(candidates: fingerprints)
                }
            }
            return .unknown
        }
    }
    
    // MARK: - Social Identity Management
    
    func getSocialIdentity(for fingerprint: String) -> SocialIdentity? {
        queue.sync {
            return cache.socialIdentities[fingerprint]
        }
    }
    
    func getAllSocialIdentities() -> [SocialIdentity] {
        queue.sync {
            return Array(cache.socialIdentities.values)
        }
    }
    
    func updateSocialIdentity(_ identity: SocialIdentity) {
        queue.async(flags: .barrier) {
            self.cache.socialIdentities[identity.fingerprint] = identity
            
            // Update nickname index
            if let existingIdentity = self.cache.socialIdentities[identity.fingerprint] {
                // Remove old nickname from index if changed
                if existingIdentity.claimedNickname != identity.claimedNickname {
                    self.cache.nicknameIndex[existingIdentity.claimedNickname]?.remove(identity.fingerprint)
                    if self.cache.nicknameIndex[existingIdentity.claimedNickname]?.isEmpty == true {
                        self.cache.nicknameIndex.removeValue(forKey: existingIdentity.claimedNickname)
                    }
                }
            }
            
            // Add new nickname to index
            if self.cache.nicknameIndex[identity.claimedNickname] == nil {
                self.cache.nicknameIndex[identity.claimedNickname] = Set<String>()
            }
            self.cache.nicknameIndex[identity.claimedNickname]?.insert(identity.fingerprint)
            
            // Save to keychain
            self.saveIdentityCache()
        }
    }
    
    // MARK: - Favorites Management
    
    func getFavorites() -> Set<String> {
        queue.sync {
            let favorites = cache.socialIdentities.values
                .filter { $0.isFavorite }
                .map { $0.fingerprint }
            return Set(favorites)
        }
    }
    
    func setFavorite(_ fingerprint: String, isFavorite: Bool) {
        queue.async(flags: .barrier) {
            if var identity = self.cache.socialIdentities[fingerprint] {
                identity.isFavorite = isFavorite
                self.cache.socialIdentities[fingerprint] = identity
            } else {
                // Create new social identity for this fingerprint
                let newIdentity = SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: "Unknown",
                    trustLevel: .unknown,
                    isFavorite: isFavorite,
                    isBlocked: false,
                    notes: nil
                )
                self.cache.socialIdentities[fingerprint] = newIdentity
            }
            self.saveIdentityCache()
        }
    }
    
    func isFavorite(fingerprint: String) -> Bool {
        queue.sync {
            return cache.socialIdentities[fingerprint]?.isFavorite ?? false
        }
    }
    
    // MARK: - Blocked Users Management
    
    func isBlocked(fingerprint: String) -> Bool {
        queue.sync {
            return cache.socialIdentities[fingerprint]?.isBlocked ?? false
        }
    }
    
    func setBlocked(_ fingerprint: String, isBlocked: Bool) {
        queue.async(flags: .barrier) {
            if var identity = self.cache.socialIdentities[fingerprint] {
                identity.isBlocked = isBlocked
                if isBlocked {
                    identity.isFavorite = false  // Can't be both favorite and blocked
                }
                self.cache.socialIdentities[fingerprint] = identity
            } else {
                // Create new social identity for this fingerprint
                let newIdentity = SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: "Unknown",
                    trustLevel: .unknown,
                    isFavorite: false,
                    isBlocked: isBlocked,
                    notes: nil
                )
                self.cache.socialIdentities[fingerprint] = newIdentity
            }
            self.saveIdentityCache()
        }
    }
    
    // MARK: - Ephemeral Session Management
    
    func registerEphemeralSession(peerID: String, handshakeState: HandshakeState = .none) {
        queue.async(flags: .barrier) {
            self.ephemeralSessions[peerID] = EphemeralIdentity(
                peerID: peerID,
                sessionStart: Date(),
                handshakeState: handshakeState
            )
        }
    }
    
    func updateHandshakeState(peerID: String, state: HandshakeState) {
        queue.async(flags: .barrier) {
            self.ephemeralSessions[peerID]?.handshakeState = state
            
            // If handshake completed, update last interaction
            if case .completed(let fingerprint) = state {
                self.cache.lastInteractions[fingerprint] = Date()
                self.saveIdentityCache()
            }
        }
    }
    
    func getHandshakeState(peerID: String) -> HandshakeState? {
        queue.sync {
            return ephemeralSessions[peerID]?.handshakeState
        }
    }
    
    // MARK: - Pending Actions
    
    func setPendingAction(peerID: String, action: PendingActions) {
        queue.async(flags: .barrier) {
            self.pendingActions[peerID] = action
        }
    }
    
    func applyPendingActions(peerID: String, fingerprint: String) {
        queue.async(flags: .barrier) {
            guard let actions = self.pendingActions[peerID] else { return }
            
            // Get or create social identity
            var identity = self.cache.socialIdentities[fingerprint] ?? SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: "Unknown",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
            
            // Apply pending actions
            if let toggleFavorite = actions.toggleFavorite {
                identity.isFavorite = toggleFavorite
            }
            if let trustLevel = actions.setTrustLevel {
                identity.trustLevel = trustLevel
            }
            if let petname = actions.setPetname {
                identity.localPetname = petname
            }
            
            // Save updated identity
            self.cache.socialIdentities[fingerprint] = identity
            self.pendingActions.removeValue(forKey: peerID)
            self.saveIdentityCache()
        }
    }
    
    // MARK: - Cleanup
    
    func clearAllIdentityData() {
        queue.async(flags: .barrier) {
            self.cache = IdentityCache()
            self.ephemeralSessions.removeAll()
            self.cryptographicIdentities.removeAll()
            self.pendingActions.removeAll()
            
            // Delete from keychain
            _ = self.keychain.deleteIdentityKey(forKey: self.cacheKey)
        }
    }
    
    func removeEphemeralSession(peerID: String) {
        queue.async(flags: .barrier) {
            self.ephemeralSessions.removeValue(forKey: peerID)
            self.pendingActions.removeValue(forKey: peerID)
        }
    }
    
    // MARK: - Verification
    
    func setVerified(fingerprint: String, verified: Bool) {
        queue.async(flags: .barrier) {
            if verified {
                self.cache.verifiedFingerprints.insert(fingerprint)
            } else {
                self.cache.verifiedFingerprints.remove(fingerprint)
            }
            
            // Update trust level if social identity exists
            if var identity = self.cache.socialIdentities[fingerprint] {
                identity.trustLevel = verified ? .verified : .casual
                self.cache.socialIdentities[fingerprint] = identity
            }
            
            self.saveIdentityCache()
        }
    }
    
    func isVerified(fingerprint: String) -> Bool {
        queue.sync {
            return cache.verifiedFingerprints.contains(fingerprint)
        }
    }
}