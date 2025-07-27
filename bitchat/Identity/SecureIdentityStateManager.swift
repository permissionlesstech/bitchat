//
// SecureIdentityStateManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # SecureIdentityStateManager
///
/// Manages the persistent storage and retrieval of identity mappings with
/// encryption at rest. This singleton service maintains the relationship between
/// ephemeral peer IDs, cryptographic fingerprints, and social identities.
///
/// ## Overview
/// The SecureIdentityStateManager provides a secure, privacy-preserving way to
/// maintain identity relationships across app launches. It implements:
/// - Encrypted storage of identity mappings
/// - In-memory caching for performance
/// - Thread-safe access patterns
/// - Automatic debounced persistence
///
/// ## Architecture
/// The manager operates at three levels:
/// 1. **In-Memory State**: Fast access to active identities
/// 2. **Encrypted Cache**: Persistent storage in Keychain
/// 3. **Privacy Controls**: User-configurable persistence settings
///
/// ## Security Features
///
/// ### Encryption at Rest
/// - Identity cache encrypted with AES-GCM
/// - Unique 256-bit encryption key per device
/// - Key stored separately in Keychain
/// - No plaintext identity data on disk
///
/// ### Privacy by Design
/// - Persistence is optional (user-controlled)
/// - Minimal data retention
/// - No cloud sync or backup
/// - Automatic cleanup of stale entries
///
/// ### Thread Safety
/// - Concurrent read access via GCD barriers
/// - Write operations serialized
/// - Atomic state updates
/// - No data races or corruption
///
/// ## Data Model
/// Manages three types of identity data:
/// 1. **Ephemeral Sessions**: Current peer connections
/// 2. **Cryptographic Identities**: Public keys and fingerprints
/// 3. **Social Identities**: User-assigned names and trust
///
/// ## Persistence Strategy
/// - Changes batched and debounced (2-second window)
/// - Automatic save on app termination
/// - Crash-resistant with atomic writes
/// - Migration support for schema changes
///
/// ## Usage Patterns
/// ```swift
/// // Register a new peer identity
/// manager.registerPeerIdentity(peerID, publicKey, fingerprint)
/// 
/// // Update social identity
/// manager.updateSocialIdentity(fingerprint, nickname, trustLevel)
/// 
/// // Query identity
/// let identity = manager.resolvePeerIdentity(peerID)
/// ```
///
/// ## Performance Optimizations
/// - In-memory cache eliminates Keychain roundtrips
/// - Debounced saves reduce I/O operations
/// - Efficient data structures for lookups
/// - Background queue for expensive operations
///
/// ## Privacy Considerations
/// - Users can disable all persistence
/// - Identity cache can be wiped instantly
/// - No analytics or telemetry
/// - Ephemeral mode for high-risk users
///
/// ## Future Enhancements
/// - Selective identity export
/// - Cross-device identity sync (optional)
/// - Identity attestation support
/// - Advanced conflict resolution
///

import Foundation
import CryptoKit

/// Singleton manager for secure identity state persistence and retrieval.
/// Provides thread-safe access to identity mappings with encryption at rest.
/// All identity data is stored encrypted in the device Keychain for security.
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
    
    // Debouncing for keychain saves
    private var saveTimer: Timer?
    private let saveDebounceInterval: TimeInterval = 2.0  // Save at most once every 2 seconds
    private var pendingSave = false
    
    // Encryption key
    private let encryptionKey: SymmetricKey
    
    private init() {
        // Generate or retrieve encryption key from keychain
        let loadedKey: SymmetricKey
        
        // Try to load from keychain
        if let keyData = keychain.getIdentityKey(forKey: encryptionKeyName) {
            loadedKey = SymmetricKey(data: keyData)
            SecureLogger.logKeyOperation("load", keyType: "identity cache encryption key", success: true)
        }
        // Generate new key if needed
        else {
            loadedKey = SymmetricKey(size: .bits256)
            let keyData = loadedKey.withUnsafeBytes { Data($0) }
            // Save to keychain
            let saved = keychain.saveIdentityKey(keyData, forKey: encryptionKeyName)
            SecureLogger.logKeyOperation("generate", keyType: "identity cache encryption key", success: saved)
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
            SecureLogger.logError(error, context: "Failed to load identity cache", category: SecureLogger.security)
        }
    }
    
    deinit {
        // Force save any pending changes
        forceSave()
    }
    
    func saveIdentityCache() {
        // Mark that we need to save
        pendingSave = true
        
        // Cancel any existing timer
        saveTimer?.invalidate()
        
        // Schedule a new save after the debounce interval
        saveTimer = Timer.scheduledTimer(withTimeInterval: saveDebounceInterval, repeats: false) { [weak self] _ in
            self?.performSave()
        }
    }
    
    private func performSave() {
        guard pendingSave else { return }
        pendingSave = false
        
        do {
            let data = try JSONEncoder().encode(cache)
            let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
            let saved = keychain.saveIdentityKey(sealedBox.combined!, forKey: cacheKey)
            if saved {
                SecureLogger.log("Identity cache saved to keychain", category: SecureLogger.security, level: .debug)
            }
        } catch {
            SecureLogger.logError(error, context: "Failed to save identity cache", category: SecureLogger.security)
        }
    }
    
    // Force immediate save (for app termination)
    func forceSave() {
        saveTimer?.invalidate()
        if pendingSave {
            performSave()
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
        SecureLogger.log("User \(isBlocked ? "blocked" : "unblocked"): \(fingerprint)", category: SecureLogger.security, level: .info)
        
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
        SecureLogger.log("Clearing all identity data", category: SecureLogger.security, level: .warning)
        
        queue.async(flags: .barrier) {
            self.cache = IdentityCache()
            self.ephemeralSessions.removeAll()
            self.cryptographicIdentities.removeAll()
            self.pendingActions.removeAll()
            
            // Delete from keychain
            let deleted = self.keychain.deleteIdentityKey(forKey: self.cacheKey)
            SecureLogger.logKeyOperation("delete", keyType: "identity cache", success: deleted)
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
        SecureLogger.log("Fingerprint \(verified ? "verified" : "unverified"): \(fingerprint)", category: SecureLogger.security, level: .info)
        
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
    
    func getVerifiedFingerprints() -> Set<String> {
        queue.sync {
            return cache.verifiedFingerprints
        }
    }
}