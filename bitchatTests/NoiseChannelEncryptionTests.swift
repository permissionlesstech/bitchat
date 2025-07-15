//
// NoiseChannelEncryptionTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CryptoKit
@testable import bitchat

class NoiseChannelEncryptionTests: XCTestCase {
    
    // MARK: - Channel Key Derivation with Fingerprint Tests
    
    func testChannelEncryptionWithFingerprint() {
        let encryption = NoiseChannelEncryption()
        let password = "test-password-123"
        let channel = "#secure-channel"
        let fingerprint = "e36f7993abc123def456789012345678901234567890abcdef1234567890abcd"
        
        // Set channel password with fingerprint
        encryption.setChannelPasswordForCreator(password, channel: channel, creatorFingerprint: fingerprint)
        
        // Test encryption
        let message = "This is a secret message"
        do {
            let encrypted = try encryption.encryptChannelMessage(message, for: channel)
            
            // Ensure it's actually encrypted
            XCTAssertNotEqual(encrypted, Data(message.utf8))
            XCTAssertGreaterThan(encrypted.count, message.count) // Should have IV + tag
            
            // Test decryption
            let decrypted = try encryption.decryptChannelMessage(encrypted, for: channel)
            XCTAssertEqual(decrypted, message)
            
        } catch {
            XCTFail("Encryption/decryption failed: \(error)")
        }
    }
    
    func testBackwardsCompatibilityWithoutFingerprint() {
        let encryption = NoiseChannelEncryption()
        let password = "test-password-123"
        let channel = "#legacy-channel"
        
        // Set password without fingerprint (legacy mode)
        encryption.setChannelPassword(password, for: channel)
        
        // Encrypt message
        let message = "Legacy message"
        do {
            let encrypted = try encryption.encryptChannelMessage(message, for: channel)
            
            // Should still work
            let decrypted = try encryption.decryptChannelMessage(encrypted, for: channel)
            XCTAssertEqual(decrypted, message)
            
        } catch {
            XCTFail("Legacy encryption failed: \(error)")
        }
    }
    
    func testDifferentFingerprintsProduceDifferentEncryption() throws {
        let encryption1 = NoiseChannelEncryption()
        let encryption2 = NoiseChannelEncryption()
        
        let password = "same-password"
        let channel = "#test-channel"
        let message = "Test message"
        
        let fingerprint1 = "1111111111111111111111111111111111111111111111111111111111111111"
        let fingerprint2 = "2222222222222222222222222222222222222222222222222222222222222222"
        
        // Set same password with different fingerprints
        encryption1.setChannelPasswordForCreator(password, channel: channel, creatorFingerprint: fingerprint1)
        encryption2.setChannelPasswordForCreator(password, channel: channel, creatorFingerprint: fingerprint2)
        
        // Encrypt same message
        let encrypted1 = try encryption1.encryptChannelMessage(message, for: channel)
        let encrypted2 = try encryption2.encryptChannelMessage(message, for: channel)
        
        // Encrypted data should be different (different keys due to different salts)
        // Note: We can't directly compare ciphertexts due to random IVs, but we can verify they don't decrypt with wrong key
        
        // Try to decrypt with wrong fingerprint - should fail
        encryption1.removeChannelPassword(for: channel)
        encryption1.setChannelPasswordForCreator(password, channel: channel, creatorFingerprint: fingerprint2)
        
        XCTAssertThrowsError(try encryption1.decryptChannelMessage(encrypted1, for: channel)) { error in
            // Should fail to decrypt because key is different
        }
    }
    
    // MARK: - Key Management Tests
    
    func testChannelKeyPersistence() {
        let encryption = NoiseChannelEncryption()
        let password = "persistent-password"
        let channel = "#persistent-channel"
        
        // Set and save password
        encryption.setChannelPassword(password, for: channel)
        
        // Verify it's saved in keychain
        XCTAssertTrue(encryption.loadChannelPassword(for: channel))
        
        // Create new instance and load
        let encryption2 = NoiseChannelEncryption()
        XCTAssertTrue(encryption2.loadChannelPassword(for: channel))
        
        // Should be able to decrypt messages from first instance
        do {
            let message = "Cross-instance message"
            let encrypted = try encryption.encryptChannelMessage(message, for: channel)
            let decrypted = try encryption2.decryptChannelMessage(encrypted, for: channel)
            XCTAssertEqual(decrypted, message)
        } catch {
            XCTFail("Cross-instance encryption failed: \(error)")
        }
        
        // Clean up
        encryption.removeChannelPassword(for: channel)
    }
    
    func testChannelKeyPacketCreation() {
        let encryption = NoiseChannelEncryption()
        let password = "shared-password"
        let channel = "#shared-channel"
        
        // Create key packet
        guard let packet = encryption.createChannelKeyPacket(password: password, channel: channel) else {
            XCTFail("Failed to create key packet")
            return
        }
        
        // Verify packet structure
        XCTAssertGreaterThan(packet.count, 32) // Should have channel name + password + metadata
        
        // Process packet in another instance
        let encryption2 = NoiseChannelEncryption()
        guard let (extractedChannel, extractedPassword) = encryption2.processChannelKeyPacket(packet) else {
            XCTFail("Failed to process key packet")
            return
        }
        
        XCTAssertEqual(extractedChannel, channel)
        XCTAssertEqual(extractedPassword, password)
    }
    
    // MARK: - Error Handling Tests
    
    func testDecryptionWithWrongPassword() {
        let encryption = NoiseChannelEncryption()
        let channel = "#error-test"
        
        // Encrypt with one password
        encryption.setChannelPassword("correct-password", for: channel)
        let message = "Secret message"
        
        do {
            let encrypted = try encryption.encryptChannelMessage(message, for: channel)
            
            // Change to wrong password
            encryption.setChannelPassword("wrong-password", for: channel)
            
            // Should fail to decrypt
            XCTAssertThrowsError(try encryption.decryptChannelMessage(encrypted, for: channel))
            
        } catch {
            XCTFail("Encryption failed: \(error)")
        }
    }
    
    func testEncryptionWithoutPassword() {
        let encryption = NoiseChannelEncryption()
        let channel = "#no-password"
        
        // Try to encrypt without setting password
        XCTAssertThrowsError(try encryption.encryptChannelMessage("Test", for: channel)) { error in
            // Should throw channelKeyMissing error
            if let encryptionError = error as? NoiseChannelEncryptionError {
                XCTAssertEqual(encryptionError, NoiseChannelEncryptionError.channelKeyMissing)
            } else {
                XCTFail("Wrong error type")
            }
        }
    }
    
    func testInvalidChannelName() {
        let encryption = NoiseChannelEncryption()
        
        // Empty channel
        XCTAssertThrowsError(try encryption.encryptChannelMessage("Test", for: ""))
        
        // Channel without # prefix
        XCTAssertThrowsError(try encryption.encryptChannelMessage("Test", for: "invalid"))
    }
    
    // MARK: - Performance Tests
    
    func testEncryptionPerformance() {
        let encryption = NoiseChannelEncryption()
        let channel = "#perf-test"
        let fingerprint = "e36f7993abc123def456789012345678901234567890abcdef1234567890abcd"
        
        encryption.setChannelPasswordForCreator("test-password", channel: channel, creatorFingerprint: fingerprint)
        
        let message = String(repeating: "Hello World! ", count: 100) // ~1.3KB message
        
        measure {
            do {
                let encrypted = try encryption.encryptChannelMessage(message, for: channel)
                _ = try encryption.decryptChannelMessage(encrypted, for: channel)
            } catch {
                XCTFail("Performance test failed: \(error)")
            }
        }
    }
}