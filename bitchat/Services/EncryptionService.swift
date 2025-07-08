//
// EncryptionService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

    /// A secure service responsible for managing ephemeral and persistent encryption keys,
    /// signing keys, peer identity management, and encryption/decryption using symmetric keys.
final class EncryptionService: @unchecked Sendable {
    
        // MARK: - Ephemeral Keys (Session-Based)
    
        /// Ephemeral private key for key agreement during this session.
    private var privateKey: Curve25519.KeyAgreement.PrivateKey
    
        /// Public key derived from the ephemeral private key (used for peer key exchange).
    public let publicKey: Curve25519.KeyAgreement.PublicKey
    
        /// Ephemeral signing private key for message signing in this session.
    private var signingPrivateKey: Curve25519.Signing.PrivateKey
    
        /// Public signing key for the ephemeral signing key.
    public let signingPublicKey: Curve25519.Signing.PublicKey
    
        // MARK: - Persistent Identity Keys (Favorites)
    
        /// Persistent identity signing private key (stored across app sessions).
    private let identityKey: Curve25519.Signing.PrivateKey
    
        /// Public version of the persistent identity key.
    public let identityPublicKey: Curve25519.Signing.PublicKey
    
        // MARK: - Peer Key Storage
    
        /// PeerID → peer's ephemeral encryption public key.
    private var peerPublicKeys: [String: Curve25519.KeyAgreement.PublicKey] = [:]
    
        /// PeerID → peer's ephemeral signing public key.
    private var peerSigningKeys: [String: Curve25519.Signing.PublicKey] = [:]
    
        /// PeerID → peer's persistent identity public key.
    private var peerIdentityKeys: [String: Curve25519.Signing.PublicKey] = [:]
    
        /// PeerID → derived symmetric encryption key (shared secret).
    private var sharedSecrets: [String: SymmetricKey] = [:]
    
        /// Thread-safe access queue for crypto state.
    private let queueu = DispatchQueue(label: "chat.bitchat.crypto.queue", attributes: .concurrent)
    
        // MARK: - Initialization
    
        /// Initializes the encryption service by generating ephemeral keys and loading
        /// or creating a persistent identity key.
    init() {
            // Ephemeral session keys
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.publicKey = privateKey.publicKey
        
        self.signingPrivateKey = Curve25519.Signing.PrivateKey()
        self.signingPublicKey = signingPrivateKey.publicKey
        
            // Persistent identity key
        if let identityData = UserDefaults.standard.data(forKey: "bitchat.identityKey"),
           let loadedKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: identityData) {
            self.identityKey = loadedKey
        } else {
            self.identityKey = Curve25519.Signing.PrivateKey()
            UserDefaults.standard.set(identityKey.rawRepresentation, forKey: "bitchat.identityKey")
        }
        
        self.identityPublicKey = identityKey.publicKey
    }
    
        // MARK: - Public Key Exchange
    
        /// Combines the three public keys into one 96-byte data packet for exchange with peers.
        /// - Returns: Concatenated data containing ephemeral encryption, signing, and identity keys.
    func getCombinedPublicKeyData() -> Data {
        var data = Data()
        data.append(publicKey.rawRepresentation)
        data.append(signingPublicKey.rawRepresentation)
        data.append(identityPublicKey.rawRepresentation)
        return data
    }
    
        /// Stores the peer’s combined public keys and derives the symmetric encryption key.
        /// - Parameters:
        ///   - peerID: The identifier for the peer.
        ///   - publicKeyData: The peer's 96-byte combined public key data.
        /// - Throws: `EncryptionError.invalidPublicKey` if the data is malformed.
    func addPeerPublicKey(_ peerID: String, publicKeyData: Data) throws {
        try queueu.sync(flags: .barrier) {
            let keyBytes = [UInt8](publicKeyData)
            guard keyBytes.count == 96 else {
                throw EncryptionError.invalidPublicKey
            }
            
            let keyAgreementData = Data(keyBytes[0..<32])
            let signingKeyData = Data(keyBytes[32..<64])
            let identityKeyData = Data(keyBytes[64..<96])
            
            let encryptionKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyAgreementData)
            let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: signingKeyData)
            let identityKey = try Curve25519.Signing.PublicKey(rawRepresentation: identityKeyData)
            
            peerPublicKeys[peerID] = encryptionKey
            peerSigningKeys[peerID] = signingKey
            peerIdentityKeys[peerID] = identityKey
            
                // Generate shared secret
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: encryptionKey)
            let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: "bitchat-v1".data(using: .utf8)!,
                sharedInfo: Data(),
                outputByteCount: 32
            )
            sharedSecrets[peerID] = symmetricKey
        }
    }
    
        // MARK: - Identity
    
        /// Returns the persistent identity public key of a peer.
        /// - Parameter peerID: The peer’s identifier.
        /// - Returns: The identity key data if available.
    func getPeerIdentityKey(_ peerID: String) -> Data? {
        queueu.sync {
            peerIdentityKeys[peerID]?.rawRepresentation
        }
    }
    
        /// Clears the persistent identity key from local storage.
    func clearPersistentIdentity() {
        UserDefaults.standard.removeObject(forKey: "bitchat.identityKey")
    }
    
        // MARK: - Encryption & Decryption
    
        /// Encrypts the given data for the specified peer.
        /// - Parameters:
        ///   - data: Plaintext data.
        ///   - peerID: The recipient’s peer ID.
        /// - Returns: Encrypted data using AES-GCM.
    func encrypt(_ data: Data, for peerID: String) throws -> Data {
        let symmetricKey = try queueu.sync {
            guard let key = sharedSecrets[peerID] else {
                throw EncryptionError.noSharedSecret
            }
            return key
        }
        
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        return sealedBox.combined ?? Data()
    }
    
        /// Decrypts received data from the specified peer.
        /// - Parameters:
        ///   - data: Encrypted data.
        ///   - peerID: Sender's peer ID.
        /// - Returns: Decrypted plaintext data.
    func decrypt(_ data: Data, from peerID: String) throws -> Data {
        let symmetricKey = try queueu.sync {
            guard let key = sharedSecrets[peerID] else {
                throw EncryptionError.noSharedSecret
            }
            return key
        }
        
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
    
        // MARK: - Signing & Verification
    
        /// Signs a piece of data using the ephemeral signing key.
        /// - Parameter data: Data to sign.
        /// - Returns: The cryptographic signature.
    func sign(_ data: Data) throws -> Data {
        let key = signingPrivateKey
        return try key.signature(for: data)
    }
    
        /// Verifies a signature from a known peer.
        /// - Parameters:
        ///   - signature: The signature to verify.
        ///   - data: The original message data.
        ///   - peerID: The sender’s peer ID.
        /// - Returns: `true` if valid; otherwise, `false`.
    func verify(_ signature: Data, for data: Data, from peerID: String) throws -> Bool {
        let key = try queueu.sync {
            guard let verifyingKey = peerSigningKeys[peerID] else {
                throw EncryptionError.noSharedSecret
            }
            return verifyingKey
        }
        
        return key.isValidSignature(signature, for: data)
    }
}

    // MARK: - Encryption Errors

    /// Represents cryptographic errors for encryption and key handling.
enum EncryptionError: Error {
    case noSharedSecret
    case invalidPublicKey
    case encryptionFailed
    case decryptionFailed
}
