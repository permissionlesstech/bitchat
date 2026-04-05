import Foundation
import CryptoKit

/// Minimal keychain access required by NostrIdentityBridge.
public protocol NostrKeychainStoring: Sendable {
    func save(key: String, data: Data, service: String, accessible: CFString?)
    func load(key: String, service: String) -> Data?
}

/// Bridge between Noise and Nostr identities
public final class NostrIdentityBridge {
    private let keychainService = "chat.bitchat.nostr"
    private let currentIdentityKey = "nostr-current-identity"
    private let deviceSeedKey = "nostr-device-seed"
    private let deviceSeedCache: NSLock = NSLock()
    private var _deviceSeedCacheValue: Data?
    // Cache derived identities to avoid repeated crypto during view rendering
    private var _derivedIdentityCache: [String: NostrIdentity] = [:]
    private let cacheLock = NSLock()

    private let keychain: any NostrKeychainStoring

    public init(keychain: any NostrKeychainStoring) {
        self.keychain = keychain
    }

    /// Get or create the current Nostr identity
    public func getCurrentNostrIdentity() throws -> NostrIdentity? {
        if let existingData = keychain.load(key: currentIdentityKey, service: keychainService),
           let identity = try? JSONDecoder().decode(NostrIdentity.self, from: existingData) {
            return identity
        }

        let nostrIdentity = try NostrIdentity.generate()

        let data = try JSONEncoder().encode(nostrIdentity)
        keychain.save(key: currentIdentityKey, data: data, service: keychainService, accessible: nil)

        return nostrIdentity
    }

    /// Associate a Nostr identity with a Noise public key (for favorites)
    public func associateNostrIdentity(_ nostrPubkey: String, with noisePublicKey: Data) {
        let key = "nostr-noise-\(noisePublicKey.base64EncodedString())"
        if let data = nostrPubkey.data(using: .utf8) {
            keychain.save(key: key, data: data, service: keychainService, accessible: nil)
        }
    }

    /// Get Nostr public key associated with a Noise public key
    public func getNostrPublicKey(for noisePublicKey: Data) -> String? {
        let key = "nostr-noise-\(noisePublicKey.base64EncodedString())"
        guard let data = keychain.load(key: key, service: keychainService),
              let pubkey = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pubkey
    }

    /// Clear all Nostr identity associations and current identity
    public func clearAllAssociations() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                var deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: keychainService
                ]
                if let account = item[kSecAttrAccount as String] as? String {
                    deleteQuery[kSecAttrAccount as String] = account
                }
                SecItemDelete(deleteQuery as CFDictionary)
            }
        }

        deviceSeedCache.lock()
        _deviceSeedCacheValue = nil
        deviceSeedCache.unlock()
    }

    // MARK: - Per-Geohash Identities (Location Channels)

    private func getOrCreateDeviceSeed() -> Data {
        deviceSeedCache.lock()
        if let cached = _deviceSeedCacheValue {
            deviceSeedCache.unlock()
            return cached
        }
        deviceSeedCache.unlock()

        if let existing = keychain.load(key: deviceSeedKey, service: keychainService) {
            keychain.save(key: deviceSeedKey, data: existing, service: keychainService, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            deviceSeedCache.lock()
            _deviceSeedCacheValue = existing
            deviceSeedCache.unlock()
            return existing
        }
        var seed = Data(count: 32)
        _ = seed.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        keychain.save(key: deviceSeedKey, data: seed, service: keychainService, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        deviceSeedCache.lock()
        _deviceSeedCacheValue = seed
        deviceSeedCache.unlock()
        return seed
    }

    /// Derive a deterministic, unlinkable Nostr identity for a given geohash.
    public func deriveIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        cacheLock.lock()
        if let cached = _derivedIdentityCache[geohash] {
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

        for i in 0..<10 {
            let keyData = candidateKey(iteration: UInt32(i))
            if let identity = try? NostrIdentity(privateKeyData: keyData) {
                cacheLock.lock()
                _derivedIdentityCache[geohash] = identity
                cacheLock.unlock()
                return identity
            }
        }

        let fallback = (seed + msg).sha256Hash()
        let identity = try NostrIdentity(privateKeyData: fallback)

        cacheLock.lock()
        _derivedIdentityCache[geohash] = identity
        cacheLock.unlock()

        return identity
    }
}
