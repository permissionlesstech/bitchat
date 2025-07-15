//
// SecureNoiseSessionTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CryptoKit
@testable import bitchat

class SecureNoiseSessionTests: XCTestCase {
    
    // MARK: - Session Timeout Tests
    
    func testSessionTimesOutAfter30Minutes() {
        let aliceKey = Curve25519.KeyAgreement.PrivateKey()
        let session = SecureNoiseSession(peerID: "bob", role: .initiator, localStaticKey: aliceKey)
        
        // Complete handshake
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        var bob = NoiseHandshakeState(role: .responder, pattern: .XX, localStaticKey: bobKey)
        
        // Perform handshake
        do {
            let msg1 = try session.startHandshake()
            _ = try bob.readMessage(msg1)
            
            let msg2 = try bob.writeMessage()
            _ = try session.processHandshakeMessage(msg2)
            
            let msg3 = try session.writeMessage()
            _ = try bob.readMessage(msg3)
            
            XCTAssertTrue(session.isEstablished())
            
            // Check initial state
            XCTAssertFalse(session.needsRenegotiation())
            
            // Fast-forward time by setting lastActivity to 31 minutes ago
            let thirtyOneMinutesAgo = Date().addingTimeInterval(-31 * 60)
            session.setLastActivityTimeForTesting(thirtyOneMinutesAgo)
            
            // Should now need renegotiation
            XCTAssertTrue(session.needsRenegotiation())
            
        } catch {
            XCTFail("Handshake failed: \(error)")
        }
    }
    
    func testSessionRemainsValidUnder30Minutes() {
        let aliceKey = Curve25519.KeyAgreement.PrivateKey()
        let session = SecureNoiseSession(peerID: "bob", role: .initiator, localStaticKey: aliceKey)
        
        // Complete handshake
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        var bob = NoiseHandshakeState(role: .responder, pattern: .XX, localStaticKey: bobKey)
        
        do {
            let msg1 = try session.startHandshake()
            _ = try bob.readMessage(msg1)
            
            let msg2 = try bob.writeMessage()
            _ = try session.processHandshakeMessage(msg2)
            
            let msg3 = try session.writeMessage()
            _ = try bob.readMessage(msg3)
            
            XCTAssertTrue(session.isEstablished())
            
            // Set lastActivity to 29 minutes ago
            let twentyNineMinutesAgo = Date().addingTimeInterval(-29 * 60)
            session.setLastActivityTimeForTesting(twentyNineMinutesAgo)
            
            // Should NOT need renegotiation
            XCTAssertFalse(session.needsRenegotiation())
            
        } catch {
            XCTFail("Handshake failed: \(error)")
        }
    }
    
    // MARK: - Message Count Limit Tests
    
    func testSessionNeedsRekeyAfterMessageLimit() {
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
            
            // Check initial state
            XCTAssertFalse(alice.needsRenegotiation())
            
            // Set message count to just under 90% threshold (900,000)
            alice.setMessageCountForTesting(899_999)
            XCTAssertFalse(alice.needsRenegotiation())
            
            // Set message count to 90% threshold
            alice.setMessageCountForTesting(900_000)
            XCTAssertTrue(alice.needsRenegotiation())
            
        } catch {
            XCTFail("Handshake failed: \(error)")
        }
    }
    
    // MARK: - Activity Tracking Tests
    
    func testActivityUpdatesOnEncryption() {
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
            
            // Set lastActivity to 5 minutes ago
            let fiveMinutesAgo = Date().addingTimeInterval(-5 * 60)
            alice.setLastActivityTimeForTesting(fiveMinutesAgo)
            
            // Encrypt a message
            let plaintext = Data("Hello Bob".utf8)
            _ = try alice.encrypt(plaintext)
            
            // Activity should be updated to now
            let timeSinceUpdate = Date().timeIntervalSince(alice.lastActivityTime)
            XCTAssertLessThan(timeSinceUpdate, 1.0) // Should be within 1 second
            
        } catch {
            XCTFail("Test failed: \(error)")
        }
    }
    
    func testActivityUpdatesOnDecryption() {
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
            
            // Encrypt a message from Alice
            let plaintext = Data("Hello Bob".utf8)
            let ciphertext = try alice.encrypt(plaintext)
            
            // Set Bob's lastActivity to 5 minutes ago
            let fiveMinutesAgo = Date().addingTimeInterval(-5 * 60)
            bob.setLastActivityTimeForTesting(fiveMinutesAgo)
            
            // Decrypt the message
            _ = try bob.decrypt(ciphertext)
            
            // Activity should be updated to now
            let timeSinceUpdate = Date().timeIntervalSince(bob.lastActivityTime)
            XCTAssertLessThan(timeSinceUpdate, 1.0) // Should be within 1 second
            
        } catch {
            XCTFail("Test failed: \(error)")
        }
    }
    
    // MARK: - Message Count Tracking Tests
    
    func testMessageCountIncrements() {
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
            
            // Check initial message count
            XCTAssertEqual(alice.messageCount, 0)
            
            // Send multiple messages
            for i in 1...5 {
                let plaintext = Data("Message \(i)".utf8)
                let ciphertext = try alice.encrypt(plaintext)
                _ = try bob.decrypt(ciphertext)
            }
            
            // Check message count incremented
            XCTAssertEqual(alice.messageCount, 5) // Alice sent 5 messages
            XCTAssertEqual(bob.messageCount, 0)   // Bob received but didn't send
            
        } catch {
            XCTFail("Test failed: \(error)")
        }
    }
    
    // MARK: - Integration Tests
    
    func testFullSessionLifecycle() {
        let aliceKey = Curve25519.KeyAgreement.PrivateKey()
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        
        let alice = SecureNoiseSession(peerID: "bob", role: .initiator, localStaticKey: aliceKey)
        let bob = SecureNoiseSession(peerID: "alice", role: .responder, localStaticKey: bobKey)
        
        do {
            // 1. Perform handshake
            let msg1 = try alice.startHandshake()
            _ = try bob.processHandshakeMessage(msg1)
            
            let msg2 = try bob.writeMessage()
            _ = try alice.processHandshakeMessage(msg2)
            
            let msg3 = try alice.writeMessage()
            _ = try bob.processHandshakeMessage(msg3)
            
            XCTAssertTrue(alice.isEstablished())
            XCTAssertTrue(bob.isEstablished())
            
            // 2. Exchange messages
            let message1 = "Hello from Alice"
            let ciphertext1 = try alice.encrypt(Data(message1.utf8))
            let decrypted1 = try bob.decrypt(ciphertext1)
            XCTAssertEqual(String(data: decrypted1, encoding: .utf8), message1)
            
            let message2 = "Hello from Bob"
            let ciphertext2 = try bob.encrypt(Data(message2.utf8))
            let decrypted2 = try alice.decrypt(ciphertext2)
            XCTAssertEqual(String(data: decrypted2, encoding: .utf8), message2)
            
            // 3. Check session health
            XCTAssertFalse(alice.needsRenegotiation())
            XCTAssertFalse(bob.needsRenegotiation())
            
            // 4. Simulate time passing
            let oldTime = Date().addingTimeInterval(-35 * 60)
            alice.setLastActivityTimeForTesting(oldTime)
            
            // 5. Check renegotiation needed
            XCTAssertTrue(alice.needsRenegotiation())
            
        } catch {
            XCTFail("Test failed: \(error)")
        }
    }
}