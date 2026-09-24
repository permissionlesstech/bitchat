import BitFoundation
import Foundation
import CryptoKit

/// Bridge between Noise and Nostr identities
final class NostrIdentityBridge {
    private let keychainService = "chat.bitchat.nostr"
    private let currentIdentityKey = "nostr-current-identity"
    private let deviceSeedKey = "nostr-device-seed"
    // In-memory cache to avoid transient keychain access issues
    private var deviceSeedCache: Data?
    // Cache derived identities to avoid repeated crypto during view rendering
    private var derivedIdentityCache: [String: NostrIdentity] = [:]
    private let cacheLock = NSLock()

    private let keychain: KeychainManagerProtocol

    init(keychain: KeychainManagerProtocol = KeychainManager.makeDefault()) {
        self.keychain = keychain
    }
    
    /// Get or create the current Nostr identity
    func getCurrentNostrIdentity() throws -> NostrIdentity? {
        // Check if we already have a Nostr identity
        if let existingData = keychain.load(key: currentIdentityKey, service: keychainService),
           let identity = try? JSONDecoder().decode(NostrIdentity.self, from: existingData) {
            return identity
        }
        
        // Generate new Nostr identity
        let nostrIdentity = try NostrIdentity.generate()
        
        // Store it
        let data = try JSONEncoder().encode(nostrIdentity)
        keychain.save(key: currentIdentityKey, data: data, service: keychainService, accessible: nil)
        
        return nostrIdentity
    }
    
    /// Get Nostr public key associated with a Noise public key
    func getNostrPublicKey(for noisePublicKey: Data) -> String? {
        let key = "nostr-noise-\(noisePublicKey.base64EncodedString())"
        guard let data = keychain.load(key: key, service: keychainService),
              let pubkey = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pubkey
    }
    
    /// Clear all Nostr identity associations and current identity
    func clearAllAssociations() {
        // Must go through the injected keychain, not raw SecItem calls:
        // under test that keychain is in-memory, and a direct delete here
        // would wipe the developer's real Nostr identity on every test run.
        keychain.deleteAll(service: keychainService)

        deviceSeedCache = nil
        // Also drop the in-memory derived per-geohash identities. These hold the
        // actual secp256k1 private keys; if left cached, post-panic geohash
        // messages would still be signed with pre-panic keys (linkable across the
        // wipe) until the app is force-quit.
        cacheLock.lock()
        derivedIdentityCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Identity Backup (export / restore)

    /// Current device seed used for per-geohash derivation (creates one if missing).
    func exportDeviceSeed() -> Data {
        getOrCreateDeviceSeed()
    }

    /// Replace the primary Nostr identity and device seed with restored material.
    /// Clears derived-identity caches so geohash keys recompute from the new seed.
    ///
    /// `keychain.save` is fire-and-forget, so this method always read-backs both
    /// values and throws if either write did not stick. On failure it attempts
    /// to restore the previous primary/seed snapshot so Noise and Nostr cannot
    /// diverge after a half-applied restore.
    @discardableResult
    func installRestoredIdentity(privateKey: Data, deviceSeed: Data) throws -> NostrIdentity {
        guard deviceSeed.count == 32 else {
            throw IdentityBackupError.invalidKeyMaterial
        }
        let identity = try NostrIdentity(privateKeyData: privateKey)
        let encoded = try JSONEncoder().encode(identity)

        // Snapshot whatever is currently durable so a failed write after wipe
        // can be rolled back instead of leaving an empty Nostr identity.
        let previousIdentity = keychain.load(key: currentIdentityKey, service: keychainService)
        let previousSeed = keychain.load(key: deviceSeedKey, service: keychainService)

        // Drop prior associations/caches first so a partial failure cannot leave
        // a mix of old seed + new primary (or vice versa).
        clearAllAssociations()

        keychain.save(
            key: currentIdentityKey,
            data: encoded,
            service: keychainService,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        keychain.save(
            key: deviceSeedKey,
            data: deviceSeed,
            service: keychainService,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )

        let storedIdentity = keychain.load(key: currentIdentityKey, service: keychainService)
        let storedSeed = keychain.load(key: deviceSeedKey, service: keychainService)
        guard storedIdentity == encoded, storedSeed == deviceSeed else {
            // Best-effort rollback to the pre-restore snapshot.
            if let previousIdentity {
                keychain.save(
                    key: currentIdentityKey,
                    data: previousIdentity,
                    service: keychainService,
                    accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                )
            }
            if let previousSeed {
                keychain.save(
                    key: deviceSeedKey,
                    data: previousSeed,
                    service: keychainService,
                    accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                )
                deviceSeedCache = previousSeed
            } else {
                deviceSeedCache = nil
            }
            throw IdentityBackupError.persistenceFailed
        }

        deviceSeedCache = deviceSeed
        return identity
    }

    // MARK: - Per-Geohash Identities (Location Channels)

    /// Returns a stable device seed used to derive unlinkable per-geohash identities.
    /// Stored only on device keychain.
    private func getOrCreateDeviceSeed() -> Data {
        if let cached = deviceSeedCache { return cached }
        if let existing = keychain.load(key: deviceSeedKey, service: keychainService) {
            // Migrate to AfterFirstUnlockThisDeviceOnly for stability during lock
            keychain.save(key: deviceSeedKey, data: existing, service: keychainService, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            deviceSeedCache = existing
            return existing
        }
        // CryptoKit key generation cannot fail, unlike SecRandomCopyBytes —
        // a discarded failure here would persist an all-zero identity seed.
        let seed = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // Ensure availability after first unlock to prevent unintended rotation when locked
        keychain.save(key: deviceSeedKey, data: seed, service: keychainService, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        deviceSeedCache = seed
        return seed
    }

    /// Derive a deterministic, unlinkable Nostr identity for a mesh-bridge
    /// rendezvous cell. Distinct HMAC label keeps it unlinkable from the
    /// geohash-chat identity for the same cell string.
    func deriveIdentity(forBridgeRendezvous cell: String) throws -> NostrIdentity {
        try deriveIdentity(forGeohash: "bridge|" + cell)
    }

    /// Derive a deterministic, unlinkable Nostr identity for a given geohash.
    /// Uses HMAC-SHA256(deviceSeed, geohash) as private key material, with fallback rehashing
    /// if the candidate is not a valid secp256k1 private key.
    func deriveIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        // Check cache first to avoid repeated crypto + keychain I/O during view rendering
        cacheLock.lock()
        if let cached = derivedIdentityCache[geohash] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let seed = getOrCreateDeviceSeed()
        guard let msg = geohash.data(using: .utf8) else {
            throw NSError(domain: "NostrIdentity", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid geohash string"])
        }

        func candidateKey(iteration: UInt32) -> Data {
            var input = Data(msg)
            var iterBE = iteration.bigEndian
            withUnsafeBytes(of: &iterBE) { bytes in
                input.append(contentsOf: bytes)
            }
            let code = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: seed))
            return Data(code)
        }

        // Try a few iterations to ensure a valid key can be formed
        for i in 0..<10 {
            let keyData = candidateKey(iteration: UInt32(i))
            if let identity = try? NostrIdentity(privateKeyData: keyData) {
                // Cache the result
                cacheLock.lock()
                derivedIdentityCache[geohash] = identity
                cacheLock.unlock()
                return identity
            }
        }
        // As a final fallback, hash the seed+msg and try again
        let fallback = (seed + msg).sha256Hash()
        let identity = try NostrIdentity(privateKeyData: fallback)

        // Cache the result
        cacheLock.lock()
        derivedIdentityCache[geohash] = identity
        cacheLock.unlock()

        return identity
    }
}
