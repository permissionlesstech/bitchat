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
/// - Synchronous, change-only persistence
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
/// - Synchronous, change-only: a call writes before it returns, and only
///   when it changed something
/// - A failed write is retried; termination flushes it
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
/// - Unchanged re-announces skip the write entirely
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
    func recordVouches(_ vouches: [(voucheeFingerprint: String, timestamp: Date)], voucherFingerprint: String) -> Int
    func validVouchers(for fingerprint: String) -> [VouchRecord]
    func isVouched(fingerprint: String) -> Bool
    func lastVouchBatchSent(to fingerprint: String) -> Date?
    func markVouchBatchSent(to fingerprint: String, at date: Date)
    func signingPublicKey(forFingerprint fingerprint: String) -> Data?
    func mostRecentlyVerifiedFingerprints(limit: Int, excluding fingerprint: String) -> [String]

    // MARK: Noise-authenticated announcement identity
    func bindAuthenticatedSigningPublicKey(_ signingPublicKey: Data, fingerprint: String)
    func authenticatedSigningPublicKey(forFingerprint fingerprint: String) -> Data?

    // MARK: Private-media downgrade protection
    func markPrivateMediaCapable(fingerprint: String)
    func hasObservedPrivateMediaCapability(fingerprint: String) -> Bool
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
    // Cryptographic identities (including pinned signing keys) live inside
    // `cache` so they persist across app restarts; see IdentityCache.
    private var cache: IdentityCache = IdentityCache()
    // Short peer ID (the first 16 hex characters of a fingerprint) -> the
    // keys of `cache.cryptographicIdentities` whose fingerprint starts with
    // it, so `getCryptoIdentitiesByPeerIDPrefix` is a hash lookup instead of
    // a scan over every identity ever seen. Derived from `cache`, never
    // persisted, and guarded by `queue` like it. Only `rebuildShortIDIndex`,
    // `indexShortIDLocked` (the one place a crypto identity is inserted) and
    // `clearAllIdentityData` touch it.
    private var fingerprintsByShortID: [String: [String]] = [:]
    
    // Thread safety
    private let queue = DispatchQueue(label: "bitchat.identity.state", attributes: .concurrent)
    private let queueSpecificKey = DispatchSpecificKey<UInt8>()
    
    // Failed-write retry state. Reads/writes are serialized on `queue`.
    //
    // Persistence is SYNCHRONOUS: every mutating API runs its mutate + encrypt
    // + keychain write inside `queue.sync(flags: .barrier)`, so when the call
    // returns the write is already complete and NOTHING is left scheduled on
    // the queue. This is deliberate — a retained DispatchSourceTimer (the
    // original design) kept the dispatch machinery alive and prevented the
    // unit-test process from exiting, and fire-and-forget `queue.async(.barrier)`
    // (a later design) left a backlog of instrumented barrier saves still
    // draining when LLVM's `--enable-code-coverage` `atexit` handler dumped
    // `.profraw`, deadlocking the process at teardown on the constrained CI
    // runner. Synchronous persistence has zero outstanding dispatch at exit, so
    // neither failure mode is possible.
    //
    // Writes are also change-only (see `upsertCryptographicIdentity`), so the
    // next announce no longer repairs a failed write by accident. `pendingSave`
    // is true while the keychain does not hold the in-memory state: the last
    // write failed, and because `KeychainManager.saveData` deletes the item
    // before adding the new one, the keychain may hold no identity cache at
    // all. The next mutation's own write carries the pending state. An upsert
    // that changes nothing retries at once after a first failure, which keeps
    // that window as short as it was when every announce wrote; once writes
    // have failed twice in a row it retries at most once per
    // `failedSaveRetryInterval` after `lastFailedSaveAt`, so a keychain that
    // keeps failing is not sent a full re-encoded cache on every announce.
    // `forceSave` (termination) and `deinit` always retry.
    private var pendingSave = false
    private var consecutiveFailedSaves = 0
    private var lastFailedSaveAt: Date?
    /// Minimum spacing between retries of a failed write by upserts that
    /// changed nothing, once writes have failed twice in a row.
    static let failedSaveRetryInterval: TimeInterval = 30

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
        queue.setSpecific(key: queueSpecificKey, value: 1)

        // Only read the persisted cache when we hold the real key; with an
        // ephemeral key the decrypt would fail and discard the real cache.
        if !keyIsEphemeral {
            loadIdentityCache()
        }
    }
    
    deinit {
        // Do NOT dispatch onto `queue` here. `deinit` can run on any thread
        // (including one draining `queue`), and the object is being
        // deallocated: a `queue.sync` risks a re-entrant same-queue wait
        // (deadlock) and a `queue.async` schedules work that resurrects `self`
        // and may not drain before process exit.
        //
        // A flush here is normally redundant: every mutating API already
        // persists inline within its own barrier, so the keychain is already
        // up to date unless a write failed. As a queue-free best-effort
        // retry, only flush if a write is still pending. This is a direct read of
        // in-hand state — safe because a deallocating object has no other
        // live references, so nothing can be mutating `cache` concurrently.
        if pendingSave {
            pendingSave = false
            persist(snapshot: cache)
        }
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
        rebuildShortIDIndex()
    }

    /// Rebuilds `fingerprintsByShortID` from `cache`. Runs in `init`, before
    /// `self` escapes, so it needs no barrier.
    private func rebuildShortIDIndex() {
        fingerprintsByShortID = [:]
        for (key, identity) in cache.cryptographicIdentities {
            fingerprintsByShortID[String(identity.fingerprint.prefix(16)), default: []].append(key)
        }
    }

    /// Requires `queue` (barrier). Indexes a crypto identity just inserted.
    private func indexShortIDLocked(_ fingerprint: String) {
        fingerprintsByShortID[String(fingerprint.prefix(16)), default: []].append(fingerprint)
    }
    
    /// Persists the cache. Always invoked on `queue` under a barrier (its
    /// callers run inside `queue.sync(flags: .barrier)`), so `cache` is read
    /// while serialized. The encode + keychain write are done here (already on
    /// the exclusive barrier context), synchronously, so no separate hop is
    /// scheduled and nothing is left to keep the process alive. A failed
    /// write leaves `pendingSave` set so it is retried.
    private func saveIdentityCache(now: Date = Date()) {
        // On the barrier context already: snapshot is trivially consistent.
        if persist(snapshot: cache) {
            pendingSave = false
            consecutiveFailedSaves = 0
            lastFailedSaveAt = nil
        } else {
            pendingSave = true
            consecutiveFailedSaves += 1
            lastFailedSaveAt = now
        }
    }

    /// Requires `queue`. Whether an upsert that changed nothing should retry
    /// a failed write now: at once after a first failure, then once per
    /// `failedSaveRetryInterval`. `abs` keeps a clock stepped backwards from
    /// postponing the retry indefinitely.
    private func failedSaveRetryIsDueLocked(now: Date) -> Bool {
        guard pendingSave else { return false }
        guard consecutiveFailedSaves > 1, let lastFailedSaveAt else { return true }
        return abs(now.timeIntervalSince(lastFailedSaveAt)) >= Self.failedSaveRetryInterval
    }

    /// Encodes, seals, and writes a *snapshot* of the cache to the keychain.
    ///
    /// Takes the cache by value so callers can capture a consistent snapshot
    /// under `queue` and then encode without holding it. Reading `cache`
    /// concurrently with a barrier writer would be a data race on the
    /// dictionary storage, which — because `JSONEncoder` walks that storage —
    /// can spin forever (observed as a CI test-suite hang), so the snapshot
    /// must be taken on `queue`, never off it.
    ///
    /// Returns false when the write failed and must be retried. Returns true
    /// when the keychain holds the snapshot, or when this session never
    /// persists (ephemeral key), so there is nothing to retry.
    @discardableResult
    private func persist(snapshot: IdentityCache) -> Bool {
        // Never persist under an ephemeral key — it would overwrite the real
        // cache with data the next launch cannot decrypt.
        guard !encryptionKeyIsEphemeral else {
            SecureLogger.debug("Skipping identity cache save (ephemeral key this session)", category: .security)
            return true
        }

        do {
            let data = try JSONEncoder().encode(snapshot)
            let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
            let saved = keychain.saveIdentityKey(sealedBox.combined!, forKey: cacheKey)
            if saved {
                SecureLogger.debug("Identity cache saved to keychain", category: .security)
            }
            return saved
        } catch {
            SecureLogger.error(error, context: "Failed to save identity cache", category: .security)
            return false
        }
    }

    // Force a flush (for app-termination / lifecycle events — NOT from
    // `deinit`, which persists inline; see the deinit note). Every mutating
    // API already persists inline inside its own barrier via
    // `saveIdentityCache`, so by the time this is called the keychain is
    // normally up to date and this is a no-op; it retries a write that
    // failed (`pendingSave`).
    //
    // Runs synchronously inside a `queue.sync(flags: .barrier)`: the barrier
    // makes the `cache` read race-free (a plain off-queue read races in-flight
    // barrier writers — JSONEncoder walking a concurrently-mutated dictionary
    // can spin forever, which surfaced as a CI hang), and being synchronous it
    // leaves nothing scheduled to keep the process alive at teardown. Safe
    // against re-entrant deadlock because this is never invoked from `deinit`
    // (the only path that can run *on* `queue`).
    func forceSave() {
        queue.sync(flags: .barrier) {
            guard pendingSave else { return }
            saveIdentityCache()
        }
    }
    
    // MARK: - Social Identity Management
    
    func getSocialIdentity(for fingerprint: String) -> SocialIdentity? {
        queue.sync {
            return cache.socialIdentities[fingerprint]
        }
    }

    // MARK: - Cryptographic Identities

    /// Insert or update a cryptographic identity and optionally persist its signing key and claimed nickname.
    ///
    /// TOFU signing-key pinning: once a signing key has been persisted for a
    /// fingerprint, an update carrying a *different* signing key is refused in
    /// full (including the claimed-nickname update) and security-logged. This
    /// mirrors `BLEPeerRegistry.upsertVerifiedAnnounce` — without it, an
    /// attacker replaying a victim's noiseKey/peerID with their own signing
    /// key could overwrite the victim's persisted identity while the victim is
    /// offline or after an app restart. The refusal is permanent: there is
    /// currently no targeted in-app way to reset the pin (`setVerified` does
    /// not touch it). Recovering from a legitimate signing re-key requires the
    /// peer to establish a new noise identity (new peerID) or the local user
    /// to wipe all identity data (`clearAllIdentityData`, e.g. panic wipe).
    ///
    /// Writes the cache only when the call changes it (a new identity, a
    /// first signing-key pin, a Noise key change or a nickname change).
    /// Most calls are periodic re-announces of an unchanged peer, and each
    /// write re-encodes, re-seals and replaces the whole cache.
    /// - Parameters:
    ///   - fingerprint: SHA-256 hex of the Noise static public key
    ///   - noisePublicKey: Noise static public key data
    ///   - signingPublicKey: Optional Ed25519 signing public key for authenticating public messages
    ///   - claimedNickname: Optional latest claimed nickname to persist into social identity
    func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String? = nil) {
        upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            claimedNickname: claimedNickname,
            now: Date()
        )
    }

    func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String?, now: Date) {
        queue.sync(flags: .barrier) {
            var changed = false
            if var existing = self.cache.cryptographicIdentities[fingerprint] {
                if let pinnedSigningKey = existing.signingPublicKey,
                   let announcedSigningKey = signingPublicKey,
                   pinnedSigningKey != announcedSigningKey {
                    SecureLogger.warning("🚨 Refusing to replace pinned signing key for \(fingerprint.prefix(8))… (possible impersonation attempt)", category: .security)
                    return
                }
                // Update keys if changed
                if existing.publicKey != noisePublicKey {
                    existing = CryptographicIdentity(
                        fingerprint: fingerprint,
                        publicKey: noisePublicKey,
                        signingPublicKey: signingPublicKey ?? existing.signingPublicKey,
                        firstSeen: existing.firstSeen
                    )
                    self.cache.cryptographicIdentities[fingerprint] = existing
                    changed = true
                } else if existing.signingPublicKey == nil, let signingPublicKey {
                    // First pin of the signing key. Any other announced key
                    // either matches the pin or was refused above.
                    existing.signingPublicKey = signingPublicKey
                    self.cache.cryptographicIdentities[fingerprint] = existing
                    changed = true
                }
            } else {
                // New entry
                let entry = CryptographicIdentity(
                    fingerprint: fingerprint,
                    publicKey: noisePublicKey,
                    signingPublicKey: signingPublicKey,
                    firstSeen: now
                )
                self.cache.cryptographicIdentities[fingerprint] = entry
                self.indexShortIDLocked(fingerprint)
                changed = true
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
                    changed = true
                } else if self.cache.socialIdentities[fingerprint] == nil {
                    self.cache.socialIdentities[fingerprint] = identity
                    changed = true
                }
            }

            if changed || self.failedSaveRetryIsDueLocked(now: now) {
                self.saveIdentityCache(now: now)
            }
        }
    }

    /// Find cryptographic identities whose fingerprint prefix matches a peerID (16-hex) short ID
    func getCryptoIdentitiesByPeerIDPrefix(_ peerID: PeerID) -> [CryptographicIdentity] {
        queue.sync {
            // Defensive: ensure hex and correct length
            guard peerID.isShort else { return [] }
            // `id` keeps any prefix (`nostr_`, `bridge:`), which no
            // fingerprint starts with, so prefixed IDs still find nothing.
            return (fingerprintsByShortID[peerID.id] ?? []).compactMap { cache.cryptographicIdentities[$0] }
        }
    }

    // MARK: - Private-media downgrade protection

    func markPrivateMediaCapable(fingerprint: String) {
        guard !fingerprint.isEmpty else { return }
        let insertAndPersist = {
            var pinned = self.cache.privateMediaCapableFingerprints ?? []
            guard pinned.insert(fingerprint).inserted else { return }
            self.cache.privateMediaCapableFingerprints = pinned
            self.saveIdentityCache()
        }
        // Downgrade decisions can run immediately after an authenticated
        // announce. Make the pin visible before returning; merely enqueueing a
        // barrier leaves a cross-queue window where a replay can look legacy.
        // The queue-specific fast path prevents self-deadlock if a future
        // identity-state mutation records the capability from inside `queue`.
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            insertAndPersist()
        } else {
            queue.sync(flags: .barrier, execute: insertAndPersist)
        }
    }

    func hasObservedPrivateMediaCapability(fingerprint: String) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return queue.sync {
            cache.privateMediaCapableFingerprints?.contains(fingerprint) == true
        }
    }

    // MARK: - Noise-authenticated announcement identity

    func bindAuthenticatedSigningPublicKey(_ signingPublicKey: Data, fingerprint: String) {
        guard signingPublicKey.count == AuthenticatedPeerStatePacket.signingPublicKeyLength,
              !fingerprint.isEmpty else { return }
        let bindAndPersist = {
            var changed = false
            if self.cache.authenticatedSigningKeysByFingerprint?[fingerprint] != signingPublicKey {
                var bindings = self.cache.authenticatedSigningKeysByFingerprint ?? [:]
                bindings[fingerprint] = signingPublicKey
                self.cache.authenticatedSigningKeysByFingerprint = bindings
                changed = true
            }
            // The persisted crypto identity follows the binding. Upserts write
            // only what they change, so this mutation must persist itself.
            if var cryptoIdentity = self.cache.cryptographicIdentities[fingerprint],
               cryptoIdentity.signingPublicKey != signingPublicKey {
                cryptoIdentity.signingPublicKey = signingPublicKey
                self.cache.cryptographicIdentities[fingerprint] = cryptoIdentity
                changed = true
            }
            guard changed else { return }
            self.saveIdentityCache()
        }
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            bindAndPersist()
        } else {
            queue.sync(flags: .barrier, execute: bindAndPersist)
        }
    }

    func authenticatedSigningPublicKey(forFingerprint fingerprint: String) -> Data? {
        guard !fingerprint.isEmpty else { return nil }
        return queue.sync {
            cache.authenticatedSigningKeysByFingerprint?[fingerprint]
        }
    }
    
    func updateSocialIdentity(_ identity: SocialIdentity) {
        queue.sync(flags: .barrier) {
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
        queue.sync(flags: .barrier) {
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
        
        queue.sync(flags: .barrier) {
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
        queue.sync(flags: .barrier) {
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
        queue.sync(flags: .barrier) {
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
        
        queue.sync(flags: .barrier) {
            self.cache = IdentityCache()
            self.fingerprintsByShortID = [:]
            self.ephemeralSessions.removeAll()
            // Nothing is left to retry: the wipe deletes the keychain item.
            self.pendingSave = false
            self.consecutiveFailedSaves = 0
            self.lastFailedSaveAt = nil

            // Delete from keychain
            let deleted = self.keychain.deleteIdentityKey(forKey: self.cacheKey)
            SecureLogger.logKeyOperation(.delete, keyType: "identity cache", success: deleted)
        }
    }
    
    func removeEphemeralSession(peerID: PeerID) {
        queue.sync(flags: .barrier) {
            _ = self.ephemeralSessions.removeValue(forKey: peerID)
        }
    }
    
    // MARK: - Verification
    
    func setVerified(fingerprint: String, verified: Bool) {
        SecureLogger.info("Fingerprint \(verified ? "verified" : "unverified"): \(fingerprint)", category: .security)
        
        queue.sync(flags: .barrier) {
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

    /// Records a batch of accepted vouches from one voucher, enforcing every
    /// accept-policy gate that can be evaluated against stored state
    /// (signature verification is the caller's job — it needs the sender's
    /// announce-bound signing key):
    /// - the voucher must be a fingerprint *I* verified
    /// - self-vouches are ignored
    /// - vouches for peers I already verified are ignored (nothing to add)
    /// - attestations outside the validity window are ignored
    /// - a repeat vouch counts only with a strictly newer timestamp
    /// - at most `maxVouchersPerVouchee` vouchers are kept per vouchee
    ///
    /// The batch is applied in one barrier and written at most once.
    /// Returns how many vouches were stored (or refreshed).
    @discardableResult
    func recordVouches(_ vouches: [(voucheeFingerprint: String, timestamp: Date)], voucherFingerprint: String) -> Int {
        recordVouches(vouches, voucherFingerprint: voucherFingerprint, now: Date())
    }

    @discardableResult
    func recordVouches(
        _ vouches: [(voucheeFingerprint: String, timestamp: Date)],
        voucherFingerprint: String,
        now: Date
    ) -> Int {
        queue.sync(flags: .barrier) {
            guard self.cache.verifiedFingerprints.contains(voucherFingerprint) else { return 0 }
            var stored = 0
            for vouch in vouches where self.applyVouchLocked(
                voucheeFingerprint: vouch.voucheeFingerprint,
                voucherFingerprint: voucherFingerprint,
                timestamp: vouch.timestamp,
                now: now
            ) {
                stored += 1
            }
            if stored > 0 {
                self.saveIdentityCache()
            }
            return stored
        }
    }

    /// One-vouch `recordVouches`. Returns true when the vouch was stored (or
    /// refreshed).
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
        recordVouches(
            [(voucheeFingerprint: voucheeFingerprint, timestamp: timestamp)],
            voucherFingerprint: voucherFingerprint,
            now: now
        ) == 1
    }

    /// Requires `queue` (barrier) and a voucher I verified. Applies one vouch
    /// without writing; returns whether the stored vouches changed.
    private func applyVouchLocked(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date, now: Date) -> Bool {
        guard voucheeFingerprint != voucherFingerprint,
              !cache.verifiedFingerprints.contains(voucheeFingerprint) else {
            return false
        }
        let age = now.timeIntervalSince(timestamp)
        guard age <= VouchAttestation.maxAge, age >= -VouchAttestation.maxClockSkew else {
            return false
        }

        var records = cache.vouchesByVouchee?[voucheeFingerprint] ?? []
        if let index = records.firstIndex(where: { $0.voucherFingerprint == voucherFingerprint }) {
            // An equal or older redelivery changes nothing.
            guard timestamp > records[index].timestamp else { return false }
            records[index] = VouchRecord(voucherFingerprint: voucherFingerprint, timestamp: timestamp)
        } else {
            records.append(VouchRecord(voucherFingerprint: voucherFingerprint, timestamp: timestamp))
        }
        // Keep the most recent vouchers up to the cap.
        records.sort { $0.timestamp > $1.timestamp }
        let capped = Array(records.prefix(Self.maxVouchersPerVouchee))
        guard capped.contains(where: { $0.voucherFingerprint == voucherFingerprint }) else {
            return false // Full of fresher vouches; nothing changed.
        }

        var vouches = cache.vouchesByVouchee ?? [:]
        vouches[voucheeFingerprint] = capped
        cache.vouchesByVouchee = vouches
        return true
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
        queue.sync { cache.cryptographicIdentities[fingerprint]?.signingPublicKey }
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
