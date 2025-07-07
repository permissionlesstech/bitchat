//
// EncryptionService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

class EncryptionService {
    // Key agreement keys for encryption (Curve25519)
    private var privateKey: Curve25519.KeyAgreement.PrivateKey
    public let publicKey: Curve25519.KeyAgreement.PublicKey
    
    // Legacy Curve25519 signing keys (for backwards compatibility)
    private var signingPrivateKey: Curve25519.Signing.PrivateKey
    public let signingPublicKey: Curve25519.Signing.PublicKey
    
    // P256 signing public keys from DeviceIdentity (for unified identity)
    public var p256PublicKey: Data {
        DeviceIdentity.shared.publicKeyData
    }
    
    // Storage for peer keys
    private var peerPublicKeys: [String: Curve25519.KeyAgreement.PublicKey] = [:]
    private var peerSigningKeys: [String: Curve25519.Signing.PublicKey] = [:]  // Legacy Curve25519
    private var peerIdentityKeys: [String: Curve25519.Signing.PublicKey] = [:]  // Legacy Curve25519
    private var peerP256Keys: [String: P256.Signing.PublicKey] = [:]  // P256 public keys for unified identity
    private var sharedSecrets: [String: SymmetricKey] = [:]
    
    // Persistent identity for favorites (separate from ephemeral keys)
    private let identityKey: Curve25519.Signing.PrivateKey
    public let identityPublicKey: Curve25519.Signing.PublicKey
    
    // Thread safety
    private let cryptoQueue = DispatchQueue(label: "chat.bitchat.crypto", attributes: .concurrent)
    
    init() {
        // Generate ephemeral key pairs for this session
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.publicKey = privateKey.publicKey
        
        self.signingPrivateKey = Curve25519.Signing.PrivateKey()
        self.signingPublicKey = signingPrivateKey.publicKey
        
        // Load or create persistent identity key
        if let identityData = UserDefaults.standard.data(forKey: "bitchat.identityKey"),
           let loadedKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: identityData) {
            self.identityKey = loadedKey
        } else {
            // First run - create and save identity key
            self.identityKey = Curve25519.Signing.PrivateKey()
            UserDefaults.standard.set(identityKey.rawRepresentation, forKey: "bitchat.identityKey")
        }
        self.identityPublicKey = identityKey.publicKey
    }
    
    // Create combined public key data for exchange
    func getCombinedPublicKeyData() -> Data {
        var data = Data()
        data.append(publicKey.rawRepresentation)  // 32 bytes - ephemeral encryption key
        data.append(signingPublicKey.rawRepresentation)  // 32 bytes - ephemeral signing key (legacy)
        data.append(identityPublicKey.rawRepresentation)  // 32 bytes - persistent identity key (legacy)
        data.append(p256PublicKey)  // 65 bytes - P256 public key for unified identity
        return data  // Total: 161 bytes
    }
    
    // Add peer's combined public keys
    // Supports two formats:
    // - Legacy: 96 bytes (32 + 32 + 32) - Curve25519 keys only
    // - Unified: 161 bytes (32 + 32 + 32 + 65) - Curve25519 + P256 keys
    func addPeerPublicKey(_ peerID: String, publicKeyData: Data) throws {
        try cryptoQueue.sync(flags: .barrier) {
            // Convert to array for safe access
            let keyBytes = [UInt8](publicKeyData)
            
            // Support both legacy (96 bytes) and new format (161 bytes)
            if keyBytes.count == 96 {
                // Legacy format: 32 + 32 + 32
                let keyAgreementData = Data(keyBytes[0..<32])
                let signingKeyData = Data(keyBytes[32..<64])
                let identityKeyData = Data(keyBytes[64..<96])
                
                let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyAgreementData)
                peerPublicKeys[peerID] = publicKey
                
                let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: signingKeyData)
                peerSigningKeys[peerID] = signingKey
                
                let identityKey = try Curve25519.Signing.PublicKey(rawRepresentation: identityKeyData)
                peerIdentityKeys[peerID] = identityKey
                
                // No P256 key in legacy format
                peerP256Keys.removeValue(forKey: peerID)
                
            } else if keyBytes.count == 161 {
                // New format: 32 + 32 + 32 + 65
                let keyAgreementData = Data(keyBytes[0..<32])
                let signingKeyData = Data(keyBytes[32..<64])
                let identityKeyData = Data(keyBytes[64..<96])
                let p256KeyData = Data(keyBytes[96..<161])
                
                let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyAgreementData)
                peerPublicKeys[peerID] = publicKey
                
                let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: signingKeyData)
                peerSigningKeys[peerID] = signingKey
                
                let identityKey = try Curve25519.Signing.PublicKey(rawRepresentation: identityKeyData)
                peerIdentityKeys[peerID] = identityKey
                
                let p256Key = try P256.Signing.PublicKey(x963Representation: p256KeyData)
                peerP256Keys[peerID] = p256Key
                
            } else {
                throw EncryptionError.invalidPublicKey
            }
            
            // Generate shared secret for encryption
            if let publicKey = peerPublicKeys[peerID] {
                let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
                let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                    using: SHA256.self,
                    salt: "bitchat-v1".data(using: .utf8)!,
                    sharedInfo: Data(),
                    outputByteCount: 32
                )
                sharedSecrets[peerID] = symmetricKey
            }
        }
    }
    
    // Get peer's persistent identity key for favorites
    func getPeerIdentityKey(_ peerID: String) -> Data? {
        return cryptoQueue.sync {
            return peerIdentityKeys[peerID]?.rawRepresentation
        }
    }
    
    // Clear persistent identity (for panic mode)
    func clearPersistentIdentity() {
        UserDefaults.standard.removeObject(forKey: "bitchat.identityKey")
        // print("[CRYPTO] Cleared persistent identity key")
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
    
    func getPublicKey(for peerID: String) -> Data? {
        return cryptoQueue.sync {
            // Return the raw public key data for the peer
            // Note: This returns Curve25519 signing public key (32 bytes)
            // which is incompatible with DeviceIdentity.verify() that expects P256 keys (65 bytes)
            return peerSigningKeys[peerID]?.rawRepresentation
        }
    }
    
    // Get peer's P256 public key for unified identity verification
    func getP256PublicKey(for peerID: String) -> P256.Signing.PublicKey? {
        return cryptoQueue.sync {
            return peerP256Keys[peerID]
        }
    }
    
    // Sign with P256 for unified identity
    func signWithP256(_ data: Data) throws -> Data {
        return try DeviceIdentity.shared.sign(data)
    }
    
    // Verify P256 signature for unified identity
    func verifyP256Signature(_ signature: Data, for data: Data, from peerID: String) -> Bool {
        guard let publicKey = getP256PublicKey(for: peerID) else {
            // Fallback to legacy verification if no P256 key
            return (try? verify(signature, for: data, from: peerID)) ?? false
        }
        return DeviceIdentity.shared.verify(signature: signature, for: data, using: publicKey)
    }
    
}

enum EncryptionError: Error {
    case noSharedSecret
    case invalidPublicKey
    case encryptionFailed
    case decryptionFailed
}