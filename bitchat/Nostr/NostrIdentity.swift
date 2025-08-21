import Foundation
import CryptoKit
import P256K
import Security

// Keychain helper for secure storage
struct KeychainHelper {
    static func save(key: String, data: Data, service: String, accessible: CFString? = nil) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        if let accessible = accessible {
            query[kSecAttrAccessible as String] = accessible
        }
        
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    static func load(key: String, service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
    
    static func delete(key: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}

/// Manages Nostr identity (secp256k1 keypair) for NIP-17 private messaging
struct NostrIdentity: Codable {
    let privateKey: Data
    let publicKey: Data
    let npub: String // Bech32-encoded public key
    let createdAt: Date
    
    /// Memberwise initializer
    init(privateKey: Data, publicKey: Data, npub: String, createdAt: Date) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.npub = npub
        self.createdAt = createdAt
    }
    
    /// Generate a new Nostr identity
    static func generate() throws -> NostrIdentity {
        // Generate Schnorr key for Nostr
        let schnorrKey = try P256K.Schnorr.PrivateKey()
        let xOnlyPubkey = Data(schnorrKey.xonly.bytes)
        let npub = try Bech32.encode(hrp: "npub", data: xOnlyPubkey)
        
        return NostrIdentity(
            privateKey: schnorrKey.dataRepresentation,
            publicKey: xOnlyPubkey, // Store x-only public key
            npub: npub,
            createdAt: Date()
        )
    }
    
    /// Initialize from existing private key data
    init(privateKeyData: Data) throws {
        let schnorrKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKeyData)
        let xOnlyPubkey = Data(schnorrKey.xonly.bytes)
        
        self.privateKey = privateKeyData
        self.publicKey = xOnlyPubkey
        self.npub = try Bech32.encode(hrp: "npub", data: xOnlyPubkey)
        self.createdAt = Date()
    }
    
    /// Get signing key for event signatures
    func signingKey() throws -> P256K.Signing.PrivateKey {
        try P256K.Signing.PrivateKey(dataRepresentation: privateKey)
    }
    
    /// Get Schnorr signing key for Nostr event signatures
    func schnorrSigningKey() throws -> P256K.Schnorr.PrivateKey {
        try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
    }
    
    /// Get hex-encoded public key (for Nostr events)
    var publicKeyHex: String {
        // Public key is already stored as x-only (32 bytes)
        return publicKey.hexEncodedString()
    }
}

/// Bridge between Noise and Nostr identities
struct NostrIdentityBridge {
    private static let keychainService = "chat.bitchat.nostr"
    private static let currentIdentityKey = "nostr-current-identity"
    private static let deviceSeedKey = "nostr-device-seed"
    // In-memory cache to avoid transient keychain access issues
    private static var deviceSeedCache: Data?
    
    /// Get or create the current Nostr identity
    static func getCurrentNostrIdentity() throws -> NostrIdentity? {
        // Check if we already have a Nostr identity
        if let existingData = KeychainHelper.load(key: currentIdentityKey, service: keychainService),
           let identity = try? JSONDecoder().decode(NostrIdentity.self, from: existingData) {
            return identity
        }
        
        // Generate new Nostr identity
        let nostrIdentity = try NostrIdentity.generate()
        
        // Store it
        let data = try JSONEncoder().encode(nostrIdentity)
        KeychainHelper.save(key: currentIdentityKey, data: data, service: keychainService)
        
        return nostrIdentity
    }
    
    /// Associate a Nostr identity with a Noise public key (for favorites)
    static func associateNostrIdentity(_ nostrPubkey: String, with noisePublicKey: Data) {
        let key = "nostr-noise-\(noisePublicKey.base64EncodedString())"
        if let data = nostrPubkey.data(using: .utf8) {
            KeychainHelper.save(key: key, data: data, service: keychainService)
        }
    }
    
    /// Get Nostr public key associated with a Noise public key
    static func getNostrPublicKey(for noisePublicKey: Data) -> String? {
        let key = "nostr-noise-\(noisePublicKey.base64EncodedString())"
        guard let data = KeychainHelper.load(key: key, service: keychainService),
              let pubkey = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pubkey
    }
    
    /// Clear all Nostr identity associations and current identity
    static func clearAllAssociations() {
        // Delete current Nostr identity
        KeychainHelper.delete(key: currentIdentityKey, service: keychainService)
        KeychainHelper.delete(key: deviceSeedKey, service: keychainService)
        
        // Note: We can't efficiently delete all noise-nostr associations 
        // without tracking them, but they'll be orphaned and eventually cleaned up
        // The important part is deleting the current identity so a new one is generated
    }

    // MARK: - Per-Geohash Identities (Location Channels)

