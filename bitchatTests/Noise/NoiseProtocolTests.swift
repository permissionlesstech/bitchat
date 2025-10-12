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
    private var mockKeychain: MockKeychain!
    
    override func setUp() {
        super.setUp()
        aliceKey = Curve25519.KeyAgreement.PrivateKey()
        bobKey = Curve25519.KeyAgreement.PrivateKey()
        mockKeychain = MockKeychain()
    }
    
    override func tearDown() {
        aliceSession = nil
        bobSession = nil
        mockKeychain = nil
        super.tearDown()
    }
    
    // MARK: - Performance Tests
    
    func testHandshakePerformance() {
        measure {
            do {
                let alice = NoiseSession(peerID: "bob", role: .initiator, keychain: mockKeychain, localStaticKey: aliceKey)
                let bob = NoiseSession(peerID: "alice", role: .responder, keychain: mockKeychain, localStaticKey: bobKey)
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
            keychain: mockKeychain,
            localStaticKey: aliceKey
        )
        
        bobSession = NoiseSession(
            peerID: TestConstants.testPeerID1,
            role: .responder,
            keychain: mockKeychain,
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
}
