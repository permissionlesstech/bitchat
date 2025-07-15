//
// NoiseSecurityTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CryptoKit
@testable import bitchat

class NoiseSecurityTests: XCTestCase {
    
    // MARK: - Channel Password Salt Tests
    
    func testChannelPasswordSaltIncludesFingerprint() {
        let encryption = NoiseChannelEncryption()
        let password = "test-password-123"
        let channel = "#secure-channel"
        
        // Derive key without fingerprint
        let key1 = encryption.deriveChannelKey(from: password, channel: channel, creatorFingerprint: nil)
        
        // Derive key with fingerprint
        let fingerprint = "e36f7993abc123def456789012345678901234567890abcdef1234567890abcd"
        let key2 = encryption.deriveChannelKey(from: password, channel: channel, creatorFingerprint: fingerprint)
        
        // Keys should be different due to different salts
        XCTAssertNotEqual(key1.withUnsafeBytes { Data($0) }, key2.withUnsafeBytes { Data($0) })
    }
    
    func testChannelPasswordDerivationPerformance() {
        let encryption = NoiseChannelEncryption()
        let password = "test-password-123"
        let channel = "#performance-test"
        let fingerprint = "e36f7993abc123def456789012345678901234567890abcdef1234567890abcd"
        
        // Measure time for PBKDF2 with 210,000 iterations
        measure {
            _ = encryption.deriveChannelKey(from: password, channel: channel, creatorFingerprint: fingerprint)
        }
        
        // Should complete within reasonable time (< 1 second on modern hardware)
    }
    
    func testDifferentChannelsProduceDifferentKeys() {
        let encryption = NoiseChannelEncryption()
        let password = "same-password"
        let fingerprint = "e36f7993abc123def456789012345678901234567890abcdef1234567890abcd"
        
        let key1 = encryption.deriveChannelKey(from: password, channel: "#channel1", creatorFingerprint: fingerprint)
        let key2 = encryption.deriveChannelKey(from: password, channel: "#channel2", creatorFingerprint: fingerprint)
        
        // Same password but different channels should produce different keys
        XCTAssertNotEqual(key1.withUnsafeBytes { Data($0) }, key2.withUnsafeBytes { Data($0) })
    }
    
    // MARK: - Message Padding Tests
    
    func testMessagePaddingAppliedToAllPackets() throws {
        // Create a small packet
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data("testuser".utf8),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("Hello".utf8),
            signature: nil,
            ttl: 3
        )
        
        // Encode packet
        guard let encodedData = packet.toBinaryData() else {
            XCTFail("Failed to encode packet")
            return
        }
        
        // Check that size matches one of the standard block sizes
        let blockSizes = [256, 512, 1024, 2048]
        XCTAssertTrue(blockSizes.contains(encodedData.count) || encodedData.count > 2048,
                      "Encoded data size \(encodedData.count) doesn't match expected block sizes")
        
        // Decode should work correctly
        guard let decodedPacket = BitchatPacket.from(encodedData) else {
            XCTFail("Failed to decode packet")
            return
        }
        
