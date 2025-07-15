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
    
    // MARK: - Cipher State Tests
    
    func testCipherStateEncryptDecrypt() throws {
        let key = SymmetricKey(size: .bits256)
        let cipher = NoiseCipherState(key: key)
        
        let plaintext = "Hello, Noise Protocol!".data(using: .utf8)!
        let associatedData = "metadata".data(using: .utf8)!
        
        // Encrypt
        let ciphertext = try cipher.encrypt(plaintext: plaintext, associatedData: associatedData)
        
        // Create new cipher with same key for decryption
        let decryptCipher = NoiseCipherState(key: key)
        let decrypted = try decryptCipher.decrypt(ciphertext: ciphertext, associatedData: associatedData)
        
        XCTAssertEqual(plaintext, decrypted)
    }
    
    func testCipherStateNonceIncrement() throws {
        let key = SymmetricKey(size: .bits256)
        let cipher = NoiseCipherState(key: key)
        
        let plaintext = "Test".data(using: .utf8)!
        
        // Encrypt multiple messages
        let ct1 = try cipher.encrypt(plaintext: plaintext)
        let ct2 = try cipher.encrypt(plaintext: plaintext)
        let ct3 = try cipher.encrypt(plaintext: plaintext)
        
        // All ciphertexts should be different due to nonce increment
        XCTAssertNotEqual(ct1, ct2)
        XCTAssertNotEqual(ct2, ct3)
        XCTAssertNotEqual(ct1, ct3)
    }
    
    // MARK: - Symmetric State Tests
    
    func testSymmetricStateInitialization() {
        let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"
        let state = NoiseSymmetricState(protocolName: protocolName)
        
        // Hash should be initialized with protocol name
        let hash = state.getHandshakeHash()
        XCTAssertEqual(hash.count, 32) // SHA256 output
    }
    
    func testSymmetricStateMixKey() throws {
        let state = NoiseSymmetricState(protocolName: "Noise_XX_25519_ChaChaPoly_SHA256")
        
        let keyMaterial = Data(repeating: 0x42, count: 32)
        state.mixKey(keyMaterial)
        
        // After mixKey, cipher should be initialized
        let plaintext = "Test".data(using: .utf8)!
        let encrypted = try state.encryptAndHash(plaintext)
        
        XCTAssertNotEqual(plaintext, encrypted)
        XCTAssertEqual(encrypted.count, plaintext.count + 16) // ChaCha20Poly1305 adds 16-byte tag
    }
    
    // MARK: - Handshake State Tests
    
    func testNoiseXXHandshakeComplete() throws {
        // Create initiator and responder
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()
        
        var initiator = NoiseHandshakeState(role: .initiator, pattern: .XX, localStaticKey: initiatorStatic)
        var responder = NoiseHandshakeState(role: .responder, pattern: .XX, localStaticKey: responderStatic)
        
        // Message 1: initiator -> responder (e)
        let msg1 = try initiator.writeMessage()
        _ = try responder.readMessage(msg1)
        
        // Message 2: responder -> initiator (e, ee, s, es)
        let msg2 = try responder.writeMessage()
        _ = try initiator.readMessage(msg2)
        
        // Message 3: initiator -> responder (s, se)
        let msg3 = try initiator.writeMessage()
        _ = try responder.readMessage(msg3)
        
        // Both should have completed handshake
        XCTAssertTrue(initiator.isHandshakeComplete())
        XCTAssertTrue(responder.isHandshakeComplete())
        
        // Get transport ciphers
        let (initSend, initRecv) = try initiator.getTransportCiphers()
        let (respSend, respRecv) = try responder.getTransportCiphers()
        
        // Test transport encryption
        let testMessage = "Secret message".data(using: .utf8)!
        let encrypted = try initSend.encrypt(plaintext: testMessage)
        let decrypted = try respRecv.decrypt(ciphertext: encrypted)
        
        XCTAssertEqual(testMessage, decrypted)
        
        // Test reverse direction
        let encrypted2 = try respSend.encrypt(plaintext: testMessage)
        let decrypted2 = try initRecv.decrypt(ciphertext: encrypted2)
        
        XCTAssertEqual(testMessage, decrypted2)
    }
    
    func testNoiseXXWithPayloads() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()
        
        var initiator = NoiseHandshakeState(role: .initiator, pattern: .XX, localStaticKey: initiatorStatic)
        var responder = NoiseHandshakeState(role: .responder, pattern: .XX, localStaticKey: responderStatic)
        
        // Message 1 with payload
        let payload1 = "Hello from initiator".data(using: .utf8)!
        let msg1 = try initiator.writeMessage(payload: payload1)
        let received1 = try responder.readMessage(msg1)
        XCTAssertEqual(payload1, received1)
        
        // Message 2 with payload
        let payload2 = "Hello from responder".data(using: .utf8)!
        let msg2 = try responder.writeMessage(payload: payload2)
        let received2 = try initiator.readMessage(msg2)
        XCTAssertEqual(payload2, received2)
        
        // Message 3 with payload
        let payload3 = "Final message".data(using: .utf8)!
        let msg3 = try initiator.writeMessage(payload: payload3)
        let received3 = try responder.readMessage(msg3)
        XCTAssertEqual(payload3, received3)
    }
    
    // MARK: - Session Tests
    
    func testNoiseSessionLifecycle() throws {
        let aliceKey = Curve25519.KeyAgreement.PrivateKey()
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        
        let aliceSession = NoiseSession(peerID: "bob", role: .initiator, localStaticKey: aliceKey)
        let bobSession = NoiseSession(peerID: "alice", role: .responder, localStaticKey: bobKey)
        
        // Start handshake - only initiator calls startHandshake
        let msg1 = try aliceSession.startHandshake()
        XCTAssertFalse(msg1.isEmpty, "Initiator should send first message")
        
        // Process messages - responder will auto-initialize on first message
        let msg2 = try bobSession.processHandshakeMessage(msg1)!
        XCTAssertFalse(msg2.isEmpty, "Responder should send second message")
        
        let msg3 = try aliceSession.processHandshakeMessage(msg2)!
        XCTAssertFalse(msg3.isEmpty, "Initiator should send third message")
        
        let finalMsg = try bobSession.processHandshakeMessage(msg3)
        XCTAssertNil(finalMsg, "No more messages after handshake complete")
        
        // Both sessions should be established
        XCTAssertTrue(aliceSession.isEstablished(), "Alice session should be established")
        XCTAssertTrue(bobSession.isEstablished(), "Bob session should be established")
        
        // Test encryption
        let plaintext = "Test message".data(using: .utf8)!
        let encrypted = try aliceSession.encrypt(plaintext)
        let decrypted = try bobSession.decrypt(encrypted)
        
        XCTAssertEqual(plaintext, decrypted)
    }
    
    // MARK: - Integration Tests
    
    func testNoiseEncryptionServiceIntegration() throws {
        // Clean up any existing keys
        _ = KeychainManager.shared.deleteIdentityKey(forKey: "noiseStaticKey")
        
        let service1 = NoiseEncryptionService()
        let service2 = NoiseEncryptionService()
        
        let peer1ID = "peer1"
        let peer2ID = "peer2"
        
        // Initiate handshake from peer1 to peer2
        let handshake1 = try service1.initiateHandshake(with: peer2ID)
        
        // Process on peer2 and get response
        let handshake2 = try service2.processHandshakeMessage(from: peer1ID, message: handshake1)!
        
        // Process response on peer1
        let handshake3 = try service1.processHandshakeMessage(from: peer2ID, message: handshake2)!
        
        // Final message on peer2
        let final = try service2.processHandshakeMessage(from: peer1ID, message: handshake3)
        XCTAssertNil(final)
        
        // Both should have established sessions
        XCTAssertTrue(service1.hasEstablishedSession(with: peer2ID))
        XCTAssertTrue(service2.hasEstablishedSession(with: peer1ID))
        
        // Test message encryption
        let message = "Secret message".data(using: .utf8)!
        let encrypted = try service1.encrypt(message, for: peer2ID)
        let decrypted = try service2.decrypt(encrypted, from: peer1ID)
        
        XCTAssertEqual(message, decrypted)
    }
    
    func testBidirectionalNoiseSession() throws {
        // This test verifies that messages can be sent in both directions after handshake
        let aliceKey = Curve25519.KeyAgreement.PrivateKey()
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        
        // Create session managers
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey)
        
        // Alice initiates handshake (msg1: -> e)
        let msg1 = try aliceManager.initiateHandshake(with: "bob")
        XCTAssertFalse(msg1.isEmpty)
        
        // Bob processes and responds (msg2: <- e, ee, s, es)
        let msg2 = try bobManager.handleIncomingHandshake(from: "alice", message: msg1)
        XCTAssertNotNil(msg2)
        XCTAssertFalse(msg2!.isEmpty)
        
        // Alice processes and sends final message (msg3: -> s, se)
        let msg3 = try aliceManager.handleIncomingHandshake(from: "bob", message: msg2!)
        XCTAssertNotNil(msg3)
        XCTAssertFalse(msg3!.isEmpty)
        
        // Bob processes final message
        let msg4 = try bobManager.handleIncomingHandshake(from: "alice", message: msg3!)
        XCTAssertNil(msg4) // Now handshake is complete
        
        // Verify both sessions are established
        XCTAssertTrue(aliceManager.getSession(for: "bob")?.isEstablished() ?? false)
        XCTAssertTrue(bobManager.getSession(for: "alice")?.isEstablished() ?? false)
        
        // Test Alice -> Bob
        let aliceMessage = "Hello Bob!".data(using: .utf8)!
        let encrypted1 = try aliceManager.encrypt(aliceMessage, for: "bob")
        let decrypted1 = try bobManager.decrypt(encrypted1, from: "alice")
        XCTAssertEqual(decrypted1, aliceMessage)
        
        // Test Bob -> Alice
        let bobMessage = "Hello Alice!".data(using: .utf8)!
        let encrypted2 = try bobManager.encrypt(bobMessage, for: "alice")
        let decrypted2 = try aliceManager.decrypt(encrypted2, from: "bob")
        XCTAssertEqual(decrypted2, bobMessage)
        
        // Test multiple messages in both directions
        for i in 1...5 {
            // Alice -> Bob
            let msg = "Message \(i) from Alice".data(using: .utf8)!
            let enc = try aliceManager.encrypt(msg, for: "bob")
            let dec = try bobManager.decrypt(enc, from: "alice")
            XCTAssertEqual(dec, msg)
            
            // Bob -> Alice
            let msg2 = "Message \(i) from Bob".data(using: .utf8)!
            let enc2 = try bobManager.encrypt(msg2, for: "alice")
            let dec2 = try aliceManager.decrypt(enc2, from: "bob")
            XCTAssertEqual(dec2, msg2)
        }
    }
    
    // MARK: - Channel Encryption Tests
    
    func testChannelEncryption() throws {
        let channelEnc = NoiseChannelEncryption()
        let channel = "#test-channel"
        let password = "super-secret-password"
        
        // Set channel password
        channelEnc.setChannelPassword(password, for: channel)
        
        // Encrypt message
        let message = "Hello channel!"
        let encrypted = try channelEnc.encryptChannelMessage(message, for: channel)
        
        // Decrypt message
        let decrypted = try channelEnc.decryptChannelMessage(encrypted, for: channel)
        
        XCTAssertEqual(message, decrypted)
    }
    
    func testChannelKeyDerivation() {
        let channelEnc = NoiseChannelEncryption()
        let password = "test-password"
        
        // Same password and channel should produce same key
        let key1 = channelEnc.deriveChannelKey(from: password, channel: "#channel1")
        let key2 = channelEnc.deriveChannelKey(from: password, channel: "#channel1")
        
        // Different channels should produce different keys
        let key3 = channelEnc.deriveChannelKey(from: password, channel: "#channel2")
        
        // Can't directly compare SymmetricKey, but we can test encryption
        let testData = "test".data(using: .utf8)!
        let nonce = ChaChaPoly.Nonce()
        
        let sealed1 = try! ChaChaPoly.seal(testData, using: key1, nonce: nonce)
        let sealed2 = try! ChaChaPoly.seal(testData, using: key2, nonce: nonce)
        
        XCTAssertEqual(sealed1.ciphertext, sealed2.ciphertext)
        
        // Different key should produce different ciphertext
        let sealed3 = try! ChaChaPoly.seal(testData, using: key3, nonce: nonce)
        XCTAssertNotEqual(sealed1.ciphertext, sealed3.ciphertext)
    }
    
    // MARK: - Security Tests
    
    func testHandshakeAuthentication() throws {
        let aliceKey = Curve25519.KeyAgreement.PrivateKey()
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        let eveKey = Curve25519.KeyAgreement.PrivateKey() // Attacker
        
        var alice = NoiseHandshakeState(role: .initiator, pattern: .XX, localStaticKey: aliceKey)
        var eve = NoiseHandshakeState(role: .responder, pattern: .XX, localStaticKey: eveKey)
        
        // Alice initiates handshake thinking she's talking to Bob
        let msg1 = try alice.writeMessage()
        _ = try eve.readMessage(msg1)
        
        // Eve responds with her keys
        let msg2 = try eve.writeMessage()
        _ = try alice.readMessage(msg2)
        
        // Alice completes handshake
        let msg3 = try alice.writeMessage()
        _ = try eve.readMessage(msg3)
        
        // Both complete handshake, but Alice has Eve's public key, not Bob's
        let aliceRemoteKey = alice.getRemoteStaticPublicKey()
        XCTAssertEqual(aliceRemoteKey?.rawRepresentation, eveKey.publicKey.rawRepresentation)
        XCTAssertNotEqual(aliceRemoteKey?.rawRepresentation, bobKey.publicKey.rawRepresentation)
        
        // This demonstrates that authentication requires out-of-band verification
        // or pre-shared knowledge of public keys
    }
    
    func testReplayProtection() throws {
        let key = SymmetricKey(size: .bits256)
        let cipher1 = NoiseCipherState(key: key)
        let cipher2 = NoiseCipherState(key: key)
        
        let plaintext = "Test".data(using: .utf8)!
        
        // Encrypt a message
        let ciphertext = try cipher1.encrypt(plaintext: plaintext)
        
        // Decrypt normally works
        _ = try cipher2.decrypt(ciphertext: ciphertext)
        
        // Replaying the same ciphertext should fail due to nonce mismatch
        XCTAssertThrowsError(try cipher2.decrypt(ciphertext: ciphertext))
    }
}