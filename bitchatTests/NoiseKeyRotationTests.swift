//
// NoiseKeyRotationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CryptoKit
@testable import bitchat

class NoiseKeyRotationTests: XCTestCase {
    
    var keyRotation: NoiseChannelKeyRotation!
    
    override func setUp() {
        super.setUp()
        keyRotation = NoiseChannelKeyRotation()
    }
    
    override func tearDown() {
        // Clean up test data
        keyRotation.clearEpochs(for: "#test-channel")
        super.tearDown()
    }
    
    // MARK: - Basic Key Rotation Tests
    
    func testInitialKeyGeneration() {
        let channel = "#test-channel"
        let password = "test-password"
        let fingerprint = "abc123def456"
        
        // Get initial key
        guard let rotatedKey = keyRotation.getCurrentKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        ) else {
            XCTFail("Failed to get initial key")
            return
        }
        
        XCTAssertEqual(rotatedKey.epoch.epochNumber, 1)
        XCTAssertTrue(rotatedKey.isActive)
        XCTAssertNotNil(rotatedKey.key)
    }
    
    func testKeyRotation() {
        let channel = "#test-channel"
        let password = "test-password"
        let fingerprint = "abc123def456"
        
        // Get initial key
        let initialKey = keyRotation.getCurrentKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        // Rotate key
        let newEpoch = keyRotation.rotateChannelKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        XCTAssertEqual(newEpoch.epochNumber, 2)
        XCTAssertNotNil(newEpoch.previousEpochCommitment)
        
        // Get new current key
        let rotatedKey = keyRotation.getCurrentKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        XCTAssertEqual(rotatedKey?.epoch.epochNumber, 2)
        
        // Keys should be different
        if let initial = initialKey, let rotated = rotatedKey {
            XCTAssertNotEqual(
                initial.key.withUnsafeBytes { Data($0) },
                rotated.key.withUnsafeBytes { Data($0) }
            )
        }
    }
    
    func testKeyRotationNeeded() {
        let channel = "#test-channel"
        let password = "test-password"
        let fingerprint = "abc123def456"
        
        // Initially needs rotation (no epochs)
        XCTAssertTrue(keyRotation.needsKeyRotation(for: channel))
        
        // After getting initial key, shouldn't need rotation
        _ = keyRotation.getCurrentKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        XCTAssertFalse(keyRotation.needsKeyRotation(for: channel))
        
        // Note: We can't easily test time-based rotation need without
        // modifying internal state or waiting 22+ hours
    }
    
    // MARK: - Multiple Epoch Tests
    
    func testMultipleEpochsForDecryption() {
        let channel = "#test-channel"
        let password = "test-password"
        let fingerprint = "abc123def456"
        
        // Create initial epoch
        _ = keyRotation.getCurrentKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        // Rotate multiple times
        for _ in 0..<3 {
            _ = keyRotation.rotateChannelKey(
                for: channel,
                basePassword: password,
                creatorFingerprint: fingerprint
            )
        }
        
        // Get valid keys for decryption
        let validKeys = keyRotation.getValidKeysForDecryption(
            channel: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        // Should have at least the current epoch
        XCTAssertGreaterThanOrEqual(validKeys.count, 1)
        
        // Check that we have the latest epoch
        XCTAssertTrue(validKeys.contains { $0.epoch.epochNumber == 4 })
    }
    
    func testEpochKeyDerivationConsistency() {
        let channel = "#test-channel"
        let password = "test-password"
        let fingerprint = "abc123def456"
        
        // Get key for epoch 1
        let key1a = keyRotation.getCurrentKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        // Get the same key again
        let key1b = keyRotation.getCurrentKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        // Keys should be identical for same epoch
        if let a = key1a, let b = key1b {
            XCTAssertEqual(
                a.key.withUnsafeBytes { Data($0) },
                b.key.withUnsafeBytes { Data($0) }
            )
            XCTAssertEqual(a.epoch.epochNumber, b.epoch.epochNumber)
        }
    }
    
    // MARK: - Edge Cases
    
    func testMaxEpochLimit() {
        let channel = "#test-channel"
        let password = "test-password"
        let fingerprint = "abc123def456"
        
        // Create initial epoch
        _ = keyRotation.getCurrentKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        // Rotate many times (more than max stored epochs)
        for _ in 0..<10 {
            _ = keyRotation.rotateChannelKey(
                for: channel,
                basePassword: password,
                creatorFingerprint: fingerprint
            )
        }
        
        // Get all valid epochs
        let validKeys = keyRotation.getValidKeysForDecryption(
            channel: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        // Should not exceed reasonable limit
        XCTAssertLessThanOrEqual(validKeys.count, 7) // maxStoredEpochs
    }
    
    func testDifferentChannelsDifferentEpochs() {
        let password = "test-password"
        let fingerprint = "abc123def456"
        
        let channel1 = "#channel-1"
        let channel2 = "#channel-2"
        
        // Get keys for both channels
        let key1 = keyRotation.getCurrentKey(
            for: channel1,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        let key2 = keyRotation.getCurrentKey(
            for: channel2,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        // Keys should be different even with same password
        if let k1 = key1, let k2 = key2 {
            XCTAssertNotEqual(
                k1.key.withUnsafeBytes { Data($0) },
                k2.key.withUnsafeBytes { Data($0) }
            )
        }
    }
    
    // MARK: - Integration Tests
    
    func testKeyRotationWithEncryption() throws {
        let channel = "#test-channel"
        let password = "test-password"
        let fingerprint = "abc123def456"
        
        // Get initial key
        guard let initialRotatedKey = keyRotation.getCurrentKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        ) else {
            XCTFail("Failed to get initial key")
            return
        }
        
        // Encrypt a message with initial key
        let message = "Test message before rotation"
        let nonce = ChaChaPoly.Nonce()
        let sealed1 = try ChaChaPoly.seal(
            Data(message.utf8),
            using: initialRotatedKey.key,
            nonce: nonce
        )
        
        // Rotate key
        _ = keyRotation.rotateChannelKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        // Get new key
        guard let newRotatedKey = keyRotation.getCurrentKey(
            for: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        ) else {
            XCTFail("Failed to get rotated key")
            return
        }
        
        // New key should not decrypt old message
        XCTAssertThrowsError(
            try ChaChaPoly.open(sealed1, using: newRotatedKey.key)
        )
        
        // But we should still be able to decrypt with old epoch key
        let validKeys = keyRotation.getValidKeysForDecryption(
            channel: channel,
            basePassword: password,
            creatorFingerprint: fingerprint
        )
        
        // Try each valid key until one works
        var decrypted = false
        for rotatedKey in validKeys {
            do {
                let plaintext = try ChaChaPoly.open(sealed1, using: rotatedKey.key)
                XCTAssertEqual(String(data: plaintext, encoding: .utf8), message)
                decrypted = true
                break
            } catch {
                continue
            }
        }
        
        XCTAssertTrue(decrypted, "Failed to decrypt with any valid key")
    }
}

// MARK: - Post-Quantum Framework Tests

class NoisePostQuantumTests: XCTestCase {
    
    func testHybridKeyGeneration() throws {
        let (publicKey, privateKey) = try HybridNoiseKeyExchange.generateKeyPair(algorithm: .classicalOnly)
        
        XCTAssertNotNil(publicKey.classical)
        XCTAssertNil(publicKey.postQuantum) // No PQ component yet
        XCTAssertEqual(publicKey.serialized.count, 32) // Just Curve25519
        
        XCTAssertNotNil(privateKey.classical)
        XCTAssertNil(privateKey.postQuantum)
    }
    
    func testHybridKeyAgreement() throws {
        // Generate two keypairs
        let (alicePub, alicePriv) = try HybridNoiseKeyExchange.generateKeyPair(algorithm: .classicalOnly)
        let (bobPub, bobPriv) = try HybridNoiseKeyExchange.generateKeyPair(algorithm: .classicalOnly)
        
        // Perform key agreement
        let aliceShared = try HybridNoiseKeyExchange.performKeyAgreement(
            localPrivate: alicePriv,
            remotePublic: bobPub,
            algorithm: .classicalOnly
        )
        
        let bobShared = try HybridNoiseKeyExchange.performKeyAgreement(
            localPrivate: bobPriv,
            remotePublic: alicePub,
            algorithm: .classicalOnly
        )
        
        // Shared secrets should match
        XCTAssertEqual(
            aliceShared.combinedSecret().withUnsafeBytes { Data($0) },
            bobShared.combinedSecret().withUnsafeBytes { Data($0) }
        )
    }
    
    func testMigrationConfig() {
        let config = NoiseProtocolMigration.getMigrationConfig()
        
        XCTAssertEqual(config.currentPhase, .classicalOnly)
        XCTAssertEqual(config.preferredAlgorithm, .classicalOnly)
        XCTAssertTrue(config.acceptedAlgorithms.contains(.classicalOnly))
        XCTAssertNil(config.migrationDeadline)
    }
    
    #if DEBUG
    func testMockPostQuantum() throws {
        // Test mock PQ implementation
        let (publicKey, privateKey) = try MockPostQuantumKeyExchange.generateKeyPair()
        
        XCTAssertEqual(publicKey.count, MockPostQuantumKeyExchange.publicKeySize)
        XCTAssertEqual(privateKey.count, 32) // Mock uses smaller private key
        
        let (sharedSecret, ciphertext) = try MockPostQuantumKeyExchange.encapsulate(
            remotePublicKey: publicKey
        )
        
        XCTAssertEqual(ciphertext.count, MockPostQuantumKeyExchange.ciphertextSize)
        XCTAssertEqual(sharedSecret.count, MockPostQuantumKeyExchange.sharedSecretSize)
        
        let decapsulatedSecret = try MockPostQuantumKeyExchange.decapsulate(
            ciphertext: ciphertext,
            privateKey: privateKey
        )
        
        // In real implementation, these would match
        // Mock just returns deterministic values
        XCTAssertEqual(decapsulatedSecret.count, 32)
    }
    #endif
}