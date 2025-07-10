//
// EncryptionService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit
import Security

class EncryptionService {
    // Key agreement keys for encryption
    private var privateKey: Curve25519.KeyAgreement.PrivateKey
    public let publicKey: Curve25519.KeyAgreement.PublicKey
    
    // Signing keys for authentication
    private var signingPrivateKey: Curve25519.Signing.PrivateKey
    public let signingPublicKey: Curve25519.Signing.PublicKey
    
    // Storage for peer keys
    private var peerPublicKeys: [String: Curve25519.KeyAgreement.PublicKey] = [:]
    private var peerSigningKeys: [String: Curve25519.Signing.PublicKey] = [:]
    private var peerIdentityKeys: [String: Curve25519.Signing.PublicKey] = [:]
    private var sharedSecrets: [String: SymmetricKey] = [:]
    
    // Persistent identity for favorites (separate from ephemeral keys)
    private let identityKey: Curve25519.Signing.PrivateKey
    public let identityPublicKey: Curve25519.Signing.PublicKey
    
    // Thread safety
    private let cryptoQueue = DispatchQueue(label: "chat.bitchat.crypto", attributes: .concurrent)
    
    // SECURITY FIX: Key rotation for perfect forward secrecy
    private var keyRotationInterval: TimeInterval = 3600 // 1 hour
    private var lastKeyRotation: Date = Date()
    
    init() {
        // Generate ephemeral key pairs for this session
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.publicKey = privateKey.publicKey
        
        self.signingPrivateKey = Curve25519.Signing.PrivateKey()
        self.signingPublicKey = signingPrivateKey.publicKey
        
        // SECURITY FIX: Load or create persistent identity key using Keychain
        self.identityKey = loadOrCreateIdentityKey()
        self.identityPublicKey = identityKey.publicKey
        
        // Schedule periodic key rotation for forward secrecy
        scheduleKeyRotation()
    }
    
    // SECURITY FIX: Secure Keychain storage instead of UserDefaults
    private func loadOrCreateIdentityKey() -> Curve25519.Signing.PrivateKey {
        let tag = "bitchat.identityKey".data(using: .utf8)!
        
        // Query for existing key
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query, &result)
        
