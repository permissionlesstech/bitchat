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

final class NoiseProtocolTests: XCTestCase {
    
    var aliceKey: Curve25519.KeyAgreement.PrivateKey!
    var bobKey: Curve25519.KeyAgreement.PrivateKey!
    var aliceSession: NoiseSession!
    var bobSession: NoiseSession!
    
    override func setUp() {
        super.setUp()
        aliceKey = Curve25519.KeyAgreement.PrivateKey()
        bobKey = Curve25519.KeyAgreement.PrivateKey()
    }
    
    override func tearDown() {
        aliceSession = nil
        bobSession = nil
        super.tearDown()
    }
    
    // MARK: - Basic Handshake Tests
    
    func testXXPatternHandshake() throws {
        // Create sessions
        aliceSession = NoiseSession(
            peerID: TestConstants.testPeerID2,
            role: .initiator,
            localStaticKey: aliceKey
        )
        
        bobSession = NoiseSession(
            peerID: TestConstants.testPeerID1,
            role: .responder,
            localStaticKey: bobKey
        )
        
        // Alice starts handshake (message 1)
        let message1 = try aliceSession.startHandshake()
        XCTAssertFalse(message1.isEmpty)
        XCTAssertEqual(aliceSession.getState(), .handshaking)
        
        // Bob processes message 1 and creates message 2
        let message2 = try bobSession.processHandshakeMessage(message1)
        XCTAssertNotNil(message2)
        XCTAssertFalse(message2!.isEmpty)
        XCTAssertEqual(bobSession.getState(), .handshaking)
        
        // Alice processes message 2 and creates message 3
        let message3 = try aliceSession.processHandshakeMessage(message2!)
        XCTAssertNotNil(message3)
        XCTAssertFalse(message3!.isEmpty)
        XCTAssertEqual(aliceSession.getState(), .established)
        
        // Bob processes message 3 and completes handshake
        let finalMessage = try bobSession.processHandshakeMessage(message3!)
        XCTAssertNil(finalMessage) // No more messages needed
        XCTAssertEqual(bobSession.getState(), .established)
        
        // Verify both sessions are established
        XCTAssertTrue(aliceSession.isEstablished())
        XCTAssertTrue(bobSession.isEstablished())
        
        // Verify they have each other's static keys
        XCTAssertEqual(aliceSession.getRemoteStaticPublicKey()?.rawRepresentation, bobKey.publicKey.rawRepresentation)
        XCTAssertEqual(bobSession.getRemoteStaticPublicKey()?.rawRepresentation, aliceKey.publicKey.rawRepresentation)
    }
    
    func testHandshakeStateValidation() throws {
        aliceSession = NoiseSession(
            peerID: TestConstants.testPeerID2,
            role: .initiator,
            localStaticKey: aliceKey
        )
        
        // Cannot process message before starting handshake
        XCTAssertThrowsError(try aliceSession.processHandshakeMessage(Data()))
        
        // Start handshake
        _ = try aliceSession.startHandshake()
        
        // Cannot start handshake twice
        XCTAssertThrowsError(try aliceSession.startHandshake())
    }
    
    // MARK: - Encryption/Decryption Tests
    
    func testBasicEncryptionDecryption() throws {
        // Establish sessions
        try establishSessions()
        
        let plaintext = "Hello, Bob!".data(using: .utf8)!
        
        // Alice encrypts
        let ciphertext = try aliceSession.encrypt(plaintext)
        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertGreaterThan(ciphertext.count, plaintext.count) // Should have overhead
        
        // Bob decrypts
        let decrypted = try bobSession.decrypt(ciphertext)
        XCTAssertEqual(decrypted, plaintext)
    }
    
    func testBidirectionalEncryption() throws {
        try establishSessions()
        
        // Alice -> Bob
        let aliceMessage = "Hello from Alice".data(using: .utf8)!
        let aliceCiphertext = try aliceSession.encrypt(aliceMessage)
        let bobReceived = try bobSession.decrypt(aliceCiphertext)
        XCTAssertEqual(bobReceived, aliceMessage)
        
        // Bob -> Alice
        let bobMessage = "Hello from Bob".data(using: .utf8)!
        let bobCiphertext = try bobSession.encrypt(bobMessage)
        let aliceReceived = try aliceSession.decrypt(bobCiphertext)
        XCTAssertEqual(aliceReceived, bobMessage)
    }
    
