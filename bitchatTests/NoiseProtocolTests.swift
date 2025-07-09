//
// NoiseProtocolTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CryptoKit
@testable import bitchat

class NoiseProtocolTests: XCTestCase {
    
    var alice: NoiseProtocolManager!
    var bob: NoiseProtocolManager!
    
    override func setUp() {
        super.setUp()
        
        // Create noise protocol managers for Alice and Bob
        alice = try? NoiseProtocolManager()
        bob = try? NoiseProtocolManager()
    }
    
    override func tearDown() {
        alice = nil
        bob = nil
        
        super.tearDown()
    }
    
    // MARK: - Basic Functionality Tests
    
    func testNoiseProtocolInitialization() {
        XCTAssertNoThrow(try NoiseProtocolManager())
    }
    
    func testXXHandshake() throws {
        // Alice initiates handshake
        guard let msg1 = try alice.startHandshake(with: "bob", isInitiator: true) else {
            XCTFail("Alice should generate initial handshake message")
            return
        }
        
        // Bob responds to Alice's message
        _ = try bob.startHandshake(with: "alice", isInitiator: false)
        guard let msg2 = try bob.processHandshakeMessage(msg1, from: "alice") else {
            XCTFail("Bob should generate response message")
            return
        }
        
        // Alice processes Bob's response and sends final message
        guard let msg3 = try alice.processHandshakeMessage(msg2, from: "bob") else {
            XCTFail("Alice should generate final message")
            return
        }
        
        // Bob processes Alice's final message
        _ = try bob.processHandshakeMessage(msg3, from: "alice")
        
        // Both should have completed handshake
        XCTAssertTrue(alice.isHandshakeComplete(for: "bob"))
        XCTAssertTrue(bob.isHandshakeComplete(for: "alice"))
    }
    
    func testBidirectionalMessaging() {
        do {
            // Complete handshake
            try completeHandshake()
            
            // Alice sends message to Bob
            let message1 = "Hello Bob!".data(using: .utf8)!
            let encrypted1 = try alice.encrypt(message1, for: "bob")
            let decrypted1 = try bob.decrypt(encrypted1, from: "alice")
            XCTAssertEqual(decrypted1, message1)
            
            // Bob sends message to Alice
            let message2 = "Hello Alice!".data(using: .utf8)!
            let encrypted2 = try bob.encrypt(message2, for: "alice")
            let decrypted2 = try alice.decrypt(encrypted2, from: "bob")
            XCTAssertEqual(decrypted2, message2)
            
        } catch {
            XCTFail("Bidirectional messaging failed: \(error)")
        }
    }
    
    func testMultipleSequentialMessages() {
        do {
            // Complete handshake
            try completeHandshake()
            
            // Send multiple messages in sequence
            for i in 0..<10 {
                let message = "Message \(i)".data(using: .utf8)!
                let encrypted = try alice.encrypt(message, for: "bob")
                let decrypted = try bob.decrypt(encrypted, from: "alice")
                XCTAssertEqual(decrypted, message)
            }
            
        } catch {
            XCTFail("Sequential messaging failed: \(error)")
        }
    }
    
    func testLargeMessageHandling() {
        do {
            // Complete handshake
            try completeHandshake()
            
            // Create a large message (10KB)
            let largeMessage = Data(repeating: 0x42, count: 10240)
            let encrypted = try alice.encrypt(largeMessage, for: "bob")
            let decrypted = try bob.decrypt(encrypted, from: "alice")
            XCTAssertEqual(decrypted, largeMessage)
            
        } catch {
            XCTFail("Large message handling failed: \(error)")
        }
    }
    
    // MARK: - Session Management Tests
    
    func testSessionRemoval() {
        do {
            // Complete handshake
            try completeHandshake()
            
            // Verify session exists
            XCTAssertTrue(alice.isHandshakeComplete(for: "bob"))
            
            // Remove session
            alice.removeSession(for: "bob")
            
            // Verify session is removed
            XCTAssertFalse(alice.isHandshakeComplete(for: "bob"))
            
        } catch {
            XCTFail("Session removal failed: \(error)")
        }
    }
    
