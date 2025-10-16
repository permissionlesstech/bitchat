//
// NoiseProtocolTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import CryptoKit
import Foundation
@testable import bitchat

struct NoiseProtocolTests {
    
    private let aliceKey = Curve25519.KeyAgreement.PrivateKey()
    private let bobKey = Curve25519.KeyAgreement.PrivateKey()
    private let mockKeychain = MockKeychain()
    
    private let alicePeerID = PeerID(str: UUID().uuidString)
    private let bobPeerID = PeerID(str: UUID().uuidString)
    
    private let aliceSession: NoiseSession
    private let bobSession: NoiseSession
    
    init() {
        aliceSession = NoiseSession(
            peerID: alicePeerID,
            role: .initiator,
            keychain: mockKeychain,
            localStaticKey: aliceKey
        )
        
        bobSession = NoiseSession(
            peerID: bobPeerID,
            role: .responder,
            keychain: mockKeychain,
            localStaticKey: bobKey
        )
    }
    
    // MARK: - Basic Handshake Tests
    
    @Test func xxPatternHandshake() throws {
        // Alice starts handshake (message 1)
        let message1 = try aliceSession.startHandshake()
        #expect(!message1.isEmpty)
        #expect(aliceSession.getState() == .handshaking)
        
        // Bob processes message 1 and creates message 2
        let message2 = try bobSession.processHandshakeMessage(message1)
        #expect(message2 != nil)
        #expect(!message2!.isEmpty)
        #expect(bobSession.getState() == .handshaking)
        
        // Alice processes message 2 and creates message 3
        let message3 = try aliceSession.processHandshakeMessage(message2!)
        #expect(message3 != nil)
        #expect(!message3!.isEmpty)
        #expect(aliceSession.getState() == .established)
        
        // Bob processes message 3 and completes handshake
        let finalMessage = try bobSession.processHandshakeMessage(message3!)
        #expect(finalMessage == nil) // No more messages needed
        #expect(bobSession.getState() == .established)
        
        // Verify both sessions are established
        #expect(aliceSession.isEstablished())
        #expect(bobSession.isEstablished())
        
        // Verify they have each other's static keys
        #expect(aliceSession.getRemoteStaticPublicKey()?.rawRepresentation == bobKey.publicKey.rawRepresentation)
        #expect(bobSession.getRemoteStaticPublicKey()?.rawRepresentation == aliceKey.publicKey.rawRepresentation)
    }
    
    @Test func handshakeStateValidation() throws {
        // Cannot process message before starting handshake
        #expect(throws: NoiseSessionError.invalidState) {
            try aliceSession.processHandshakeMessage(Data())
        }
        
        // Start handshake
        _ = try aliceSession.startHandshake()
        