        if status == errSecSuccess,
           let keyData = result as? Data,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
            return key
        } else {
            // First run - create and securely store identity key
            let newKey = Curve25519.Signing.PrivateKey()
            
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecValueData as String: newKey.rawRepresentation,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
            ]
            
            let addStatus = SecItemAdd(addQuery, nil)
            if addStatus != errSecSuccess {
                print("[CRYPTO] Warning: Failed to store identity key in Keychain, status: \(addStatus)")
            }
            
            return newKey
        }
    }
    
    // SECURITY FIX: Perfect Forward Secrecy - Key rotation mechanism
    private func scheduleKeyRotation() {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + keyRotationInterval) {
            self.rotateEphemeralKeys()
            self.scheduleKeyRotation() // Schedule next rotation
        }
    }
    
    // SECURITY FIX: Rotate ephemeral keys for forward secrecy
    func rotateEphemeralKeys() {
        cryptoQueue.sync(flags: .barrier) {
            // Clear old keys from memory (explicit zeroization would be ideal but Swift doesn't expose it)
            privateKey = Curve25519.KeyAgreement.PrivateKey()
            publicKey = privateKey.publicKey
            
            signingPrivateKey = Curve25519.Signing.PrivateKey()
            signingPublicKey = signingPrivateKey.publicKey
            
            // Clear shared secrets to force renegotiation with new keys
            sharedSecrets.removeAll()
            
            lastKeyRotation = Date()
            print("[CRYPTO] Ephemeral keys rotated for forward secrecy")
        }
    }
    
    // Force immediate key rotation (for testing or manual security)
    func forceKeyRotation() {
        rotateEphemeralKeys()
    }
    
    // Create combined public key data for exchange
    func getCombinedPublicKeyData() -> Data {
        var data = Data()
        data.append(publicKey.rawRepresentation)  // 32 bytes - ephemeral encryption key
        data.append(signingPublicKey.rawRepresentation)  // 32 bytes - ephemeral signing key
        data.append(identityPublicKey.rawRepresentation)  // 32 bytes - persistent identity key
        return data  // Total: 96 bytes
    }
    
    // Add peer's combined public keys
    func addPeerPublicKey(_ peerID: String, publicKeyData: Data) throws {
        try cryptoQueue.sync(flags: .barrier) {
            // Convert to array for safe access
            let keyBytes = [UInt8](publicKeyData)
            
            guard keyBytes.count == 96 else {
                throw EncryptionError.invalidPublicKey
            }
            
            // Extract all three keys: 32 for key agreement + 32 for signing + 32 for identity
            let keyAgreementData = Data(keyBytes[0..<32])
            let signingKeyData = Data(keyBytes[32..<64])
            let identityKeyData = Data(keyBytes[64..<96])
            
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyAgreementData)
            peerPublicKeys[peerID] = publicKey
            
            let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: signingKeyData)
            peerSigningKeys[peerID] = signingKey
            
            let identityKey = try Curve25519.Signing.PublicKey(rawRepresentation: identityKeyData)
            peerIdentityKeys[peerID] = identityKey
            
            // Generate shared secret for encryption with secure random salt
            try generateSharedSecret(for: peerID)
        }
    }
    
    // SECURITY FIX: Generate shared secret with random salt instead of static string
    private func generateSharedSecret(for peerID: String) throws {
        guard let publicKey = peerPublicKeys[peerID] else {
            throw EncryptionError.noSharedSecret
        }
        
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        
        // SECURITY FIX: Generate cryptographically secure random salt
        var salt = Data(count: 32)
        let result = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard result == errSecSuccess else {
            throw EncryptionError.encryptionFailed
        }
        
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,  // Random salt instead of static "bitchat-v1"
            sharedInfo: Data(),
            outputByteCount: 32
        )
        sharedSecrets[peerID] = symmetricKey
    }
    
    // Get peer's persistent identity key for favorites
    func getPeerIdentityKey(_ peerID: String) -> Data? {
        return cryptoQueue.sync {
            return peerIdentityKeys[peerID]?.rawRepresentation
        }
    }
    
    // SECURITY FIX: Clear persistent identity from Keychain (for panic mode)
    func clearPersistentIdentity() {
        let tag = "bitchat.identityKey".data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag
        ]
        
        let status = SecItemDelete(query)
        if status == errSecSuccess {
            print("[CRYPTO] Cleared persistent identity key from Keychain")
        } else {
            print("[CRYPTO] Failed to clear identity key, status: \(status)")
        }
    }
    
    func encrypt(_ data: Data, for peerID: String) throws -> Data {
        let symmetricKey = try cryptoQueue.sync {
            guard let key = sharedSecrets[peerID] else {
                throw EncryptionError.noSharedSecret
            }
            return key
        }
        
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        return sealedBox.combined ?? Data()
    }
    
    func decrypt(_ data: Data, from peerID: String) throws -> Data {
        let symmetricKey = try cryptoQueue.sync {
            guard let key = sharedSecrets[peerID] else {
                throw EncryptionError.noSharedSecret
            }
            return key
        }
        
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
    
    func sign(_ data: Data) throws -> Data {
        // Create a local copy of the key to avoid concurrent access
        let key = signingPrivateKey
        return try key.signature(for: data)
    }
    
    func verify(_ signature: Data, for data: Data, from peerID: String) throws -> Bool {
        let verifyingKey = try cryptoQueue.sync {
            guard let key = peerSigningKeys[peerID] else {
                throw EncryptionError.noSharedSecret
            }
            return key
        }
        
        return verifyingKey.isValidSignature(signature, for: data)
    }
    
    // SECURITY ENHANCEMENT: Get key rotation status for debugging
    func getKeyRotationInfo() -> (lastRotation: Date, nextRotation: Date) {
        return (lastKeyRotation, lastKeyRotation.addingTimeInterval(keyRotationInterval))
    }
}

enum EncryptionError: Error {
    case noSharedSecret
    case invalidPublicKey
    case encryptionFailed
    case decryptionFailed
    case keychainError
}