    func testLargeMessageEncryption() throws {
        try establishSessions()
        
        // Create a large message
        let largeMessage = TestHelpers.generateRandomData(length: 100_000)
        
        // Encrypt and decrypt
        let ciphertext = try aliceSession.encrypt(largeMessage)
        let decrypted = try bobSession.decrypt(ciphertext)
        
        XCTAssertEqual(decrypted, largeMessage)
    }
    
    func testEncryptionBeforeHandshake() {
        aliceSession = NoiseSession(
            peerID: TestConstants.testPeerID2,
            role: .initiator,
            localStaticKey: aliceKey
        )
        
        let plaintext = "test".data(using: .utf8)!
        
        // Should throw when not established
        XCTAssertThrowsError(try aliceSession.encrypt(plaintext))
        XCTAssertThrowsError(try aliceSession.decrypt(plaintext))
    }
    
    // MARK: - Session Manager Tests
    
    func testSessionManagerBasicOperations() throws {
        let manager = NoiseSessionManager(localStaticKey: aliceKey)
        
        // Create session
        let session = manager.createSession(for: TestConstants.testPeerID2, role: .initiator)
        XCTAssertNotNil(session)
        
        // Get session
        let retrieved = manager.getSession(for: TestConstants.testPeerID2)
        XCTAssertNotNil(retrieved)
        XCTAssertTrue(session === retrieved)
        
        // Remove session
        manager.removeSession(for: TestConstants.testPeerID2)
        XCTAssertNil(manager.getSession(for: TestConstants.testPeerID2))
    }
    
