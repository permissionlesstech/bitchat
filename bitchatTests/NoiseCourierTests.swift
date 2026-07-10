//
// NoiseCourierTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

/// One-way Noise X envelopes: encryption to a known static key without an
/// interactive handshake, used by the courier store-and-forward path.
struct NoiseCourierTests {

    @Test func sealAndOpenRoundTrip() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())

        let payload = Data("meet at the north gate".utf8)
        let sealed = try alice.sealCourierPayload(payload, recipientStaticKey: bob.getStaticPublicKeyData())

        let opened = try bob.openCourierPayload(sealed)
        #expect(opened.payload == payload)
        // The X pattern authenticates the sender: Bob learns Alice's real static key.
        #expect(opened.senderStaticKey == alice.getStaticPublicKeyData())
    }

    @Test func wrongRecipientCannotOpen() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let carol = NoiseEncryptionService(keychain: MockKeychain())

        let sealed = try alice.sealCourierPayload(Data("secret".utf8), recipientStaticKey: bob.getStaticPublicKeyData())

        #expect(throws: (any Error).self) {
            _ = try carol.openCourierPayload(sealed)
        }
    }

    @Test func tamperedEnvelopeFailsToOpen() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())

        var sealed = try alice.sealCourierPayload(Data("secret".utf8), recipientStaticKey: bob.getStaticPublicKeyData())
        sealed[sealed.count - 1] ^= 0x01

        #expect(throws: (any Error).self) {
            _ = try bob.openCourierPayload(sealed)
        }
    }

    @Test func senderIdentityCannotBeForged() throws {
        // The encrypted static key inside the envelope is bound by the ss DH;
        // splicing one envelope's ephemeral prefix onto another must fail.
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let mallory = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())

        let bobKey = bob.getStaticPublicKeyData()
        let fromAlice = try alice.sealCourierPayload(Data("hi".utf8), recipientStaticKey: bobKey)
        let fromMallory = try mallory.sealCourierPayload(Data("hi".utf8), recipientStaticKey: bobKey)

        // e (32 bytes) from Mallory's envelope + rest from Alice's.
        let spliced = fromMallory.prefix(32) + fromAlice.dropFirst(32)
        #expect(throws: (any Error).self) {
            _ = try bob.openCourierPayload(Data(spliced))
        }
    }

    @Test func sealRejectsInvalidRecipientKey() {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        #expect(throws: (any Error).self) {
            _ = try alice.sealCourierPayload(Data("x".utf8), recipientStaticKey: Data(repeating: 0, count: 32))
        }
        #expect(throws: (any Error).self) {
            _ = try alice.sealCourierPayload(Data("x".utf8), recipientStaticKey: Data(repeating: 1, count: 8))
        }
    }

    @Test func emptyAndLargePayloadsRoundTrip() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let bobKey = bob.getStaticPublicKeyData()

        let empty = try alice.sealCourierPayload(Data(), recipientStaticKey: bobKey)
        #expect(try bob.openCourierPayload(empty).payload.isEmpty)

        let large = Data((0..<8192).map { UInt8($0 % 251) })
        let sealed = try alice.sealCourierPayload(large, recipientStaticKey: bobKey)
        #expect(try bob.openCourierPayload(sealed).payload == large)
    }

    @Test func envelopesAreNotLinkableAcrossSends() throws {
        // Fresh ephemeral per seal: same payload to the same recipient must
        // produce entirely different ciphertexts.
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let payload = Data("same message".utf8)

        let a = try alice.sealCourierPayload(payload, recipientStaticKey: bob.getStaticPublicKeyData())
        let b = try alice.sealCourierPayload(payload, recipientStaticKey: bob.getStaticPublicKeyData())
        #expect(a != b)
        #expect(a.prefix(32) != b.prefix(32))
    }
}
