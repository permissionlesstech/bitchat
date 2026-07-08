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

import BitLogger
import BitFoundation
import Foundation
import CryptoKit

protocol SecureIdentityStateManagerProtocol {
    // MARK: Secure Loading/Saving
    func forceSave()
    
    // MARK: Social Identity Management
    func getSocialIdentity(for fingerprint: String) -> SocialIdentity?
    
    // MARK: Cryptographic Identities
    func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String?)
    func getCryptoIdentitiesByPeerIDPrefix(_ peerID: PeerID) -> [CryptographicIdentity]
    func updateSocialIdentity(_ identity: SocialIdentity)
    
    // MARK: Favorites Management
    func isFavorite(fingerprint: String) -> Bool
    
    // MARK: Blocked Users Management
    func isBlocked(fingerprint: String) -> Bool
    func setBlocked(_ fingerprint: String, isBlocked: Bool)
    
    // MARK: Geohash (Nostr) Blocking
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool
    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool)
    func getBlockedNostrPubkeys() -> Set<String>
    
    // MARK: Ephemeral Session Management
    func registerEphemeralSession(peerID: PeerID, handshakeState: HandshakeState)

    // MARK: Cleanup
    func clearAllIdentityData()
    func removeEphemeralSession(peerID: PeerID)
    
    // MARK: Verification
    func setVerified(fingerprint: String, verified: Bool)
    func isVerified(fingerprint: String) -> Bool
    func getVerifiedFingerprints() -> Set<String>

    // MARK: Vouching (transitive verification)
    @discardableResult
    func recordVouch(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date) -> Bool
    func validVouchers(for fingerprint: String) -> [VouchRecord]
    func isVouched(fingerprint: String) -> Bool
    func lastVouchBatchSent(to fingerprint: String) -> Date?
    func markVouchBatchSent(to fingerprint: String, at date: Date)
    func signingPublicKey(forFingerprint fingerprint: String) -> Data?
    func mostRecentlyVerifiedFingerprints(limit: Int, excluding fingerprint: String) -> [String]
}

/// Singleton manager for secure identity state persistence and retrieval.
/// Provides thread-safe access to identity mappings with encryption at rest.
/// All identity data is stored encrypted in the device Keychain for security.
final class SecureIdentityStateManager: SecureIdentityStateManagerProtocol {
    private let keychain: KeychainManagerProtocol
    private let cacheKey = "bitchat.identityCache.v2"
    private let encryptionKeyName = "identityCacheEncryptionKey"
    
    // In-memory state
    private var ephemeralSessions: [PeerID: EphemeralIdentity] = [:]
    private var cryptographicIdentities: [String: CryptographicIdentity] = [:]
    private var cache: IdentityCache = IdentityCache()
    
    // Thread safety
    private let queue = DispatchQueue(label: "bitchat.identity.state", attributes: .concurrent)
    
    // Pending-save coalescing flag. Reads/writes are serialized on `queue`.
    // Persistence is done with a fire-and-forget `queue.async(.barrier)` rather
    // than a retained DispatchSourceTimer: a lingering, never-cancelled timer
    // keeps the dispatch machinery alive and prevents the unit-test process from
    // exiting. (The original code used Timer.scheduledTimer on a GCD queue with
    // no run loop, so saves never actually fired.)
    private var pendingSave = false

    // Encryption key
    private let encryptionKey: SymmetricKey
    /// True when `encryptionKey` is a throwaway generated this session because the
    /// persisted key could not be read (device locked / access denied). In that
    /// state we must NOT persist (it would overwrite the real cache with data the
    /// next launch can't decrypt) and must NOT delete the existing cache.
    private let encryptionKeyIsEphemeral: Bool
    
