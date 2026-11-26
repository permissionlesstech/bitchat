import BitFoundation
import Foundation
import CryptoKit

/// Bridge between Noise and Nostr identities
final class NostrIdentityBridge {
    private let keychainService = "chat.bitchat.nostr"
    private let currentIdentityKey = "nostr-current-identity"
    private let deviceSeedKey = "nostr-device-seed"
    // In-memory cache to avoid transient keychain access issues
    private var currentIdentityCache: NostrIdentity?
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
        cacheLock.lock()
        if let cached = currentIdentityCache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Distinguish missing vs transiently unavailable Keychain so a locked-device
        // read neither overwrites an existing identity nor caches a throwaway key.
        switch keychain.loadWithResult(key: currentIdentityKey, service: keychainService) {
        case .success(let existingData):
            if let identity = try? JSONDecoder().decode(NostrIdentity.self, from: existingData) {
                cacheLock.lock()
                currentIdentityCache = identity
                cacheLock.unlock()
                return identity
            }
        case .itemNotFound:
            break
        case .deviceLocked, .accessDenied, .authenticationFailed, .otherError:
            return nil
        }

        // Generate new Nostr identity
        let nostrIdentity = try NostrIdentity.generate()

        // Store it and confirm retention before caching, since save is void-returning
        let data = try JSONEncoder().encode(nostrIdentity)
        keychain.save(key: currentIdentityKey, data: data, service: keychainService, accessible: nil)

        if case .success(let stored) = keychain.loadWithResult(key: currentIdentityKey, service: keychainService),
           stored == data {
            cacheLock.lock()
            currentIdentityCache = nostrIdentity
            cacheLock.unlock()
        }

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
    
    /// Drop in-memory private key caches without touching Keychain.
    /// Used by shadow service bridges during panic wipe so post-panic events
    /// cannot keep signing with pre-panic keys cached in memory.
    func clearInMemoryCaches() {
        cacheLock.lock()
        currentIdentityCache = nil
        deviceSeedCache = nil
        derivedIdentityCache.removeAll()
        cacheLock.unlock()
    }

    /// Clear all Nostr identity associations and current identity
    func clearAllAssociations() {
        // Must go through the injected keychain, not raw SecItem calls:
        // under test that keychain is in-memory, and a direct delete here
        // would wipe the developer's real Nostr identity on every test run.
        keychain.deleteAll(service: keychainService)

        // Also drop the in-memory derived per-geohash identities and seed. These
        // hold actual secp256k1 private keys; if left cached, post-panic geohash
        // messages would still be signed with pre-panic keys (linkable across the
        // wipe) until the app is force-quit.
        clearInMemoryCaches()
    }

    // MARK: - Per-Geohash Identities (Location Channels)

    /// Returns a stable device seed used to derive unlinkable per-geohash identities,
    /// along with whether the seed is durably backed by Keychain and safe to cache.
    private func getOrCreateDeviceSeed() -> (seed: Data, durable: Bool) {
        cacheLock.lock()
        if let cached = deviceSeedCache {
            cacheLock.unlock()
            return (cached, true)
        }
        cacheLock.unlock()

        switch keychain.loadWithResult(key: deviceSeedKey, service: keychainService) {
        case .success(let existing):
            cacheLock.lock()
            deviceSeedCache = existing
            cacheLock.unlock()
            return (existing, true)
        case .itemNotFound:
            break
        case .deviceLocked, .accessDenied, .authenticationFailed, .otherError:
            // Preserve the retry path without overwriting or caching a temporary seed.
            let ephemeralSeed = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            return (ephemeralSeed, false)
        }

        // CryptoKit key generation cannot fail, unlike SecRandomCopyBytes —
        // a discarded failure here would persist an all-zero identity seed.
        let seed = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // Ensure availability after first unlock to prevent unintended rotation when locked
        keychain.save(key: deviceSeedKey, data: seed, service: keychainService, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        let persisted: Bool
        if case .success(let stored) = keychain.loadWithResult(key: deviceSeedKey, service: keychainService),
           stored == seed {
            cacheLock.lock()
            deviceSeedCache = seed
            cacheLock.unlock()
            persisted = true
        } else {
            persisted = false
        }
        return (seed, persisted)
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

        let (seed, durable) = getOrCreateDeviceSeed()
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
                if durable {
                    cacheLock.lock()
                    derivedIdentityCache[geohash] = identity
                    cacheLock.unlock()
                }
                return identity
            }
        }
        // As a final fallback, hash the seed+msg and try again
        let fallback = (seed + msg).sha256Hash()
        let identity = try NostrIdentity(privateKeyData: fallback)

        if durable {
            cacheLock.lock()
            derivedIdentityCache[geohash] = identity
            cacheLock.unlock()
        }

        return identity
    }
}