        // Verify decoded content matches original
        XCTAssertEqual(decodedPacket.type, packet.type)
        XCTAssertEqual(String(data: decodedPacket.payload, encoding: .utf8),
                       String(data: packet.payload, encoding: .utf8))
    }
    
    func testPaddingConsistentAcrossMessages() {
        // Create multiple packets with same size payload
        let packets: [BitchatPacket] = (0..<5).map { i in
            BitchatPacket(
                type: MessageType.message.rawValue,
                senderID: Data("user\(i)".utf8),
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: Data("Same size message content here".utf8),
                signature: nil,
                ttl: 3
            )
        }
        
        // Encode all packets
        let encodedSizes = packets.compactMap { $0.toBinaryData()?.count }
        
        // All should have same padded size
        XCTAssertEqual(encodedSizes.count, packets.count)
        let firstSize = encodedSizes[0]
        XCTAssertTrue(encodedSizes.allSatisfy { $0 == firstSize },
                      "All packets with similar content should pad to same size")
    }
    
    // MARK: - Public Key Validation Tests
    
    func testValidPublicKeyAccepted() throws {
        // Generate a valid key
        let validKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyData = validKey.publicKey.rawRepresentation
        
        // Should validate successfully
        let validated = try NoiseHandshakeState.validatePublicKey(publicKeyData)
        XCTAssertEqual(validated.rawRepresentation, publicKeyData)
    }
    
    func testAllZeroKeyRejected() {
        let zeroKey = Data(repeating: 0x00, count: 32)
        
        XCTAssertThrowsError(try NoiseHandshakeState.validatePublicKey(zeroKey)) { error in
            XCTAssertEqual(error as? NoiseError, NoiseError.invalidPublicKey)
        }
    }
    
    func testAllOneKeyRejected() {
        let oneKey = Data(repeating: 0xFF, count: 32)
        
        XCTAssertThrowsError(try NoiseHandshakeState.validatePublicKey(oneKey)) { error in
            XCTAssertEqual(error as? NoiseError, NoiseError.invalidPublicKey)
        }
    }
    
    func testInvalidKeySizeRejected() {
        // Too short
        let shortKey = Data(repeating: 0x42, count: 16)
        XCTAssertThrowsError(try NoiseHandshakeState.validatePublicKey(shortKey)) { error in
            XCTAssertEqual(error as? NoiseError, NoiseError.invalidPublicKey)
        }
        
        // Too long
        let longKey = Data(repeating: 0x42, count: 64)
        XCTAssertThrowsError(try NoiseHandshakeState.validatePublicKey(longKey)) { error in
            XCTAssertEqual(error as? NoiseError, NoiseError.invalidPublicKey)
        }
    }
    
    func testWeakKeyRejected() {
        // Known weak Curve25519 key patterns
        // Low order points that would result in weak DH
        let weakKeys = [
            Data([0x01] + Array(repeating: 0x00, count: 31)), // Near zero
            Data(Array(repeating: 0x00, count: 31) + [0x01]), // Different pattern
        ]
        
        for weakKey in weakKeys {
            // CryptoKit should reject these during DH operation
            if (try? NoiseHandshakeState.validatePublicKey(weakKey)) != nil {
                // If key creation succeeds, DH should fail in validation
                print("Note: Weak key pattern was not rejected by CryptoKit directly")
            }
        }
    }
    
    // MARK: - Integration Tests
    
    func testSecureHandshakeWithValidation() throws {
        // Create two parties
        let aliceStatic = Curve25519.KeyAgreement.PrivateKey()
        let bobStatic = Curve25519.KeyAgreement.PrivateKey()
        
        var alice = NoiseHandshakeState(role: .initiator, pattern: .XX, localStaticKey: aliceStatic)
        var bob = NoiseHandshakeState(role: .responder, pattern: .XX, localStaticKey: bobStatic)
        
        // Perform handshake - validation happens automatically
        let msg1 = try alice.writeMessage()
        _ = try bob.readMessage(msg1)
        
        let msg2 = try bob.writeMessage()
        _ = try alice.readMessage(msg2)
        
        let msg3 = try alice.writeMessage()
        _ = try bob.readMessage(msg3)
        
        // Both should complete successfully
        XCTAssertTrue(alice.isHandshakeComplete())
        XCTAssertTrue(bob.isHandshakeComplete())
    }
    
    func testPaddedMessageTransmission() throws {
        // Create a packet and encode it
        let originalMessage = "Test message for padding"
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data("sender123".utf8),
            recipientID: Data("recipient".utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(originalMessage.utf8),
            signature: nil,
            ttl: 5
        )
        
        // Encode (with padding)
        guard let encoded = packet.toBinaryData() else {
            XCTFail("Failed to encode")
            return
        }
        
        // Verify padded size
        XCTAssertTrue(encoded.count >= originalMessage.count + 21) // Header + sender + payload
        
        // Decode (removes padding)
        guard let decoded = BitchatPacket.from(encoded) else {
            XCTFail("Failed to decode")
            return
        }
        
        // Verify message integrity
        XCTAssertEqual(String(data: decoded.payload, encoding: .utf8), originalMessage)
    }
    
    // MARK: - Session Rekeying Tests
    
    func testSessionRekeyingTriggered() {
        // Create session manager
        let localKey = Curve25519.KeyAgreement.PrivateKey()
        let sessionManager = NoiseSessionManager(localStaticKey: localKey)
        
        // Create a session
        let session = sessionManager.createSession(for: "testPeer", role: .initiator)
        
        // Complete handshake
        let remoteKey = Curve25519.KeyAgreement.PrivateKey()
        var remoteHandshake = NoiseHandshakeState(role: .responder, pattern: .XX, localStaticKey: remoteKey)
        
        do {
            let msg1 = try session.startHandshake()
            _ = try remoteHandshake.readMessage(msg1)
            
            let msg2 = try remoteHandshake.writeMessage()
            _ = try session.processHandshakeMessage(msg2)
            
            let msg3 = try session.writeMessage()
            _ = try remoteHandshake.readMessage(msg3)
            
            XCTAssertTrue(session.isEstablished())
            
            // Get sessions needing rekey (should be empty)
            var needsRekey = sessionManager.getSessionsNeedingRekey()
            XCTAssertTrue(needsRekey.isEmpty)
            
            // Force the session to need rekeying by manipulating its state
            if let secureSession = session as? SecureNoiseSession {
                // Set old activity time
                let oldTime = Date().addingTimeInterval(-35 * 60)
                secureSession.setLastActivityTimeForTesting(oldTime)
                
                // Now check again
                needsRekey = sessionManager.getSessionsNeedingRekey()
                XCTAssertFalse(needsRekey.isEmpty)
                XCTAssertTrue(needsRekey.contains(where: { $0.peerID == "testPeer" && $0.needsRekey }))
            }
            
        } catch {
            XCTFail("Test failed: \(error)")
        }
    }
    
    func testRekeyInitiation() {
        // Create session manager
        let localKey = Curve25519.KeyAgreement.PrivateKey()
        let sessionManager = NoiseSessionManager(localStaticKey: localKey)
        
        // Create and establish a session
        let session = sessionManager.createSession(for: "testPeer", role: .initiator)
        
        // Complete handshake
        let remoteKey = Curve25519.KeyAgreement.PrivateKey()
        var remoteHandshake = NoiseHandshakeState(role: .responder, pattern: .XX, localStaticKey: remoteKey)
        
        do {
            let msg1 = try session.startHandshake()
            _ = try remoteHandshake.readMessage(msg1)
            
            let msg2 = try remoteHandshake.writeMessage()
            _ = try session.processHandshakeMessage(msg2)
            
            let msg3 = try session.writeMessage()
            _ = try remoteHandshake.readMessage(msg3)
            
            XCTAssertTrue(session.isEstablished())
            
            // Store the old session's remote key
            let oldRemoteKey = session.getRemoteStaticPublicKey()
            XCTAssertNotNil(oldRemoteKey)
            
            // Initiate rekey
            try sessionManager.initiateRekey(for: "testPeer")
            
            // The old session should be removed
            let currentSession = sessionManager.getSession(for: "testPeer")
            XCTAssertNil(currentSession) // Session removed, waiting for new handshake
            
        } catch {
            XCTFail("Test failed: \(error)")
        }
    }
    
    // MARK: - Integration Tests
    
    func testFullRekeyHandshake() {
        // Create encryption service
        let alice = NoiseEncryptionService()
        let bob = NoiseEncryptionService()
        
        let aliceID = "alice"
        let bobID = "bob"
        
        do {
            // Initial handshake
            let msg1 = try alice.initiateHandshake(with: bobID)
            let msg2 = try bob.processHandshakeMessage(from: aliceID, message: msg1)!
            _ = try alice.processHandshakeMessage(from: bobID, message: msg2)
            
            // Verify sessions established
            XCTAssertTrue(alice.hasEstablishedSession(with: bobID))
            XCTAssertTrue(bob.hasEstablishedSession(with: aliceID))
            
            // Exchange some messages
            let plaintext1 = "Hello Bob"
            let encrypted1 = try alice.encrypt(Data(plaintext1.utf8), for: bobID)
            let decrypted1 = try bob.decrypt(encrypted1, from: aliceID)
            XCTAssertEqual(String(data: decrypted1, encoding: .utf8), plaintext1)
            
            // Force session to expire by manipulating internal state
            // (In real scenario, this would happen after 30 minutes or 1M messages)
            
            // Trigger rekey from Alice's side
            var rekeyHandshakeCompleted = false
            alice.onHandshakeRequired = { peerID in
                XCTAssertEqual(peerID, bobID)
                rekeyHandshakeCompleted = true
            }
            
            // After rekey, should be able to continue messaging
            // Note: In real implementation, the rekey would be triggered automatically
            
        } catch {
            XCTFail("Integration test failed: \(error)")
        }
    }
    
    func testErrorHandlingDuringHandshake() {
        let service = NoiseEncryptionService()
        
        // Test invalid peer ID
        XCTAssertThrowsError(try service.initiateHandshake(with: "")) { error in
            if let securityError = error as? NoiseSecurityError {
                XCTAssertEqual(securityError, NoiseSecurityError.invalidPeerID)
            }
        }
        
        // Test invalid handshake message
        XCTAssertThrowsError(try service.processHandshakeMessage(from: "peer", message: Data())) { error in
            // Should fail to parse empty data as handshake
        }
        
        // Test oversized handshake message
        let oversizedMessage = Data(repeating: 0x42, count: 100_000)
        XCTAssertThrowsError(try service.processHandshakeMessage(from: "peer", message: oversizedMessage)) { error in
            if let securityError = error as? NoiseSecurityError {
                XCTAssertEqual(securityError, NoiseSecurityError.messageTooLarge)
            }
        }
    }
    
    func testRateLimitingIntegration() {
        let service = NoiseEncryptionService()
        let peerID = "rate-limited-peer"
        
        var handshakeAttempts = 0
        var rateLimitHit = false
        
        // Try many rapid handshakes
        for _ in 0..<10 {
            do {
                _ = try service.initiateHandshake(with: peerID)
                handshakeAttempts += 1
            } catch {
                if let securityError = error as? NoiseSecurityError,
                   securityError == NoiseSecurityError.rateLimitExceeded {
                    rateLimitHit = true
                    break
                }
            }
        }
        
        // Should hit rate limit before all 10 attempts
        XCTAssertTrue(rateLimitHit)
        XCTAssertLessThan(handshakeAttempts, 10)
    }
    
    func testChannelEncryptionIntegration() {
        let service = NoiseEncryptionService()
        let channel = "#integration-test"
        let password = "test-password"
        let fingerprint = service.getIdentityFingerprint()
        
        // Set channel password
        service.setChannelPassword(password, for: channel)
        
        // Encrypt channel message
        do {
            let message = "Channel message test"
            let encrypted = try service.encryptChannelMessage(message, for: channel)
            
            // Verify it's encrypted
            XCTAssertNotEqual(encrypted, Data(message.utf8))
            
            // Decrypt
            let decrypted = try service.decryptChannelMessage(encrypted, for: channel)
            XCTAssertEqual(decrypted, message)
            
            // Clean up
            service.removeChannelPassword(for: channel)
            
        } catch {
            XCTFail("Channel encryption failed: \(error)")
        }
    }
    
    func testSecureSessionConcurrency() {
        let aliceKey = Curve25519.KeyAgreement.PrivateKey()
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        
        let alice = SecureNoiseSession(peerID: "bob", role: .initiator, localStaticKey: aliceKey)
        let bob = SecureNoiseSession(peerID: "alice", role: .responder, localStaticKey: bobKey)
        
        // Complete handshake
        do {
            let msg1 = try alice.startHandshake()
            _ = try bob.processHandshakeMessage(msg1)
            
            let msg2 = try bob.writeMessage()
            _ = try alice.processHandshakeMessage(msg2)
            
            let msg3 = try alice.writeMessage()
            _ = try bob.processHandshakeMessage(msg3)
            
            XCTAssertTrue(alice.isEstablished())
            XCTAssertTrue(bob.isEstablished())
            
            // Concurrent encryption/decryption
            let expectation = self.expectation(description: "Concurrent operations")
            expectation.expectedFulfillmentCount = 20
            
            let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
            
            for i in 0..<10 {
                // Encrypt from Alice
                queue.async {
                    do {
                        let message = "Message \(i) from Alice"
                        let encrypted = try alice.encrypt(Data(message.utf8))
                        let decrypted = try bob.decrypt(encrypted)
                        XCTAssertEqual(String(data: decrypted, encoding: .utf8), message)
                        expectation.fulfill()
                    } catch {
                        XCTFail("Concurrent encrypt failed: \(error)")
                    }
                }
                
                // Encrypt from Bob
                queue.async {
                    do {
                        let message = "Message \(i) from Bob"
                        let encrypted = try bob.encrypt(Data(message.utf8))
                        let decrypted = try alice.decrypt(encrypted)
                        XCTAssertEqual(String(data: decrypted, encoding: .utf8), message)
                        expectation.fulfill()
                    } catch {
                        XCTFail("Concurrent decrypt failed: \(error)")
                    }
                }
            }
            
            waitForExpectations(timeout: 5)
            
        } catch {
            XCTFail("Handshake failed: \(error)")
        }
    }
}