    /// Returns a stable device seed used to derive unlinkable per-geohash identities.
    /// Stored only on device keychain.
    private static func getOrCreateDeviceSeed() -> Data {
        if let cached = deviceSeedCache { return cached }
        if let existing = KeychainHelper.load(key: deviceSeedKey, service: keychainService) {
            // Migrate to AfterFirstUnlockThisDeviceOnly for stability during lock
            KeychainHelper.save(key: deviceSeedKey, data: existing, service: keychainService, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            deviceSeedCache = existing
            return existing
        }
        var seed = Data(count: 32)
        _ = seed.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        // Ensure availability after first unlock to prevent unintended rotation when locked
        KeychainHelper.save(key: deviceSeedKey, data: seed, service: keychainService, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        deviceSeedCache = seed
        return seed
    }

    /// Derive a deterministic, unlinkable Nostr identity for a given geohash.
    /// Uses HMAC-SHA256(deviceSeed, geohash) as private key material, with fallback rehashing
    /// if the candidate is not a valid secp256k1 private key.
    static func deriveIdentity(forGeohash geohash: String) throws -> NostrIdentity {
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
            let code = CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(for: input, using: SymmetricKey(data: seed))
            return Data(code)
        }

        // Try a few iterations to ensure a valid key can be formed
        for i in 0..<10 {
            let keyData = candidateKey(iteration: UInt32(i))
            if let identity = try? NostrIdentity(privateKeyData: keyData) {
                return identity
            }
        }
        // As a final fallback, hash the seed+msg and try again
        var combined = Data()
        combined.append(seed)
        combined.append(msg)
        let fallback = Data(CryptoKit.SHA256.hash(data: combined))
        return try NostrIdentity(privateKeyData: fallback)
    }
}

// Bech32 encoding for Nostr (minimal implementation)
enum Bech32 {
    private static let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    private static let generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    
    static func encode(hrp: String, data: Data) throws -> String {
        let values = convertBits(from: 8, to: 5, pad: true, data: Array(data))
        let checksum = createChecksum(hrp: hrp, values: values)
        let combined = values + checksum
        
        return hrp + "1" + combined.map { 
            let index = charset.index(charset.startIndex, offsetBy: Int($0))
            return String(charset[index])
        }.joined()
    }
    
    static func decode(_ bech32String: String) throws -> (hrp: String, data: Data) {
        // Find the last occurrence of '1'
        guard let separatorIndex = bech32String.lastIndex(of: "1") else {
            throw Bech32Error.invalidFormat
        }
        
        let hrp = String(bech32String[..<separatorIndex])
        
        // Validate HRP contains only ASCII characters
        for char in hrp {
            guard char.asciiValue != nil else {
                throw Bech32Error.invalidCharacter
            }
        }
        
        let dataString = String(bech32String[bech32String.index(after: separatorIndex)...])
        
        // Convert characters to values
        var values = [UInt8]()
        for char in dataString {
            guard let index = charset.firstIndex(of: char) else {
                throw Bech32Error.invalidCharacter
            }
            values.append(UInt8(charset.distance(from: charset.startIndex, to: index)))
        }
        
        // Verify checksum
        guard values.count >= 6 else {
            throw Bech32Error.invalidChecksum
        }
        
        let payloadValues = Array(values.dropLast(6))
        let checksum = Array(values.suffix(6))
        let expectedChecksum = createChecksum(hrp: hrp, values: payloadValues)
        
        guard checksum == expectedChecksum else {
            throw Bech32Error.invalidChecksum
        }
        
        // Convert back to bytes
        let bytes = convertBits(from: 5, to: 8, pad: false, data: payloadValues)
        return (hrp: hrp, data: Data(bytes))
    }
    
    enum Bech32Error: Error {
        case invalidFormat
        case invalidCharacter
        case invalidChecksum
    }
    
    private static func convertBits(from: Int, to: Int, pad: Bool, data: [UInt8]) -> [UInt8] {
        var acc = 0
        var bits = 0
        var result = [UInt8]()
        let maxv = (1 << to) - 1
        
        for value in data {
            acc = (acc << from) | Int(value)
            bits += from
            
            while bits >= to {
                bits -= to
                result.append(UInt8((acc >> bits) & maxv))
            }
        }
        
        if pad && bits > 0 {
            result.append(UInt8((acc << (to - bits)) & maxv))
        }
        
        return result
    }
    
    private static func createChecksum(hrp: String, values: [UInt8]) -> [UInt8] {
        let checksumValues = hrpExpand(hrp) + values + [0, 0, 0, 0, 0, 0]
        let polymod = polymod(checksumValues) ^ 1
        var checksum = [UInt8]()
        
        for i in 0..<6 {
            checksum.append(UInt8((polymod >> (5 * (5 - i))) & 31))
        }
        
        return checksum
    }
    
    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var result = [UInt8]()
        for c in hrp {
            guard let asciiValue = c.asciiValue else {
                return [] // Return empty array for invalid input
            }
            result.append(UInt8(asciiValue >> 5))
        }
        result.append(0)
        for c in hrp {
            guard let asciiValue = c.asciiValue else {
                return [] // Return empty array for invalid input
            }
            result.append(UInt8(asciiValue & 31))
        }
        return result
    }
    
    private static func polymod(_ values: [UInt8]) -> Int {
        var chk = 1
        for value in values {
            let b = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ Int(value)
            for i in 0..<5 {
                if (b >> i) & 1 == 1 {
                    chk ^= generator[i]
                }
            }
        }
        return chk
    }
}

// Data hex encoding extension moved to BinaryEncodingUtils.swift to avoid duplication