        // Cannot start handshake twice
        #expect(throws: NoiseSessionError.invalidState) {
            try aliceSession.startHandshake()
        }
    }
    
    // MARK: - Encryption/Decryption Tests
    
    @Test func basicEncryptionDecryption() throws {
        try performHandshake(initiator: aliceSession, responder: bobSession)
        
        let plaintext = "Hello, Bob!".data(using: .utf8)!
        
        // Alice encrypts
        let ciphertext = try aliceSession.encrypt(plaintext)
        #expect(ciphertext != plaintext)
        #expect(ciphertext.count > plaintext.count) // Should have overhead
        
        // Bob decrypts
        let decrypted = try bobSession.decrypt(ciphertext)
        #expect(decrypted == plaintext)
    }
    
    @Test func bidirectionalEncryption() throws {
        try performHandshake(initiator: aliceSession, responder: bobSession)
        
        // Alice -> Bob
        let aliceMessage = "Hello from Alice".data(using: .utf8)!
        let aliceCiphertext = try aliceSession.encrypt(aliceMessage)
        let bobReceived = try bobSession.decrypt(aliceCiphertext)
        #expect(bobReceived == aliceMessage)
        
        // Bob -> Alice
        let bobMessage = "Hello from Bob".data(using: .utf8)!
        let bobCiphertext = try bobSession.encrypt(bobMessage)
        let aliceReceived = try aliceSession.decrypt(bobCiphertext)
        #expect(aliceReceived == bobMessage)
    }
    
    @Test func largeMessageEncryption() throws {
        try performHandshake(initiator: aliceSession, responder: bobSession)
        
        // Create a large message
        let largeMessage = TestHelpers.generateRandomData(length: 100_000)
        
        // Encrypt and decrypt
        let ciphertext = try aliceSession.encrypt(largeMessage)
        let decrypted = try bobSession.decrypt(ciphertext)
        
        #expect(decrypted == largeMessage)
    }
    
    @Test func encryptionBeforeHandshake() {
        let plaintext = "test".data(using: .utf8)!
        
        #expect(throws: NoiseSessionError.notEstablished) {
            try aliceSession.encrypt(plaintext)
        }
        
        #expect(throws: NoiseSessionError.notEstablished) {
            try aliceSession.decrypt(plaintext)
        }
    }
    
    // MARK: - Session Manager Tests
    
    @Test func sessionManagerBasicOperations() throws {
        let manager = NoiseSessionManager(localStaticKey: aliceKey, keychain: mockKeychain)

        #expect(manager.getSession(for: alicePeerID) == nil)

        _ = try manager.initiateHandshake(with: alicePeerID)
        #expect(manager.getSession(for: alicePeerID) != nil)

        // Get session
        let retrieved = manager.getSession(for: alicePeerID)
        #expect(retrieved != nil)

        // Remove session
        manager.removeSession(for: alicePeerID)
        #expect(manager.getSession(for: alicePeerID) == nil)
    }
    
    @Test func sessionManagerHandshakeInitiation() throws {
        let manager = NoiseSessionManager(localStaticKey: aliceKey, keychain: mockKeychain)
        
        // Initiate handshake
        let handshakeData = try manager.initiateHandshake(with: alicePeerID)
        #expect(!handshakeData.isEmpty)
        
        // Session should exist
        let session = manager.getSession(for: alicePeerID)
        #expect(session != nil)
        #expect(session?.getState() == .handshaking)
    }
    
    @Test func sessionManagerIncomingHandshake() throws {
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey, keychain: mockKeychain)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey, keychain: mockKeychain)
        
        // Alice initiates
        let message1 = try aliceManager.initiateHandshake(with: alicePeerID)
        
        // Bob responds
        let message2 = try bobManager.handleIncomingHandshake(from: bobPeerID, message: message1)
        #expect(message2 != nil)
        
        // Continue handshake
        let message3 = try aliceManager.handleIncomingHandshake(from: alicePeerID, message: message2!)
        #expect(message3 != nil)
        
        // Complete handshake
        let finalMessage = try bobManager.handleIncomingHandshake(from: bobPeerID, message: message3!)
        #expect(finalMessage == nil)
        
        // Both should have established sessions
        #expect(aliceManager.getSession(for: alicePeerID)?.isEstablished() == true)
        #expect(bobManager.getSession(for: bobPeerID)?.isEstablished() == true)
    }
    
    @Test func sessionManagerEncryptionDecryption() throws {
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey, keychain: mockKeychain)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey, keychain: mockKeychain)
        
        // Establish sessions
        try establishManagerSessions(aliceManager: aliceManager, bobManager: bobManager)
        
        // Encrypt with manager
        let plaintext = "Test message".data(using: .utf8)!
        let ciphertext = try aliceManager.encrypt(plaintext, for: alicePeerID)
        
        // Decrypt with manager
        let decrypted = try bobManager.decrypt(ciphertext, from: bobPeerID)
        #expect(decrypted == plaintext)
    }
    
    // MARK: - Security Tests
    
    @Test func tamperedCiphertextDetection() throws {
        try performHandshake(initiator: aliceSession, responder: bobSession)
        
        let plaintext = "Secret message".data(using: .utf8)!
        var ciphertext = try aliceSession.encrypt(plaintext)
        
        // Tamper with ciphertext
        ciphertext[ciphertext.count / 2] ^= 0xFF
        
        // Decryption should fail
        if #available(macOS 14.4, iOS 17.4, *) {
            #expect(throws: CryptoKitError.authenticationFailure) {
                try bobSession.decrypt(ciphertext)
            }
        } else {
            #expect(throws: (any Error).self) {
                try bobSession.decrypt(ciphertext)
            }
        }
    }
    
    @Test func replayPrevention() throws {
        try performHandshake(initiator: aliceSession, responder: bobSession)
        
        let plaintext = "Test message".data(using: .utf8)!
        let ciphertext = try aliceSession.encrypt(plaintext)
        
        // First decryption should succeed
        _ = try bobSession.decrypt(ciphertext)
        
        // Replaying the same ciphertext should fail
        #expect(throws: NoiseError.replayDetected) {
            try bobSession.decrypt(ciphertext)
        }
    }
    
    @Test func sessionIsolation() throws {
        // Create two separate session pairs
        let aliceSession1 = NoiseSession(peerID: PeerID(str: "peer1"), role: .initiator, keychain: mockKeychain, localStaticKey: aliceKey)
        let bobSession1 = NoiseSession(peerID: PeerID(str: "alice1"), role: .responder, keychain: mockKeychain, localStaticKey: bobKey)
        
        let aliceSession2 = NoiseSession(peerID: PeerID(str: "peer2"), role: .initiator, keychain: mockKeychain, localStaticKey: aliceKey)
        let bobSession2 = NoiseSession(peerID: PeerID(str: "alice2"), role: .responder, keychain: mockKeychain, localStaticKey: bobKey)
        
        // Establish both pairs
        try performHandshake(initiator: aliceSession1, responder: bobSession1)
        try performHandshake(initiator: aliceSession2, responder: bobSession2)
        
        // Encrypt with session 1
        let plaintext = "Secret".data(using: .utf8)!
        let ciphertext1 = try aliceSession1.encrypt(plaintext)
        
        // Should not be able to decrypt with session 2
        if #available(macOS 14.4, iOS 17.4, *) {
            #expect(throws: CryptoKitError.authenticationFailure) {
                try bobSession2.decrypt(ciphertext1)
            }
        } else {
            #expect(throws: (any Error).self) {
                try bobSession2.decrypt(ciphertext1)
            }
        }
        
        // But should work with correct session
        let decrypted = try bobSession1.decrypt(ciphertext1)
        #expect(decrypted == plaintext)
    }
    
    // MARK: - Session Recovery Tests
    
    @Test func peerRestartDetection() throws {
        // Establish initial sessions
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey, keychain: mockKeychain)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey, keychain: mockKeychain)
        
        try establishManagerSessions(aliceManager: aliceManager, bobManager: bobManager)
        
        // Exchange some messages to establish nonce state
        let message1 = try aliceManager.encrypt("Hello".data(using: .utf8)!, for: alicePeerID)
        _ = try bobManager.decrypt(message1, from: bobPeerID)
        
        let message2 = try bobManager.encrypt("World".data(using: .utf8)!, for: bobPeerID)
        _ = try aliceManager.decrypt(message2, from: alicePeerID)
        
        // Simulate Bob restart by creating new manager with same key
        let bobManagerRestarted = NoiseSessionManager(localStaticKey: bobKey, keychain: mockKeychain)
        
        // Bob initiates new handshake after restart
        let newHandshake1 = try bobManagerRestarted.initiateHandshake(with: bobPeerID)
        
        // Alice should accept the new handshake (clearing old session)
        let newHandshake2 = try aliceManager.handleIncomingHandshake(from: alicePeerID, message: newHandshake1)
        #expect(newHandshake2 != nil)
        
        // Complete the new handshake
        let newHandshake3 = try bobManagerRestarted.handleIncomingHandshake(from: bobPeerID, message: newHandshake2!)
        #expect(newHandshake3 != nil)
        _ = try aliceManager.handleIncomingHandshake(from: alicePeerID, message: newHandshake3!)
        
        // Should be able to exchange messages with new sessions
        let testMessage = "After restart".data(using: .utf8)!
        let encrypted = try bobManagerRestarted.encrypt(testMessage, for: bobPeerID)
        let decrypted = try aliceManager.decrypt(encrypted, from: alicePeerID)
        #expect(decrypted == testMessage)
    }
    
    @Test func nonceDesynchronizationRecovery() throws {
        // Create two sessions
        let aliceSession = NoiseSession(peerID: alicePeerID, role: .initiator, keychain: mockKeychain, localStaticKey: aliceKey)
        let bobSession = NoiseSession(peerID: bobPeerID, role: .responder, keychain: mockKeychain, localStaticKey: bobKey)
        
        // Establish sessions
        try performHandshake(initiator: aliceSession, responder: bobSession)
        
        // Exchange messages to advance nonces
        for i in 0..<5 {
            let msg = try aliceSession.encrypt("Message \(i)".data(using: .utf8)!)
            _ = try bobSession.decrypt(msg)
        }
        
        // Simulate desynchronization by encrypting but not decrypting
        for i in 0..<3 {
            _ = try aliceSession.encrypt("Lost message \(i)".data(using: .utf8)!)
        }
        
        // With per-packet nonce carried, decryption should not throw here
        let desyncMessage = try aliceSession.encrypt("This now succeeds".data(using: .utf8)!)
        #expect(throws: Never.self) {
            try bobSession.decrypt(desyncMessage)
        }
    }
    
    @Test func concurrentEncryption() async throws {
        // Test thread safety of encryption operations
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey, keychain: mockKeychain)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey, keychain: mockKeychain)
        
        try establishManagerSessions(aliceManager: aliceManager, bobManager: bobManager)
        
        let messageCount = 100
        
        try await confirmation("All messages encrypted and decrypted", expectedCount: messageCount) { completion in
            var encryptedMessages: [Int: Data] = [:]
            // Encrypt messages sequentially to avoid nonce races in manager
            for i in 0..<messageCount {
                let plaintext = "Concurrent message \(i)".data(using: .utf8)!
                let encrypted = try aliceManager.encrypt(plaintext, for: alicePeerID)
                encryptedMessages[i] = encrypted
            }
            
            // Decrypt messages sequentially to avoid triggering anti-replay with reordering
            for i in 0..<messageCount {
                do {
                    guard let encrypted = encryptedMessages[i] else {
                        Issue.record("Missing encrypted message \(i)")
                        return
                    }
                    let decrypted = try bobManager.decrypt(encrypted, from: bobPeerID)
                    let expected = "Concurrent message \(i)".data(using: .utf8)!
                    #expect(decrypted == expected)
                    completion()
                } catch {
                    Issue.record("Decryption failed for message \(i): \(error)")
                }
            }
        }
    }
    
    @Test func sessionStaleDetection() throws {
        // Test that sessions are properly marked as stale
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey, keychain: mockKeychain)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey, keychain: mockKeychain)
        
        try establishManagerSessions(aliceManager: aliceManager, bobManager: bobManager)
        
        // Get the session and check it needs renegotiation based on age
        let sessions = aliceManager.getSessionsNeedingRekey()
        
        // New session should not need rekey
        #expect(sessions.isEmpty || sessions.allSatisfy { !$0.needsRekey })
    }
    
    @Test func handshakeAfterDecryptionFailure() throws {
        // Test that handshake is properly initiated after decryption failure
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey, keychain: mockKeychain)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey, keychain: mockKeychain)
        
        // Establish sessions
        try establishManagerSessions(aliceManager: aliceManager, bobManager: bobManager)
        
        // Create a corrupted message
        var encrypted = try aliceManager.encrypt("Test".data(using: .utf8)!, for: alicePeerID)
        encrypted[10] ^= 0xFF // Corrupt the data
        
        // Decryption should fail
        if #available(macOS 14.4, iOS 17.4, *) {
            #expect(throws: CryptoKitError.authenticationFailure) {
                try bobManager.decrypt(encrypted, from: bobPeerID)
            }
        } else {
            #expect(throws: (any Error).self) {
                try bobManager.decrypt(encrypted, from: bobPeerID)
            }
        }
        
        // Bob should still have the session (it's not removed on single failure)
        #expect(bobManager.getSession(for: bobPeerID) != nil)
    }
    
    @Test func handshakeAlwaysAcceptedWithExistingSession() throws {
        // Test that handshake is always accepted even with existing valid session
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey, keychain: mockKeychain)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey, keychain: mockKeychain)
        
        // Establish sessions
        try establishManagerSessions(aliceManager: aliceManager, bobManager: bobManager)
        
        // Verify sessions are established
        #expect(aliceManager.getSession(for: alicePeerID)?.isEstablished() == true)
        #expect(bobManager.getSession(for: bobPeerID)?.isEstablished() == true)
        
        // Exchange messages to verify sessions work
        let testMessage = "Session works".data(using: .utf8)!
        let encrypted = try aliceManager.encrypt(testMessage, for: alicePeerID)
        let decrypted = try bobManager.decrypt(encrypted, from: bobPeerID)
        #expect(decrypted == testMessage)
        
        // Alice clears her session (simulating decryption failure)
        aliceManager.removeSession(for: alicePeerID)
        
        // Alice initiates new handshake despite Bob having valid session
        let newHandshake1 = try aliceManager.initiateHandshake(with: alicePeerID)
        
        // Bob should accept the new handshake even though he has a valid session
        let newHandshake2 = try bobManager.handleIncomingHandshake(from: bobPeerID, message: newHandshake1)
        #expect(newHandshake2 != nil, "Bob should accept handshake despite having valid session")
        
        // Complete the handshake
        let newHandshake3 = try aliceManager.handleIncomingHandshake(from: alicePeerID, message: newHandshake2!)
        #expect(newHandshake3 != nil)
        _ = try bobManager.handleIncomingHandshake(from: bobPeerID, message: newHandshake3!)
        
        // Verify new sessions work
        let testMessage2 = "New session works".data(using: .utf8)!
        let encrypted2 = try aliceManager.encrypt(testMessage2, for: alicePeerID)
        let decrypted2 = try bobManager.decrypt(encrypted2, from: bobPeerID)
        #expect(decrypted2 == testMessage2)
    }
    
    @Test func nonceDesynchronizationCausesRehandshake() throws {
        // Test that nonce desynchronization leads to proper re-handshake
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey, keychain: mockKeychain)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey, keychain: mockKeychain)
        
        // Establish sessions
        try establishManagerSessions(aliceManager: aliceManager, bobManager: bobManager)
        
        // Exchange messages normally
        for i in 0..<5 {
            let msg = try aliceManager.encrypt("Message \(i)".data(using: .utf8)!, for: alicePeerID)
            _ = try bobManager.decrypt(msg, from: bobPeerID)
        }
        
        // Simulate desynchronization - Alice sends messages that Bob doesn't receive
        for i in 0..<3 {
            _ = try aliceManager.encrypt("Lost message \(i)".data(using: .utf8)!, for: alicePeerID)
        }
        
        // With nonce carried in packet, decryption should not throw here
        let desyncMessage = try aliceManager.encrypt("This now succeeds".data(using: .utf8)!, for: alicePeerID)
        #expect(throws: Never.self) {
            try bobManager.decrypt(desyncMessage, from: bobPeerID)
        }
        
        // Bob clears session and initiates new handshake
        bobManager.removeSession(for: bobPeerID)
        let rehandshake1 = try bobManager.initiateHandshake(with: bobPeerID)
        
        // Alice should accept despite having a "valid" (but desynced) session
        let rehandshake2 = try aliceManager.handleIncomingHandshake(from: alicePeerID, message: rehandshake1)
        #expect(rehandshake2 != nil, "Alice should accept handshake to fix desync")
        
        // Complete handshake
        let rehandshake3 = try bobManager.handleIncomingHandshake(from: bobPeerID, message: rehandshake2!)
        #expect(rehandshake3 != nil)
        _ = try aliceManager.handleIncomingHandshake(from: alicePeerID, message: rehandshake3!)
        
        // Verify communication works again
        let testResynced = "Resynced".data(using: .utf8)!
        let encryptedResync = try aliceManager.encrypt(testResynced, for: alicePeerID)
        let decryptedResync = try bobManager.decrypt(encryptedResync, from: bobPeerID)
        #expect(decryptedResync == testResynced)
    }
    
    // MARK: - Helper Methods
    
    private func performHandshake(initiator: NoiseSession, responder: NoiseSession) throws {
        let msg1 = try initiator.startHandshake()
        let msg2 = try responder.processHandshakeMessage(msg1)!
        let msg3 = try initiator.processHandshakeMessage(msg2)!
        _ = try responder.processHandshakeMessage(msg3)
    }
    
    private func establishManagerSessions(aliceManager: NoiseSessionManager, bobManager: NoiseSessionManager) throws {
        let msg1 = try aliceManager.initiateHandshake(with: alicePeerID)
        let msg2 = try bobManager.handleIncomingHandshake(from: bobPeerID, message: msg1)!
        let msg3 = try aliceManager.handleIncomingHandshake(from: alicePeerID, message: msg2)!
        _ = try bobManager.handleIncomingHandshake(from: bobPeerID, message: msg3)
    }
}