    func testSessionManagerHandshakeInitiation() throws {
        let manager = NoiseSessionManager(localStaticKey: aliceKey)
        
        // Initiate handshake
        let handshakeData = try manager.initiateHandshake(with: TestConstants.testPeerID2)
        XCTAssertFalse(handshakeData.isEmpty)
        
        // Session should exist
        let session = manager.getSession(for: TestConstants.testPeerID2)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.getState(), .handshaking)
    }
    
    func testSessionManagerIncomingHandshake() throws {
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey)
        
        // Alice initiates
        let message1 = try aliceManager.initiateHandshake(with: TestConstants.testPeerID2)
        
        // Bob responds
        let message2 = try bobManager.handleIncomingHandshake(from: TestConstants.testPeerID1, message: message1)
        XCTAssertNotNil(message2)
        
        // Continue handshake
        let message3 = try aliceManager.handleIncomingHandshake(from: TestConstants.testPeerID2, message: message2!)
        XCTAssertNotNil(message3)
        
        // Complete handshake
        let finalMessage = try bobManager.handleIncomingHandshake(from: TestConstants.testPeerID1, message: message3!)
        XCTAssertNil(finalMessage)
        
        // Both should have established sessions
        XCTAssertTrue(aliceManager.getSession(for: TestConstants.testPeerID2)?.isEstablished() ?? false)
        XCTAssertTrue(bobManager.getSession(for: TestConstants.testPeerID1)?.isEstablished() ?? false)
    }
    
    func testSessionManagerEncryptionDecryption() throws {
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey)
        
        // Establish sessions
        try establishManagerSessions(aliceManager: aliceManager, bobManager: bobManager)
        
        // Encrypt with manager
        let plaintext = "Test message".data(using: .utf8)!
        let ciphertext = try aliceManager.encrypt(plaintext, for: TestConstants.testPeerID2)
        
        // Decrypt with manager
        let decrypted = try bobManager.decrypt(ciphertext, from: TestConstants.testPeerID1)
        XCTAssertEqual(decrypted, plaintext)
    }
    
    func testSessionMigration() throws {
        let manager = NoiseSessionManager(localStaticKey: aliceKey)
        
        // Create and establish a session
        _ = try manager.initiateHandshake(with: TestConstants.testPeerID2)
        
        // Migrate to new peer ID
        let newPeerID = TestConstants.testPeerID3
        manager.migrateSession(from: TestConstants.testPeerID2, to: newPeerID)
        
        // Old peer ID should not have session
        XCTAssertNil(manager.getSession(for: TestConstants.testPeerID2))
        
        // New peer ID should have the session
        XCTAssertNotNil(manager.getSession(for: newPeerID))
    }
    
    // MARK: - Security Tests
    
    func testTamperedCiphertextDetection() throws {
        try establishSessions()
        
        let plaintext = "Secret message".data(using: .utf8)!
        var ciphertext = try aliceSession.encrypt(plaintext)
        
        // Tamper with ciphertext
        ciphertext[ciphertext.count / 2] ^= 0xFF
        
        // Decryption should fail
        XCTAssertThrowsError(try bobSession.decrypt(ciphertext))
    }
    
    func testReplayPrevention() throws {
        try establishSessions()
        
        let plaintext = "Test message".data(using: .utf8)!
        let ciphertext = try aliceSession.encrypt(plaintext)
        
        // First decryption should succeed
        _ = try bobSession.decrypt(ciphertext)
        
        // Replaying the same ciphertext should fail
        XCTAssertThrowsError(try bobSession.decrypt(ciphertext))
    }
    
    func testSessionIsolation() throws {
        // Create two separate session pairs
        let aliceSession1 = NoiseSession(peerID: "peer1", role: .initiator, localStaticKey: aliceKey)
        let bobSession1 = NoiseSession(peerID: "alice1", role: .responder, localStaticKey: bobKey)
        
        let aliceSession2 = NoiseSession(peerID: "peer2", role: .initiator, localStaticKey: aliceKey)
        let bobSession2 = NoiseSession(peerID: "alice2", role: .responder, localStaticKey: bobKey)
        
        // Establish both pairs
        try performHandshake(initiator: aliceSession1, responder: bobSession1)
        try performHandshake(initiator: aliceSession2, responder: bobSession2)
        
        // Encrypt with session 1
        let plaintext = "Secret".data(using: .utf8)!
        let ciphertext1 = try aliceSession1.encrypt(plaintext)
        
        // Should not be able to decrypt with session 2
        XCTAssertThrowsError(try bobSession2.decrypt(ciphertext1))
        
        // But should work with correct session
        let decrypted = try bobSession1.decrypt(ciphertext1)
        XCTAssertEqual(decrypted, plaintext)
    }
    
    // MARK: - Performance Tests
    
    func testHandshakePerformance() throws {
        measure {
            do {
                let alice = NoiseSession(peerID: "bob", role: .initiator, localStaticKey: aliceKey)
                let bob = NoiseSession(peerID: "alice", role: .responder, localStaticKey: bobKey)
                try performHandshake(initiator: alice, responder: bob)
            } catch {
                XCTFail("Handshake failed: \(error)")
            }
        }
    }
    
    func testEncryptionPerformance() throws {
        try establishSessions()
        let message = TestHelpers.generateRandomData(length: 1024)
        
        measure {
            do {
                for _ in 0..<100 {
                    let ciphertext = try aliceSession.encrypt(message)
                    _ = try bobSession.decrypt(ciphertext)
                }
            } catch {
                XCTFail("Encryption/decryption failed: \(error)")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func establishSessions() throws {
        aliceSession = NoiseSession(
            peerID: TestConstants.testPeerID2,
            role: .initiator,
            localStaticKey: aliceKey
        )
        
        bobSession = NoiseSession(
            peerID: TestConstants.testPeerID1,
            role: .responder,
            localStaticKey: bobKey
        )
        
        try performHandshake(initiator: aliceSession, responder: bobSession)
    }
    
    private func performHandshake(initiator: NoiseSession, responder: NoiseSession) throws {
        let msg1 = try initiator.startHandshake()
        let msg2 = try responder.processHandshakeMessage(msg1)!
        let msg3 = try initiator.processHandshakeMessage(msg2)!
        _ = try responder.processHandshakeMessage(msg3)
    }
    
    private func establishManagerSessions(aliceManager: NoiseSessionManager, bobManager: NoiseSessionManager) throws {
        let msg1 = try aliceManager.initiateHandshake(with: TestConstants.testPeerID2)
        let msg2 = try bobManager.handleIncomingHandshake(from: TestConstants.testPeerID1, message: msg1)!
        let msg3 = try aliceManager.handleIncomingHandshake(from: TestConstants.testPeerID2, message: msg2)!
        _ = try bobManager.handleIncomingHandshake(from: TestConstants.testPeerID1, message: msg3)
    }
}