    init(_ keychain: KeychainManagerProtocol) {
        self.keychain = keychain

        // Retrieve (or, only on genuine first run, generate) the cache
        // encryption key. We MUST distinguish "key doesn't exist yet" from a
        // transient failure (device locked / access denied): the legacy
        // getIdentityKey(forKey:) collapses both to nil, and generating+saving a
        // new key deletes the existing one first — permanently orphaning the
        // encrypted cache on a launch that merely couldn't read the key.
        let loadedKey: SymmetricKey
        let keyIsEphemeral: Bool

        switch keychain.getIdentityKeyWithResult(forKey: encryptionKeyName) {
        case .success(let keyData):
            loadedKey = SymmetricKey(data: keyData)
            keyIsEphemeral = false
            SecureLogger.logKeyOperation(.load, keyType: "identity cache encryption key", success: true)

        case .itemNotFound:
            // Genuine first run: generate and persist a new key.
            let newKey = SymmetricKey(size: .bits256)
            let keyData = newKey.withUnsafeBytes { Data($0) }
            let saved = keychain.saveIdentityKey(keyData, forKey: encryptionKeyName)
            loadedKey = newKey
            // If even the save failed, treat the key as ephemeral so we don't
            // later try to persist a cache the next launch can't read.
            keyIsEphemeral = !saved
            SecureLogger.logKeyOperation(.generate, keyType: "identity cache encryption key", success: saved)

        case .deviceLocked, .authenticationFailed, .accessDenied, .otherError:
            // Transient/critical read failure. Do NOT overwrite the persisted
            // key. Use a session-only ephemeral key; the real key and cache are
            // left intact for a healthy launch.
            SecureLogger.warning("Identity cache key unavailable; using ephemeral key for this session (not persisting)", category: .security)
            loadedKey = SymmetricKey(size: .bits256)
            keyIsEphemeral = true
        }

        self.encryptionKey = loadedKey
        self.encryptionKeyIsEphemeral = keyIsEphemeral

        // Only read the persisted cache when we hold the real key; with an
        // ephemeral key the decrypt would fail and discard the real cache.
        if !keyIsEphemeral {
            loadIdentityCache()
        }
    }
    
    deinit {
        forceSave()
    }
    
    // MARK: - Secure Loading/Saving
    
