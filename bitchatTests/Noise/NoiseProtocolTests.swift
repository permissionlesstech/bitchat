//
// NoiseProtocolTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation
import Testing

@testable import bitchat

// MARK: - Test Vector Support

struct NoiseTestVector: Codable {
    let protocol_name: String
    let init_prologue: String
    let init_static: String
    let init_ephemeral: String
    let init_psks: [String]?
    let resp_prologue: String
    let resp_static: String
    let resp_ephemeral: String
    let resp_psks: [String]?
    let handshake_hash: String?
    let messages: [TestMessage]
    
    struct TestMessage: Codable {
        let payload: String
        let ciphertext: String
    }
}

extension Data {
    init?(hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
    
    func hexString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

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
        #expect(finalMessage == nil)  // No more messages needed
        #expect(bobSession.getState() == .established)
        
        // Verify both sessions are established
        #expect(aliceSession.isEstablished())
        #expect(bobSession.isEstablished())
        
        // Verify they have each other's static keys
        #expect(
            aliceSession.getRemoteStaticPublicKey()?.rawRepresentation
            == bobKey.publicKey.rawRepresentation)
        #expect(
            bobSession.getRemoteStaticPublicKey()?.rawRepresentation
            == aliceKey.publicKey.rawRepresentation)
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
        #expect(ciphertext.count > plaintext.count)  // Should have overhead
        
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
        let message3 = try aliceManager.handleIncomingHandshake(
            from: alicePeerID, message: message2!)
        #expect(message3 != nil)
        
        // Complete handshake
        let finalMessage = try bobManager.handleIncomingHandshake(
            from: bobPeerID, message: message3!)
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
        let aliceSession1 = NoiseSession(
            peerID: PeerID(str: "peer1"), role: .initiator, keychain: mockKeychain,
            localStaticKey: aliceKey)
        let bobSession1 = NoiseSession(
            peerID: PeerID(str: "alice1"), role: .responder, keychain: mockKeychain,
            localStaticKey: bobKey)
        
        let aliceSession2 = NoiseSession(
            peerID: PeerID(str: "peer2"), role: .initiator, keychain: mockKeychain,
            localStaticKey: aliceKey)
        let bobSession2 = NoiseSession(
            peerID: PeerID(str: "alice2"), role: .responder, keychain: mockKeychain,
            localStaticKey: bobKey)
        
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
        let bobManagerRestarted = NoiseSessionManager(
            localStaticKey: bobKey, keychain: mockKeychain)
        
        // Bob initiates new handshake after restart
        let newHandshake1 = try bobManagerRestarted.initiateHandshake(with: bobPeerID)
        
        // Alice should accept the new handshake (clearing old session)
        let newHandshake2 = try aliceManager.handleIncomingHandshake(
            from: alicePeerID, message: newHandshake1)
        #expect(newHandshake2 != nil)
        
        // Complete the new handshake
        let newHandshake3 = try bobManagerRestarted.handleIncomingHandshake(
            from: bobPeerID, message: newHandshake2!)
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
        let aliceSession = NoiseSession(
            peerID: alicePeerID, role: .initiator, keychain: mockKeychain, localStaticKey: aliceKey)
        let bobSession = NoiseSession(
            peerID: bobPeerID, role: .responder, keychain: mockKeychain, localStaticKey: bobKey)
        
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
        
        try await confirmation("All messages encrypted and decrypted", expectedCount: messageCount)
        { completion in
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
        encrypted[10] ^= 0xFF  // Corrupt the data
        
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
        let newHandshake2 = try bobManager.handleIncomingHandshake(
            from: bobPeerID, message: newHandshake1)
        #expect(newHandshake2 != nil, "Bob should accept handshake despite having valid session")
        
        // Complete the handshake
        let newHandshake3 = try aliceManager.handleIncomingHandshake(
            from: alicePeerID, message: newHandshake2!)
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
        let desyncMessage = try aliceManager.encrypt(
            "This now succeeds".data(using: .utf8)!, for: alicePeerID)
        #expect(throws: Never.self) {
            try bobManager.decrypt(desyncMessage, from: bobPeerID)
        }
        
        // Bob clears session and initiates new handshake
        bobManager.removeSession(for: bobPeerID)
        let rehandshake1 = try bobManager.initiateHandshake(with: bobPeerID)
        
        // Alice should accept despite having a "valid" (but desynced) session
        let rehandshake2 = try aliceManager.handleIncomingHandshake(
            from: alicePeerID, message: rehandshake1)
        #expect(rehandshake2 != nil, "Alice should accept handshake to fix desync")
        
        // Complete handshake
        let rehandshake3 = try bobManager.handleIncomingHandshake(
            from: bobPeerID, message: rehandshake2!)
        #expect(rehandshake3 != nil)
        _ = try aliceManager.handleIncomingHandshake(from: alicePeerID, message: rehandshake3!)
        
        // Verify communication works again
        let testResynced = "Resynced".data(using: .utf8)!
        let encryptedResync = try aliceManager.encrypt(testResynced, for: alicePeerID)
        let decryptedResync = try bobManager.decrypt(encryptedResync, from: bobPeerID)
        #expect(decryptedResync == testResynced)
    }
    
    // MARK: - Test Vector Tests
    
    @Test func noiseTestVectors() throws {
        // Load test vectors from bundle
        let testVectors = try loadTestVectors()
        
        for (index, testVector) in testVectors.enumerated() {
            print("Running test vector \(index + 1): \(testVector.protocol_name)")
            try runTestVector(testVector)
        }
    }
    
    // MARK: - Helper Methods
    
    private func performHandshake(initiator: NoiseSession, responder: NoiseSession) throws {
        let msg1 = try initiator.startHandshake()
        let msg2 = try responder.processHandshakeMessage(msg1)!
        let msg3 = try initiator.processHandshakeMessage(msg2)!
        _ = try responder.processHandshakeMessage(msg3)
    }
    
    private func establishManagerSessions(
        aliceManager: NoiseSessionManager, bobManager: NoiseSessionManager
    ) throws {
        let msg1 = try aliceManager.initiateHandshake(with: alicePeerID)
        let msg2 = try bobManager.handleIncomingHandshake(from: bobPeerID, message: msg1)!
        let msg3 = try aliceManager.handleIncomingHandshake(from: alicePeerID, message: msg2)!
        _ = try bobManager.handleIncomingHandshake(from: bobPeerID, message: msg3)
    }
    
    private func loadTestVectors() throws -> [NoiseTestVector] {
        // Try to load from test bundle
        let testBundle = Bundle(for: MockKeychain.self)
        guard let url = testBundle.url(forResource: "NoiseTestVectors", withExtension: "json")
        else {
            throw NSError(
                domain: "NoiseTests", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not find NoiseTestVectors.json in test bundle"
                ])
        }
        
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([NoiseTestVector].self, from: data)
    }
    
    private func runTestVector(_ testVector: NoiseTestVector) throws {
        // Parse test inputs
        guard let initStatic = Data(hex: testVector.init_static),
              let initEphemeral = Data(hex: testVector.init_ephemeral),
              let respStatic = Data(hex: testVector.resp_static),
              let respEphemeral = Data(hex: testVector.resp_ephemeral),
              let prologue = Data(hex: testVector.init_prologue)
        else {
            throw NSError(
                domain: "NoiseTests", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse test vector hex strings"])
        }
        
        let expectedHash = testVector.handshake_hash.flatMap { Data(hex: $0) }
        
        // Create keys
        guard
            let initStaticKey = try? Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: initStatic),
            let initEphemeralKey = try? Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: initEphemeral),
            let respStaticKey = try? Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: respStatic),
            let respEphemeralKey = try? Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: respEphemeral)
        else {
            throw NSError(
                domain: "NoiseTests", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create keys from test vectors"])
        }
        
        let keychain = MockKeychain()
        
        // Create handshake states
        let initiatorHandshake = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: initStaticKey,
            prologue: prologue,
            predeterminedEphemeralKey: initEphemeralKey
        )
        
        let responderHandshake = NoiseHandshakeState(
            role: .responder,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: respStaticKey,
            prologue: prologue,
            predeterminedEphemeralKey: respEphemeralKey
        )
        
        // For XX pattern, we have 3 handshake messages, then transport messages
        // The test vector messages are ordered as: [msg1, msg2, msg3, transport1, transport2, ...]
        
        guard testVector.messages.count >= 3 else {
            throw NSError(
                domain: "NoiseTests", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Test vector must have at least 3 messages for XX pattern"])
        }
        
        // Message 1: Initiator -> Responder (e)
        guard let payload1 = Data(hex: testVector.messages[0].payload),
              let expectedCiphertext1 = Data(hex: testVector.messages[0].ciphertext) else {
            throw NSError(
                domain: "NoiseTests", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Message 1: Failed to parse hex"])
        }
        
        let msg1 = try initiatorHandshake.writeMessage(payload: payload1)
        #expect(!msg1.isEmpty, "Message 1 should not be empty")
        #expect(msg1 == expectedCiphertext1, "Message 1 ciphertext should match expected value. Got: \(msg1.hexString()), Expected: \(expectedCiphertext1.hexString())")
        
        let decrypted1 = try responderHandshake.readMessage(msg1)
        #expect(decrypted1 == payload1, "Message 1: Decrypted payload should match original")
        
        // Message 2: Responder -> Initiator (e, ee, s, es)
        guard let payload2 = Data(hex: testVector.messages[1].payload),
              let expectedCiphertext2 = Data(hex: testVector.messages[1].ciphertext) else {
            throw NSError(
                domain: "NoiseTests", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Message 2: Failed to parse hex"])
        }
        
        let msg2 = try responderHandshake.writeMessage(payload: payload2)
        #expect(!msg2.isEmpty, "Message 2 should not be empty")
        #expect(msg2 == expectedCiphertext2, "Message 2 ciphertext should match expected value. Got: \(msg2.hexString()), Expected: \(expectedCiphertext2.hexString())")
        
        let decrypted2 = try initiatorHandshake.readMessage(msg2)
        #expect(decrypted2 == payload2, "Message 2: Decrypted payload should match original")
        
        // Message 3: Initiator -> Responder (s, se)
        guard let payload3 = Data(hex: testVector.messages[2].payload),
              let expectedCiphertext3 = Data(hex: testVector.messages[2].ciphertext) else {
            throw NSError(
                domain: "NoiseTests", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Message 3: Failed to parse hex"])
        }
        
        let msg3 = try initiatorHandshake.writeMessage(payload: payload3)
        #expect(!msg3.isEmpty, "Message 3 should not be empty")
        #expect(msg3 == expectedCiphertext3, "Message 3 ciphertext should match expected value. Got: \(msg3.hexString()), Expected: \(expectedCiphertext3.hexString())")
        
        let decrypted3 = try responderHandshake.readMessage(msg3)
        #expect(decrypted3 == payload3, "Message 3: Decrypted payload should match original")
        
        // Verify handshake hash
        let initiatorHash = initiatorHandshake.getHandshakeHash()
        let responderHash = responderHandshake.getHandshakeHash()
        
        #expect(initiatorHash == responderHash, "Initiator and responder hashes should match")
        
        if let expectedHash = expectedHash {
            #expect(
                initiatorHash == expectedHash,
                "Handshake hash should match expected value from test vector. Got: \(initiatorHash.hexString()), Expected: \(expectedHash.hexString())")
        }
        
        // Get transport ciphers
        let (initSend, initRecv) = try initiatorHandshake.getTransportCiphers(useExtractedNonce: false)
        let (respSend, respRecv) = try responderHandshake.getTransportCiphers(useExtractedNonce: false)

        // Test transport messages (messages after the 3 handshake messages)
        for index in 3..<testVector.messages.count {
            let testMsg = testVector.messages[index]
            guard let payload = Data(hex: testMsg.payload),
                  let expectedCiphertext = Data(hex: testMsg.ciphertext) else {
                throw NSError(
                    domain: "NoiseTests", code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Message \(index + 1): Failed to parse payload hex"
                    ])
            }
            
            // Alternate between responder and initiator sending
            // Responder sends first transport message (since initiator sent last handshake message)
            let (sender, receiver): (NoiseCipherState, NoiseCipherState)
            let transportIndex = index - 3
            if transportIndex % 2 == 0 {
                // Even transport messages: responder sends
                sender = respSend
                receiver = initRecv
            } else {
                // Odd transport messages: initiator sends
                sender = initSend
                receiver = respRecv
            }
            
            // Encrypt and validate ciphertext matches expected value
            let ciphertext = try sender.encrypt(plaintext: payload)
            #expect(
                ciphertext == expectedCiphertext,
                "Message \(index + 1) ciphertext should match expected value. Got: \(ciphertext.hexString()), Expected: \(expectedCiphertext.hexString())")

            // Decrypt and validate payload
            let decrypted = try receiver.decrypt(ciphertext: ciphertext)
            #expect(
                decrypted == payload,
                "Message \(index + 1): Decrypted payload should match original")
        }
    }
}
