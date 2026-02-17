//
// EncryptionService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

/// End-to-end encryption service built on Curve25519 (X25519 key agreement + Ed25519 signing).
///
/// Each session generates **ephemeral** key-agreement and signing key pairs.
/// A **persistent** Ed25519 identity key is stored across sessions for the favorites system.
///
/// Thread-safe: all mutable key storage is protected by a concurrent dispatch queue
/// with barrier writes.
class EncryptionService {
    /// Ephemeral Curve25519 key-agreement private key (regenerated each session).
    private var privateKey: Curve25519.KeyAgreement.PrivateKey
    /// Ephemeral Curve25519 key-agreement public key shared with peers.
    public let publicKey: Curve25519.KeyAgreement.PublicKey

    /// Ephemeral Ed25519 signing private key (regenerated each session).
    private var signingPrivateKey: Curve25519.Signing.PrivateKey
    /// Ephemeral Ed25519 signing public key shared with peers.
    public let signingPublicKey: Curve25519.Signing.PublicKey

    private var peerPublicKeys: [String: Curve25519.KeyAgreement.PublicKey] = [:]
    private var peerSigningKeys: [String: Curve25519.Signing.PublicKey] = [:]
    private var peerIdentityKeys: [String: Curve25519.Signing.PublicKey] = [:]
    private var sharedSecrets: [String: SymmetricKey] = [:]

    /// Persistent Ed25519 identity key, persisted in `UserDefaults` and used for the favorites system.
    private let identityKey: Curve25519.Signing.PrivateKey
    /// Public half of the persistent identity key.
    public let identityPublicKey: Curve25519.Signing.PublicKey

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
    
    /// Returns a 96-byte blob containing three 32-byte Curve25519 public keys concatenated in order:
    /// ephemeral key-agreement key, ephemeral signing key, persistent identity key.
    ///
    /// This blob is transmitted during the key-exchange handshake so the remote peer
    /// can set up encryption, signature verification, and identity tracking in one round-trip.
    func getCombinedPublicKeyData() -> Data {
        var data = Data()
        data.append(publicKey.rawRepresentation)  // 32 bytes - ephemeral encryption key
        data.append(signingPublicKey.rawRepresentation)  // 32 bytes - ephemeral signing key
        data.append(identityPublicKey.rawRepresentation)  // 32 bytes - persistent identity key
        return data  // Total: 96 bytes
    }
    
    /// Registers a peer's 96-byte combined public key blob and derives a shared AES-256 secret.
    ///
    /// The blob layout must match ``getCombinedPublicKeyData()``:
    /// bytes 0–31 key-agreement, 32–63 signing, 64–95 identity.
    ///
    /// - Parameters:
    ///   - peerID: The remote peer's identifier string.
    ///   - publicKeyData: Exactly 96 bytes of concatenated public keys.
    /// - Throws: ``EncryptionError/invalidPublicKey`` if the data is not 96 bytes, or a CryptoKit error.
    func addPeerPublicKey(_ peerID: String, publicKeyData: Data) throws {
        try cryptoQueue.sync(flags: .barrier) {
            // Convert to array for safe access
            let keyBytes = [UInt8](publicKeyData)
            
            guard keyBytes.count == 96 else {
                // print("[CRYPTO] Invalid public key data size: \(keyBytes.count), expected 96")
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
            
            // Stored all three keys for peer
            
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
    
    /// Returns the raw 32-byte representation of a peer's persistent identity public key, or `nil` if unknown.
    func getPeerIdentityKey(_ peerID: String) -> Data? {
        return cryptoQueue.sync {
            return peerIdentityKeys[peerID]?.rawRepresentation
        }
    }
    
    /// Erases the persistent identity key from `UserDefaults` (panic / emergency wipe mode).
    func clearPersistentIdentity() {
        UserDefaults.standard.removeObject(forKey: "bitchat.identityKey")
        // print("[CRYPTO] Cleared persistent identity key")
    }
    
    /// Encrypts `data` for a specific peer using AES-256-GCM with the previously derived shared secret.
    ///
    /// - Throws: ``EncryptionError/noSharedSecret`` if no key exchange has occurred with `peerID`.
    /// - Returns: The combined AES-GCM ciphertext (nonce + ciphertext + tag).
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
    
    /// Decrypts AES-256-GCM ciphertext received from a specific peer.
    ///
    /// - Throws: ``EncryptionError/noSharedSecret`` if no key exchange has occurred, or a CryptoKit error on authentication failure.
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
    
    /// Produces an Ed25519 signature over `data` using this session's ephemeral signing key.
    func sign(_ data: Data) throws -> Data {
        // Create a local copy of the key to avoid concurrent access
        let key = signingPrivateKey
        return try key.signature(for: data)
    }
    
    /// Verifies an Ed25519 `signature` over `data` against the peer's ephemeral signing public key.
    ///
    /// - Throws: ``EncryptionError/noSharedSecret`` if the peer's signing key is not registered.
    /// - Returns: `true` if the signature is valid.
    func verify(_ signature: Data, for data: Data, from peerID: String) throws -> Bool {
        let verifyingKey = try cryptoQueue.sync {
            guard let key = peerSigningKeys[peerID] else {
                throw EncryptionError.noSharedSecret
            }
            return key
        }
        
        return verifyingKey.isValidSignature(signature, for: data)
    }
    
}

/// Errors thrown by ``EncryptionService`` operations.
enum EncryptionError: Error {
    /// No shared secret has been derived for the requested peer (key exchange not yet performed).
    case noSharedSecret
    /// The provided public key data is malformed or not the expected 96 bytes.
    case invalidPublicKey
    /// AES-GCM encryption failed.
    case encryptionFailed
    /// AES-GCM decryption or authentication failed.
    case decryptionFailed
}