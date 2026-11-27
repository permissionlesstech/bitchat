//
// SecureNoiseSessionConcurrencyTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct SecureNoiseSessionConcurrencyTests {

    private func makeEstablishedPair() throws -> (initiator: NoiseSession, responder: NoiseSession) {
        let aliceKey = Curve25519.KeyAgreement.PrivateKey()
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        let keychain = MockKeychain()

        let alice = NoiseSession(
            peerID: PeerID(publicKey: bobKey.publicKey.rawRepresentation),
            role: .initiator,
            keychain: keychain,
            localStaticKey: aliceKey
        )
        let bob = NoiseSession(
            peerID: PeerID(publicKey: aliceKey.publicKey.rawRepresentation),
            role: .responder,
            keychain: keychain,
            localStaticKey: bobKey
        )

        let msg1 = try alice.startHandshake()
        let msg2 = try #require(try bob.processHandshakeMessage(msg1))
        let msg3 = try #require(try alice.processHandshakeMessage(msg2))
        _ = try bob.processHandshakeMessage(msg3)

        #expect(alice.getState() == .established)
        #expect(bob.getState() == .established)
        return (alice, bob)
    }

    @Test func concurrentEncryptDecryptAndRenegotiationCheckAreThreadSafe() throws {
        let (alice, bob) = try makeEstablishedPair()
        let iterations = 200
        let ciphertextsLock = NSLock()
        var ciphertexts: [Data] = []
        ciphertexts.reserveCapacity(iterations)
        var encryptionErrors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            do {
                let payload = Data("msg-\(index)".utf8)
                let encrypted = try alice.encrypt(payload)
                _ = alice.needsRenegotiation()
                ciphertextsLock.lock()
                ciphertexts.append(encrypted)
                ciphertextsLock.unlock()
            } catch {
                ciphertextsLock.lock()
                encryptionErrors.append(error)
                ciphertextsLock.unlock()
            }
        }

        #expect(encryptionErrors.isEmpty)
        #expect(ciphertexts.count == iterations)

        let decryptedLock = NSLock()
        var decryptedPayloads: Set<String> = []
        var decryptionErrors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: ciphertexts.count) { index in
            do {
                let plaintext = try bob.decrypt(ciphertexts[index])
                _ = bob.needsRenegotiation()
                if let text = String(data: plaintext, encoding: .utf8) {
                    decryptedLock.lock()
                    decryptedPayloads.insert(text)
                    decryptedLock.unlock()
                }
            } catch {
                decryptedLock.lock()
                decryptionErrors.append(error)
                decryptedLock.unlock()
            }
        }

        #expect(decryptionErrors.isEmpty)
        #expect(decryptedPayloads.count == iterations)
    }

    @Test func renegotiationThresholdTriggersUnderConcurrentIncrements() throws {
        let (alice, _) = try makeEstablishedPair()
        let threshold = UInt64(Double(NoiseSecurityConstants.maxMessagesPerSession) * 0.9)
        let batch = 50
        alice.setMessageCountForTesting(threshold - UInt64(batch))
        #expect(!alice.needsRenegotiation())

        let errorLock = NSLock()
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: batch) { index in
            do {
                _ = try alice.encrypt(Data("rekey-\(index)".utf8))
            } catch {
                errorLock.lock()
                errors.append(error)
                errorLock.unlock()
            }
        }

        #expect(errors.isEmpty)
        #expect(alice.needsRenegotiation())
    }
}