    func testMultiplePeerSessions() {
        do {
            let charlie = try NoiseProtocolManager()
            
            // Alice establishes sessions with both Bob and Charlie
            try completeHandshake()
            
            // Complete handshake with Charlie
            guard let msg1 = try alice.startHandshake(with: "charlie", isInitiator: true) else {
                XCTFail("Alice should generate initial handshake message")
                return
            }
            
            _ = try charlie.startHandshake(with: "alice", isInitiator: false)
            guard let msg2 = try charlie.processHandshakeMessage(msg1, from: "alice") else {
                XCTFail("Charlie should generate response message")
                return
            }
            
            guard let msg3 = try alice.processHandshakeMessage(msg2, from: "charlie") else {
                XCTFail("Alice should generate final message")
                return
            }
            
            _ = try charlie.processHandshakeMessage(msg3, from: "alice")
            
            // Verify both sessions exist
            XCTAssertTrue(alice.isHandshakeComplete(for: "bob"))
            XCTAssertTrue(alice.isHandshakeComplete(for: "charlie"))
            
            // Test messaging with both peers
            let message = "Hello".data(using: .utf8)!
            
            // Message to Bob
            let encryptedToBob = try alice.encrypt(message, for: "bob")
            let decryptedByBob = try bob.decrypt(encryptedToBob, from: "alice")
            XCTAssertEqual(decryptedByBob, message)
            
            // Message to Charlie
            let encryptedToCharlie = try alice.encrypt(message, for: "charlie")
            let decryptedByCharlie = try charlie.decrypt(encryptedToCharlie, from: "alice")
            XCTAssertEqual(decryptedByCharlie, message)
            
        } catch {
            XCTFail("Multiple peer sessions failed: \(error)")
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testDecryptionWithoutHandshake() {
        do {
            // Try to decrypt without handshake
            let fakeData = Data([1, 2, 3, 4])
            XCTAssertThrowsError(try alice.decrypt(fakeData, from: "bob"))
            
        } catch {
            XCTFail("Test setup failed: \(error)")
        }
    }
    
    func testEncryptionWithoutHandshake() {
        do {
            // Try to encrypt without handshake
            let message = "Hello".data(using: .utf8)!
            XCTAssertThrowsError(try alice.encrypt(message, for: "bob"))
            
        } catch {
            XCTFail("Test setup failed: \(error)")
        }
    }
    
    func testCorruptedHandshakeMessage() {
        do {
            // Alice initiates handshake
            guard let msg1 = try alice.startHandshake(with: "bob", isInitiator: true) else {
                XCTFail("Alice should generate initial handshake message")
                return
            }
            
            // Corrupt the message
            var corruptedMsg = msg1
            corruptedMsg[0] = corruptedMsg[0] ^ 0xFF
            
            // Bob tries to process corrupted message
            _ = try bob.startHandshake(with: "alice", isInitiator: false)
            XCTAssertThrowsError(try bob.processHandshakeMessage(corruptedMsg, from: "alice"))
            
        } catch {
            XCTFail("Test setup failed: \(error)")
        }
    }
    
    // MARK: - Session Cleanup Tests
    
    func testStaleSessionCleanup() {
        do {
            // Complete handshake
            try completeHandshake()
            
            // Verify session exists
            XCTAssertTrue(alice.isHandshakeComplete(for: "bob"))
            
            // Clean up stale sessions
            alice.cleanupStaleSessions()
            
            // Session should still exist if not stale
            XCTAssertTrue(alice.isHandshakeComplete(for: "bob"))
            
        } catch {
            XCTFail("Session cleanup failed: \(error)")
        }
    }
    
    // MARK: - Performance Tests
    
    func testHandshakePerformance() {
        measure {
            do {
                let testAlice = try NoiseProtocolManager()
                let testBob = try NoiseProtocolManager()
                
                // Complete handshake
                guard let msg1 = try testAlice.startHandshake(with: "bob", isInitiator: true) else {
                    XCTFail("Alice should generate initial handshake message")
                    return
                }
                
                _ = try testBob.startHandshake(with: "alice", isInitiator: false)
                guard let msg2 = try testBob.processHandshakeMessage(msg1, from: "alice") else {
                    XCTFail("Bob should generate response message")
                    return
                }
                
                guard let msg3 = try testAlice.processHandshakeMessage(msg2, from: "bob") else {
                    XCTFail("Alice should generate final message")
                    return
                }
                
                _ = try testBob.processHandshakeMessage(msg3, from: "alice")
                
            } catch {
                XCTFail("Performance test failed: \(error)")
            }
        }
    }
    
    func testEncryptionPerformance() {
        do {
            try completeHandshake()
            
            let message = "Performance test message".data(using: .utf8)!
            
            measure {
                do {
                    let encrypted = try alice.encrypt(message, for: "bob")
                    _ = try bob.decrypt(encrypted, from: "alice")
                } catch {
                    XCTFail("Performance test failed: \(error)")
                }
            }
        } catch {
            XCTFail("Performance test setup failed: \(error)")
        }
    }
    
    // MARK: - Utility Methods
    
    private func completeHandshake() throws {
        // Alice initiates handshake
        guard let msg1 = try alice.startHandshake(with: "bob", isInitiator: true) else {
            throw TestError.handshakeFailed("Alice should generate initial message")
        }
        
        // Bob starts as responder and processes Alice's message
        _ = try bob.startHandshake(with: "alice", isInitiator: false)
        guard let msg2 = try bob.processHandshakeMessage(msg1, from: "alice") else {
            throw TestError.handshakeFailed("Bob should generate response message")
        }
        
        // Alice processes Bob's response and sends final message
        guard let msg3 = try alice.processHandshakeMessage(msg2, from: "bob") else {
            throw TestError.handshakeFailed("Alice should generate final message")
        }
        
        // Bob processes Alice's final message
        _ = try bob.processHandshakeMessage(msg3, from: "alice")
        
        // Verify handshake completion
        guard alice.isHandshakeComplete(for: "bob") && bob.isHandshakeComplete(for: "alice") else {
            throw TestError.handshakeFailed("Handshake should be complete")
        }
    }
    
    private enum TestError: Error {
        case handshakeFailed(String)
    }
}