//
// SecurityTests.swift
// bitchatTests
//
// Security test suite for bitchat encryption implementation
// This is free and unencumbered software released into the public domain.
//

import XCTest
import CryptoKit
import Security
@testable import bitchat

class SecurityTests: XCTestCase {
    
    var encryptionService: EncryptionService!
    
    override func setUp() {
        super.setUp()
        // Create fresh encryption service for each test
        encryptionService = EncryptionService()
        
        // Clear any existing test keys from Keychain
        clearTestKeysFromKeychain()
    }
    
    override func tearDown() {
        // Clean up after each test
        clearTestKeysFromKeychain()
        encryptionService = nil
        super.tearDown()
    }
    
    // MARK: - Critical Security Issue Tests
    
    func testKeychainStorageInsteadOfUserDefaults() {
        // Test that identity keys are stored in Keychain, not UserDefaults
        
        // Create new encryption service (should create and store key in Keychain)
        let service1 = EncryptionService()
        let originalKey = service1.identityPublicKey
        
        // Create another service (should load the same key from Keychain)
        let service2 = EncryptionService()
        let loadedKey = service2.identityPublicKey
        
        // Keys should be identical (loaded from Keychain)
        XCTAssertEqual(originalKey.rawRepresentation, loadedKey.rawRepresentation,
                      "Identity key should persist in Keychain across service instances")
        
        // Verify key is NOT in UserDefaults
        let userDefaultsKey = UserDefaults.standard.data(forKey: "bitchat.identityKey")
        XCTAssertNil(userDefaultsKey, "Identity key should NOT be stored in UserDefaults")
        
        // Verify key IS in Keychain
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "bitchat.identityKey".data(using: .utf8)!,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(keychainQuery, &result)
        XCTAssertEqual(status, errSecSuccess, "Identity key should be stored in Keychain")
        XCTAssertNotNil(result, "Should be able to retrieve identity key from Keychain")
    }
    
    func testPerfectForwardSecrecy() {
        // Test key rotation functionality
        
        let originalPublicKey = encryptionService.publicKey.rawRepresentation
        let originalSigningKey = encryptionService.signingPublicKey.rawRepresentation
        
        // Force key rotation
        encryptionService.forceKeyRotation()
        
        let newPublicKey = encryptionService.publicKey.rawRepresentation
        let newSigningKey = encryptionService.signingPublicKey.rawRepresentation
        
        // Keys should be different after rotation
        XCTAssertNotEqual(originalPublicKey, newPublicKey,
                         "Public key should change after rotation for forward secrecy")
        XCTAssertNotEqual(originalSigningKey, newSigningKey,
                         "Signing key should change after rotation for forward secrecy")
        
        // Identity key should remain the same (persistent)
        let service2 = EncryptionService()
        XCTAssertEqual(encryptionService.identityPublicKey.rawRepresentation,
                      service2.identityPublicKey.rawRepresentation,
                      "Identity key should remain persistent across rotations")
    }
    
