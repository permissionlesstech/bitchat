import BitFoundation
import Foundation
import CryptoKit

enum NostrIdentityBridgeError: Error, Equatable {
    case identityReadUnavailable
    case invalidStoredIdentity
    case identityPersistenceFailed
}

/// Bridge between Noise and Nostr identities
final class NostrIdentityBridge {
    private let keychainService = "chat.bitchat.nostr"
    private let currentIdentityKey = "nostr-current-identity"
    private let deviceSeedKey = "nostr-device-seed"
    // Multiple production owners construct their own bridge. Creation and
    // panic deletion of the shared current-identity keychain item must still
    // be one process-wide lifecycle, or concurrent bridges can return
    // different keys or an in-flight save can resurrect a wiped identity.
    private static let identityLifecycleLock = NSLock()
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
        Self.identityLifecycleLock.lock()
        defer { Self.identityLifecycleLock.unlock() }

        switch keychain.loadWithResult(
            key: currentIdentityKey,
            service: keychainService
        ) {
        case .success(let existingData):
            guard let identity = try? JSONDecoder().decode(
                NostrIdentity.self,
                from: existingData
            ) else {
                throw NostrIdentityBridgeError.invalidStoredIdentity
            }
            return identity
        case .itemNotFound:
            break
        case .accessDenied, .deviceLocked, .authenticationFailed,
                .otherError:
            throw NostrIdentityBridgeError.identityReadUnavailable
        }
        
        // Generate new Nostr identity
        let nostrIdentity = try NostrIdentity.generate()
        
        // Store it
        let data = try JSONEncoder().encode(nostrIdentity)
        keychain.save(key: currentIdentityKey, data: data, service: keychainService, accessible: nil)
        guard case .success(let persistedData) = keychain.loadWithResult(
            key: currentIdentityKey,
            service: keychainService
        ),
            persistedData == data,
            let persistedIdentity = try? JSONDecoder().decode(
                NostrIdentity.self,
                from: persistedData
            ),
            persistedIdentity.publicKeyHex == nostrIdentity.publicKeyHex
        else {
            throw NostrIdentityBridgeError.identityPersistenceFailed
        }

        return persistedIdentity
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
        Self.identityLifecycleLock.lock()
        defer { Self.identityLifecycleLock.unlock() }

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
        var seed = Data(count: 32)
        _ = seed.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
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