    private func loadIdentityCache() {
        guard let encryptedData = keychain.getIdentityKey(forKey: cacheKey) else {
            // No existing cache, start fresh
            return
        }
        
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            let decryptedData = try AES.GCM.open(sealedBox, using: encryptionKey)
            cache = try JSONDecoder().decode(IdentityCache.self, from: decryptedData)
        } catch {
            cache = IdentityCache()
            let deleted = keychain.deleteIdentityKey(forKey: cacheKey)
            SecureLogger.warning(
                "Discarded unreadable identity cache; starting fresh (deleted=\(deleted), error=\(error.localizedDescription))",
                category: .security
            )
        }
    }
    
    /// Persists the cache. Always invoked on `queue` under a barrier (its callers
    /// run inside `queue.async(.barrier)`), so it simply marks the cache dirty
    /// and persists it on the same serialized context — no timer, nothing left
    /// scheduled to keep the process alive.
    private func saveIdentityCache() {
        pendingSave = true
        performSave()
    }

    /// Writes the cache to the keychain. Must run on `queue` with exclusive
    /// (barrier) access.
    private func performSave() {
        guard pendingSave else { return }
        pendingSave = false

        // Never persist under an ephemeral key — it would overwrite the real
        // cache with data the next launch cannot decrypt.
        guard !encryptionKeyIsEphemeral else {
            SecureLogger.debug("Skipping identity cache save (ephemeral key this session)", category: .security)
            return
        }

        do {
            let data = try JSONEncoder().encode(cache)
            let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
            let saved = keychain.saveIdentityKey(sealedBox.combined!, forKey: cacheKey)
            if saved {
                SecureLogger.debug("Identity cache saved to keychain", category: .security)
            }
        } catch {
            SecureLogger.error(error, context: "Failed to save identity cache", category: .security)
        }
    }

    // Force immediate save (for app termination / lifecycle events). Mutations
    // already persist synchronously via saveIdentityCache, so this is normally a
    // no-op (performSave early-returns when nothing is pending). Runs directly on
    // the caller's thread — deliberately NOT a `queue.sync(barrier)`, which is
    // reachable from `deinit` and from async tests on the swift-concurrency
    // cooperative pool where a blocking barrier-sync can starve/deadlock it.
    func forceSave() {
        performSave()
    }
    
    // MARK: - Social Identity Management
    
    func getSocialIdentity(for fingerprint: String) -> SocialIdentity? {
        queue.sync {
            return cache.socialIdentities[fingerprint]
        }
    }

    // MARK: - Cryptographic Identities

    /// Insert or update a cryptographic identity and optionally persist its signing key and claimed nickname.
    /// - Parameters:
    ///   - fingerprint: SHA-256 hex of the Noise static public key
    ///   - noisePublicKey: Noise static public key data
    ///   - signingPublicKey: Optional Ed25519 signing public key for authenticating public messages
    ///   - claimedNickname: Optional latest claimed nickname to persist into social identity
    func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String? = nil) {
        queue.async(flags: .barrier) {
            let now = Date()
            if var existing = self.cryptographicIdentities[fingerprint] {
                // Update keys if changed
                if existing.publicKey != noisePublicKey {
                    existing = CryptographicIdentity(
                        fingerprint: fingerprint,
                        publicKey: noisePublicKey,
                        signingPublicKey: signingPublicKey ?? existing.signingPublicKey,
                        firstSeen: existing.firstSeen
                    )
                    self.cryptographicIdentities[fingerprint] = existing
                } else {
                    // Update signing key
                    existing.signingPublicKey = signingPublicKey ?? existing.signingPublicKey
                    self.cryptographicIdentities[fingerprint] = existing
                }
                // Persist updated state (already assigned in branches above)
            } else {
                // New entry
                let entry = CryptographicIdentity(
                    fingerprint: fingerprint,
                    publicKey: noisePublicKey,
                    signingPublicKey: signingPublicKey,
                    firstSeen: now
                )
                self.cryptographicIdentities[fingerprint] = entry
            }

            // Optionally persist claimed nickname into social identity
            if let claimed = claimedNickname {
                var identity = self.cache.socialIdentities[fingerprint] ?? SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: claimed,
                    trustLevel: .unknown,
                    isFavorite: false,
                    isBlocked: false,
                    notes: nil
                )
                // Update claimed nickname if changed
                if identity.claimedNickname != claimed {
                    identity.claimedNickname = claimed
                    self.cache.socialIdentities[fingerprint] = identity
                } else if self.cache.socialIdentities[fingerprint] == nil {
                    self.cache.socialIdentities[fingerprint] = identity
                }
            }

            self.saveIdentityCache()
        }
    }

    /// Find cryptographic identities whose fingerprint prefix matches a peerID (16-hex) short ID
    func getCryptoIdentitiesByPeerIDPrefix(_ peerID: PeerID) -> [CryptographicIdentity] {
        queue.sync {
            // Defensive: ensure hex and correct length
            guard peerID.isShort else { return [] }
            return cryptographicIdentities.values.filter { $0.fingerprint.hasPrefix(peerID.id) }
        }
    }
    
    func updateSocialIdentity(_ identity: SocialIdentity) {
        queue.async(flags: .barrier) {
            let previousClaimedNickname = self.cache.socialIdentities[identity.fingerprint]?.claimedNickname
            self.cache.socialIdentities[identity.fingerprint] = identity
            
            // Update nickname index
            if let previousClaimedNickname,
               previousClaimedNickname != identity.claimedNickname {
                self.cache.nicknameIndex[previousClaimedNickname]?.remove(identity.fingerprint)
                if self.cache.nicknameIndex[previousClaimedNickname]?.isEmpty == true {
                    self.cache.nicknameIndex.removeValue(forKey: previousClaimedNickname)
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
        SecureLogger.info("User \(isBlocked ? "blocked" : "unblocked"): \(fingerprint)", category: .security)
        
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

    // MARK: - Geohash (Nostr) Blocking
    
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        queue.sync {
            return cache.blockedNostrPubkeys.contains(pubkeyHexLowercased.lowercased())
        }
    }
    
    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool) {
        let key = pubkeyHexLowercased.lowercased()
        queue.async(flags: .barrier) {
            if isBlocked {
                self.cache.blockedNostrPubkeys.insert(key)
            } else {
                self.cache.blockedNostrPubkeys.remove(key)
            }
            self.saveIdentityCache()
        }
    }
    
    func getBlockedNostrPubkeys() -> Set<String> {
        queue.sync { cache.blockedNostrPubkeys }
    }
    
    // MARK: - Ephemeral Session Management
    
    func registerEphemeralSession(peerID: PeerID, handshakeState: HandshakeState = .none) {
        queue.async(flags: .barrier) {
            self.ephemeralSessions[peerID] = EphemeralIdentity(handshakeState: handshakeState)
        }
    }
    
    func updateHandshakeState(peerID: PeerID, state: HandshakeState) {
        queue.async(flags: .barrier) {
            self.ephemeralSessions[peerID]?.handshakeState = state
            
            // If handshake completed, update last interaction
            if case .completed(let fingerprint) = state {
                self.cache.lastInteractions[fingerprint] = Date()
                self.saveIdentityCache()
            }
        }
    }
    
    // MARK: - Cleanup
    
    func clearAllIdentityData() {
        SecureLogger.warning("Clearing all identity data", category: .security)
        
        queue.async(flags: .barrier) {
            self.cache = IdentityCache()
            self.ephemeralSessions.removeAll()
            self.cryptographicIdentities.removeAll()
            
            // Delete from keychain
            let deleted = self.keychain.deleteIdentityKey(forKey: self.cacheKey)
            SecureLogger.logKeyOperation(.delete, keyType: "identity cache", success: deleted)
        }
    }
    
    func removeEphemeralSession(peerID: PeerID) {
        queue.async(flags: .barrier) {
            self.ephemeralSessions.removeValue(forKey: peerID)
        }
    }
    
    // MARK: - Verification
    
    func setVerified(fingerprint: String, verified: Bool) {
        SecureLogger.info("Fingerprint \(verified ? "verified" : "unverified"): \(fingerprint)", category: .security)
        
        queue.async(flags: .barrier) {
            if verified {
                self.cache.verifiedFingerprints.insert(fingerprint)
                var verifiedAt = self.cache.verifiedAt ?? [:]
                verifiedAt[fingerprint] = Date()
                self.cache.verifiedAt = verifiedAt
            } else {
                self.cache.verifiedFingerprints.remove(fingerprint)
                self.cache.verifiedAt?.removeValue(forKey: fingerprint)
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

    // MARK: - Vouching (transitive verification)

    /// Maximum vouchers retained per vouchee (most recent kept).
    static let maxVouchersPerVouchee = 8

    /// Records an accepted vouch, enforcing every accept-policy gate that can
    /// be evaluated against stored state (signature verification is the
    /// caller's job — it needs the sender's announce-bound signing key):
    /// - the voucher must be a fingerprint *I* verified
    /// - self-vouches are ignored
    /// - vouches for peers I already verified are ignored (nothing to add)
    /// - attestations outside the validity window are ignored
    /// - at most `maxVouchersPerVouchee` vouchers are kept per vouchee
    ///
    /// Returns true when the vouch was stored (or refreshed).
    @discardableResult
    func recordVouch(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date) -> Bool {
        recordVouch(
            voucheeFingerprint: voucheeFingerprint,
            voucherFingerprint: voucherFingerprint,
            timestamp: timestamp,
            now: Date()
        )
    }

    @discardableResult
    func recordVouch(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date, now: Date) -> Bool {
        queue.sync(flags: .barrier) {
            guard voucheeFingerprint != voucherFingerprint,
                  self.cache.verifiedFingerprints.contains(voucherFingerprint),
                  !self.cache.verifiedFingerprints.contains(voucheeFingerprint) else {
                return false
            }
            let age = now.timeIntervalSince(timestamp)
            guard age <= VouchAttestation.maxAge, age >= -VouchAttestation.maxClockSkew else {
                return false
            }

            var records = self.cache.vouchesByVouchee?[voucheeFingerprint] ?? []
            if let index = records.firstIndex(where: { $0.voucherFingerprint == voucherFingerprint }) {
                let newest = max(records[index].timestamp, timestamp)
                records[index] = VouchRecord(voucherFingerprint: voucherFingerprint, timestamp: newest)
            } else {
                records.append(VouchRecord(voucherFingerprint: voucherFingerprint, timestamp: timestamp))
            }
            // Keep the most recent vouchers up to the cap.
            records.sort { $0.timestamp > $1.timestamp }
            let capped = Array(records.prefix(Self.maxVouchersPerVouchee))
            guard capped.contains(where: { $0.voucherFingerprint == voucherFingerprint }) else {
                return false // Full of fresher vouches; nothing changed.
            }

            var vouches = self.cache.vouchesByVouchee ?? [:]
            vouches[voucheeFingerprint] = capped
            self.cache.vouchesByVouchee = vouches
            self.saveIdentityCache()
            return true
        }
    }

    /// The vouches that currently count for `fingerprint`. Validity is
    /// recomputed here rather than maintained by cascade deletes: a record
    /// only counts while its voucher is still verified-by-me and its
    /// timestamp is within the expiry window.
    func validVouchers(for fingerprint: String) -> [VouchRecord] {
        validVouchers(for: fingerprint, now: Date())
    }

    func validVouchers(for fingerprint: String, now: Date) -> [VouchRecord] {
        queue.sync {
            self.validVouchersLocked(for: fingerprint, now: now)
        }
    }

    /// Requires `queue`.
    private func validVouchersLocked(for fingerprint: String, now: Date) -> [VouchRecord] {
        guard let records = cache.vouchesByVouchee?[fingerprint] else { return [] }
        return records.filter { record in
            record.voucherFingerprint != fingerprint
                && cache.verifiedFingerprints.contains(record.voucherFingerprint)
                && now.timeIntervalSince(record.timestamp) <= VouchAttestation.maxAge
        }
    }

    /// True when the peer has at least one valid vouch and no explicit
    /// verification of ours.
    func isVouched(fingerprint: String) -> Bool {
        isVouched(fingerprint: fingerprint, now: Date())
    }

    func isVouched(fingerprint: String, now: Date) -> Bool {
        queue.sync {
            guard !self.cache.verifiedFingerprints.contains(fingerprint) else { return false }
            return !self.validVouchersLocked(for: fingerprint, now: now).isEmpty
        }
    }

    /// The trust level to display: explicit verification wins, then the
    /// persisted level, with `vouched` layered in (derived, never persisted)
    /// between `casual` and `trusted`.
    func effectiveTrustLevel(for fingerprint: String) -> TrustLevel {
        effectiveTrustLevel(for: fingerprint, now: Date())
    }

    func effectiveTrustLevel(for fingerprint: String, now: Date) -> TrustLevel {
        queue.sync {
            if self.cache.verifiedFingerprints.contains(fingerprint) { return .verified }
            let stored = self.cache.socialIdentities[fingerprint]?.trustLevel ?? .unknown
            let vouched = !self.validVouchersLocked(for: fingerprint, now: now).isEmpty
            switch stored {
            case .verified, .trusted:
                return stored
            case .vouched, .casual, .unknown:
                if vouched { return .vouched }
                // `.vouched` should never be persisted; degrade defensively.
                return stored == .vouched ? .casual : stored
            }
        }
    }

    func lastVouchBatchSent(to fingerprint: String) -> Date? {
        queue.sync { cache.vouchBatchSentAt?[fingerprint] }
    }

    func markVouchBatchSent(to fingerprint: String, at date: Date) {
        queue.async(flags: .barrier) {
            var sentAt = self.cache.vouchBatchSentAt ?? [:]
            sentAt[fingerprint] = date
            self.cache.vouchBatchSentAt = sentAt
            self.saveIdentityCache()
        }
    }

    /// The peer's announce-bound Ed25519 signing key, if seen this session.
    func signingPublicKey(forFingerprint fingerprint: String) -> Data? {
        queue.sync { cryptographicIdentities[fingerprint]?.signingPublicKey }
    }

    /// Verified fingerprints ordered most recently verified first (entries
    /// without a recorded verification time sort last), excluding the given
    /// fingerprint. Feeds the outgoing vouch batch.
    func mostRecentlyVerifiedFingerprints(limit: Int, excluding fingerprint: String) -> [String] {
        queue.sync {
            let verifiedAt = cache.verifiedAt ?? [:]
            let ordered = cache.verifiedFingerprints
                .filter { $0 != fingerprint }
                .sorted {
                    (verifiedAt[$0] ?? .distantPast, $0) > (verifiedAt[$1] ?? .distantPast, $1)
                }
            return Array(ordered.prefix(limit))
        }
    }

    var debugNicknameIndex: [String: Set<String>] {
        queue.sync { cache.nicknameIndex }
    }

    func debugEphemeralSession(for peerID: PeerID) -> EphemeralIdentity? {
        queue.sync { ephemeralSessions[peerID] }
    }

    func debugLastInteraction(for fingerprint: String) -> Date? {
        queue.sync { cache.lastInteractions[fingerprint] }
    }
}
