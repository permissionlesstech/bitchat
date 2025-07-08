//
// EncryptionService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit
import LocalAuthentication
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
    
    // Keychain service identifiers
    private let keychainService = "com.bitchat.encryption"
    private let identityKeyTag = "com.bitchat.identityKey"
    private let keyRotationTag = "com.bitchat.keyRotation"
    
    // Key rotation interval (30 days)
    private let keyRotationInterval: TimeInterval = 30 * 24 * 60 * 60
    
    init() throws {
        // Generate ephemeral key pairs for this session
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.publicKey = privateKey.publicKey
        
        self.signingPrivateKey = Curve25519.Signing.PrivateKey()
        self.signingPublicKey = signingPrivateKey.publicKey
        
        // Load or create persistent identity key with biometric protection
        do {
            if let identityKeyData = try loadIdentityKeyFromKeychain() {
                self.identityKey = try Curve25519.Signing.PrivateKey(rawRepresentation: identityKeyData)
            } else {
                // First run - create and save identity key
                self.identityKey = Curve25519.Signing.PrivateKey()
                try saveIdentityKeyToKeychain(self.identityKey.rawRepresentation)
            }
            self.identityPublicKey = identityKey.publicKey
            
            // Check if key rotation is needed
            try checkAndPerformKeyRotationIfNeeded()
        } catch {
            throw EncryptionError.keychainError(error)
        }
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
    
    // Get peer's persistent identity key for favorites
    func getPeerIdentityKey(_ peerID: String) -> Data? {
        return cryptoQueue.sync {
            return peerIdentityKeys[peerID]?.rawRepresentation
        }
    }
    
    // Clear persistent identity (for panic mode)
    func clearPersistentIdentity() throws {
        do {
            try deleteIdentityKeyFromKeychain()
            // print("[CRYPTO] Cleared persistent identity key from keychain")
        } catch {
            throw EncryptionError.keychainError(error)
        }
    }
    
    // MARK: - Keychain Operations
    
    private func createAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet, .privateKeyUsage],
            &error
        ) else {
            if let error = error?.takeRetainedValue() {
                throw error as Error
            }
            throw EncryptionError.keychainAccessControlCreationFailed
        }
        
        return accessControl
    }
    
    private func saveIdentityKeyToKeychain(_ keyData: Data) throws {
        let accessControl = try createAccessControl()
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identityKeyTag,
            kSecValueData as String: keyData,
            kSecAttrAccessControl as String: accessControl,
            kSecUseAuthenticationContext as String: LAContext(),
            kSecAttrSynchronizable as String: false
        ]
        
        // Delete any existing item first
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != errSecSuccess {
            throw EncryptionError.keychainSaveError(status)
        }
        
        // Save key rotation timestamp
        try saveKeyRotationTimestamp()
    }
    
    private func loadIdentityKeyFromKeychain() throws -> Data? {
        let context = LAContext()
        context.localizedReason = "Access your encrypted identity key"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identityKeyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw EncryptionError.keychainDataCorrupted
            }
            return data
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled:
            throw EncryptionError.biometricAuthenticationCanceled
        case errSecAuthFailed:
            throw EncryptionError.biometricAuthenticationFailed
        default:
            throw EncryptionError.keychainLoadError(status)
        }
    }
    
    private func deleteIdentityKeyFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identityKeyTag
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        if status != errSecSuccess && status != errSecItemNotFound {
            throw EncryptionError.keychainDeleteError(status)
        }
        
        // Also delete rotation timestamp
        try deleteKeyRotationTimestamp()
    }
    
    // MARK: - Key Rotation
    
    private func checkAndPerformKeyRotationIfNeeded() throws {
        guard let lastRotation = try loadKeyRotationTimestamp() else {
            // No rotation timestamp found, save current time
            try saveKeyRotationTimestamp()
            return
        }
        
        let timeSinceLastRotation = Date().timeIntervalSince(lastRotation)
        
        if timeSinceLastRotation >= keyRotationInterval {
            try performKeyRotation()
        }
    }
    
    private func performKeyRotation() throws {
        // Generate new identity key
        let newIdentityKey = Curve25519.Signing.PrivateKey()
        
        // Save the new key
        try saveIdentityKeyToKeychain(newIdentityKey.rawRepresentation)
        
        // Note: In a real implementation, you would need to:
        // 1. Notify peers of the key rotation
        // 2. Maintain old key for a transition period
        // 3. Re-encrypt any stored data with the new key
        // This is a simplified version
    }
    
    private func saveKeyRotationTimestamp() throws {
        let timestamp = Date()
        let data = try JSONEncoder().encode(timestamp)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keyRotationTag,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != errSecSuccess {
            throw EncryptionError.keychainSaveError(status)
        }
    }
    
    private func loadKeyRotationTimestamp() throws -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keyRotationTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return nil
            }
            return try JSONDecoder().decode(Date.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw EncryptionError.keychainLoadError(status)
        }
    }
    
    private func deleteKeyRotationTimestamp() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keyRotationTag
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        if status != errSecSuccess && status != errSecItemNotFound {
            throw EncryptionError.keychainDeleteError(status)
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
    
}

enum EncryptionError: LocalizedError {
    case noSharedSecret
    case invalidPublicKey
    case encryptionFailed
    case decryptionFailed
    case keychainError(Error)
    case keychainSaveError(OSStatus)
    case keychainLoadError(OSStatus)
    case keychainDeleteError(OSStatus)
    case keychainAccessControlCreationFailed
    case keychainDataCorrupted
    case biometricAuthenticationFailed
    case biometricAuthenticationCanceled
    
    var errorDescription: String? {
        switch self {
        case .noSharedSecret:
            return "No shared secret available for encryption"
        case .invalidPublicKey:
            return "Invalid public key format"
        case .encryptionFailed:
            return "Encryption operation failed"
        case .decryptionFailed:
            return "Decryption operation failed"
        case .keychainError(let error):
            return "Keychain error: \(error.localizedDescription)"
        case .keychainSaveError(let status):
            return "Failed to save to keychain: \(status)"
        case .keychainLoadError(let status):
            return "Failed to load from keychain: \(status)"
        case .keychainDeleteError(let status):
            return "Failed to delete from keychain: \(status)"
        case .keychainAccessControlCreationFailed:
            return "Failed to create keychain access control"
        case .keychainDataCorrupted:
            return "Keychain data is corrupted"
        case .biometricAuthenticationFailed:
            return "Biometric authentication failed"
        case .biometricAuthenticationCanceled:
            return "Biometric authentication was canceled"
        }
    }
}