    func testRandomSaltGeneration() {
        // Test that different shared secrets use different salts
        
        // Create mock peer data
        let peer1ID = "peer1"
        let peer2ID = "peer2"
        
        // Generate keys for mock peers
        let peer1Key = Curve25519.KeyAgreement.PrivateKey()
        let peer2Key = Curve25519.KeyAgreement.PrivateKey()
        
        // Create combined key data for peers
        var peer1Data = Data()
        peer1Data.append(peer1Key.publicKey.rawRepresentation)
        peer1Data.append(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        peer1Data.append(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        
        var peer2Data = Data()
        peer2Data.append(peer2Key.publicKey.rawRepresentation)
        peer2Data.append(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        peer2Data.append(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        
        // Add peers (this should generate shared secrets with random salts)
        XCTAssertNoThrow(try encryptionService.addPeerPublicKey(peer1ID, publicKeyData: peer1Data))
        XCTAssertNoThrow(try encryptionService.addPeerPublicKey(peer2ID, publicKeyData: peer2Data))
        
        // Test encryption with both peers (should work if salts are properly generated)
        let testMessage = "Test message for salt verification".data(using: .utf8)!
        
        XCTAssertNoThrow(try encryptionService.encrypt(testMessage, for: peer1ID))
        XCTAssertNoThrow(try encryptionService.encrypt(testMessage, for: peer2ID))
    }
    
    // MARK: - Key Generation Security Tests
    
    func testKeyGenerationEntropy() {
        // Test that generated keys have sufficient entropy (are unique)
        
        var publicKeys = Set<Data>()
        var signingKeys = Set<Data>()
        
        // Generate multiple encryption services and verify key uniqueness
        for _ in 0..<10 {
            let service = EncryptionService()
            let pubKey = service.publicKey.rawRepresentation
            let signKey = service.signingPublicKey.rawRepresentation
            
            XCTAssertFalse(publicKeys.contains(pubKey), "Generated public keys should be unique")
            XCTAssertFalse(signingKeys.contains(signKey), "Generated signing keys should be unique")
            
            publicKeys.insert(pubKey)
            signingKeys.insert(signKey)
        }
        
        // All keys should be 32 bytes
        for key in publicKeys {
            XCTAssertEqual(key.count, 32, "Curve25519 public keys should be 32 bytes")
        }
    }
    
    func testNonceUniqueness() {
        // Test that AES-GCM generates unique nonces for each encryption
        
        // Setup peer
        let peerID = "testPeer"
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        
        var peerData = Data()
        peerData.append(peerKey.publicKey.rawRepresentation)
        peerData.append(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        peerData.append(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        
        try! encryptionService.addPeerPublicKey(peerID, publicKeyData: peerData)
        
        // Encrypt the same message multiple times
        let message = "Same message for nonce test".data(using: .utf8)!
        var encryptedResults = Set<Data>()
        
        for _ in 0..<5 {
            let encrypted = try! encryptionService.encrypt(message, for: peerID)
            XCTAssertFalse(encryptedResults.contains(encrypted), 
                          "Each encryption should produce different ciphertext (unique nonces)")
            encryptedResults.insert(encrypted)
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testEncryptionWithoutPeer() {
        // Test that encryption fails gracefully without established peer
        
        let message = "Test message".data(using: .utf8)!
        
        XCTAssertThrowsError(try encryptionService.encrypt(message, for: "nonexistentPeer")) { error in
            XCTAssertEqual(error as? EncryptionError, EncryptionError.noSharedSecret)
        }
    }
    
    func testInvalidPublicKeyData() {
        // Test handling of invalid public key data
        
        let invalidKeyData = Data(repeating: 0, count: 50) // Wrong size
        
        XCTAssertThrowsError(try encryptionService.addPeerPublicKey("peer", publicKeyData: invalidKeyData)) { error in
            XCTAssertEqual(error as? EncryptionError, EncryptionError.invalidPublicKey)
        }
    }
    
    // MARK: - End-to-End Encryption Tests
    
    func testEndToEndEncryption() {
        // Test complete encryption/decryption cycle
        
        let service1 = EncryptionService()
        let service2 = EncryptionService()
        
        // Exchange public keys
        let service1Keys = service1.getCombinedPublicKeyData()
        let service2Keys = service2.getCombinedPublicKeyData()
        
        try! service1.addPeerPublicKey("service2", publicKeyData: service2Keys)
        try! service2.addPeerPublicKey("service1", publicKeyData: service1Keys)
        
        // Test message
        let originalMessage = "Secure end-to-end test message 🔐".data(using: .utf8)!
        
        // Encrypt with service1
        let encrypted = try! service1.encrypt(originalMessage, for: "service2")
        
        // Decrypt with service2
        let decrypted = try! service2.decrypt(encrypted, from: "service1")
        
        XCTAssertEqual(originalMessage, decrypted, "Decrypted message should match original")
    }
    
    func testDigitalSignatures() {
        // Test digital signature verification
        
        let message = "Message to be signed".data(using: .utf8)!
        
        // Sign message
        let signature = try! encryptionService.sign(message)
        
        // Setup peer to verify signature
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        let peerSigningKey = Curve25519.Signing.PrivateKey()
        
        var peerData = Data()
        peerData.append(peerKey.publicKey.rawRepresentation)
        peerData.append(encryptionService.signingPublicKey.rawRepresentation) // Use our signing key for verification
        peerData.append(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        
        try! encryptionService.addPeerPublicKey("signer", publicKeyData: peerData)
        
        // Verify signature
        let isValid = try! encryptionService.verify(signature, for: message, from: "signer")
        XCTAssertTrue(isValid, "Valid signature should be verified successfully")
        
        // Test invalid signature
        let invalidSignature = Data(repeating: 0, count: signature.count)
        let isInvalid = try! encryptionService.verify(invalidSignature, for: message, from: "signer")
        XCTAssertFalse(isInvalid, "Invalid signature should fail verification")
    }
    
    // MARK: - Memory Safety Tests
    
    func testKeyRotationClearsSharedSecrets() {
        // Test that key rotation properly clears old shared secrets
        
        let peerID = "testPeer"
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        
        var peerData = Data()
        peerData.append(peerKey.publicKey.rawRepresentation)
        peerData.append(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        peerData.append(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        
        try! encryptionService.addPeerPublicKey(peerID, publicKeyData: peerData)
        
        // Should be able to encrypt before rotation
        let message = "Test message".data(using: .utf8)!
        XCTAssertNoThrow(try encryptionService.encrypt(message, for: peerID))
        
        // Force key rotation
        encryptionService.forceKeyRotation()
        
        // Should fail to encrypt after rotation (shared secret cleared)
        XCTAssertThrowsError(try encryptionService.encrypt(message, for: peerID))
    }
    
    // MARK: - Helper Methods
    
    private func clearTestKeysFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "bitchat.identityKey".data(using: .utf8)!
        ]
        SecItemDelete(query)
    }
}