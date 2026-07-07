//
// PrekeyBundleTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import CryptoKit
import BitFoundation
@testable import bitchat

/// Wire format and signature binding for gossiped one-time prekey bundles.
struct PrekeyBundleTests {

    private func makePrekeys(_ count: Int) -> [PrekeyBundle.Prekey] {
        (0..<count).map { index in
            PrekeyBundle.Prekey(
                id: UInt32(index),
                publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            )
        }
    }

    // MARK: - Wire format

    @Test func encodeDecodeRoundTrip() throws {
        let bundle = PrekeyBundle(
            noiseStaticPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            prekeys: makePrekeys(8),
            generatedAt: 1_234_567_890_123,
            signature: Data(repeating: 0xAB, count: PrekeyBundle.signatureLength)
        )
        let encoded = try #require(bundle.encode())
        let decoded = try #require(PrekeyBundle.decode(encoded))
        #expect(decoded == bundle)
    }

    @Test func decodeSkipsUnknownTLVs() throws {
        let bundle = PrekeyBundle(
            noiseStaticPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            prekeys: makePrekeys(2),
            generatedAt: 42,
            signature: Data(repeating: 0x01, count: PrekeyBundle.signatureLength)
        )
        var encoded = try #require(bundle.encode())
        // Unknown TLV 0x7F appended by a future client.
        encoded.append(contentsOf: [0x7F, 0x00, 0x03, 0x01, 0x02, 0x03])
        let decoded = try #require(PrekeyBundle.decode(encoded))
        #expect(decoded == bundle)
    }

    @Test func encodeRejectsInvalidShapes() {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let signature = Data(repeating: 0, count: PrekeyBundle.signatureLength)
        // No prekeys.
        #expect(PrekeyBundle(noiseStaticPublicKey: key, prekeys: [], generatedAt: 1, signature: signature).encode() == nil)
        // Too many prekeys.
        #expect(PrekeyBundle(noiseStaticPublicKey: key, prekeys: makePrekeys(PrekeyBundle.maxPrekeys + 1), generatedAt: 1, signature: signature).encode() == nil)
        // Wrong owner key length.
        #expect(PrekeyBundle(noiseStaticPublicKey: Data(repeating: 1, count: 8), prekeys: makePrekeys(1), generatedAt: 1, signature: signature).encode() == nil)
        // Wrong signature length.
        #expect(PrekeyBundle(noiseStaticPublicKey: key, prekeys: makePrekeys(1), generatedAt: 1, signature: Data(repeating: 0, count: 32)).encode() == nil)
    }

    @Test func decodeRejectsDuplicatePrekeyIDs() throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let prekey = makePrekeys(1)[0]
        let bundle = PrekeyBundle(
            noiseStaticPublicKey: key,
            prekeys: [prekey, PrekeyBundle.Prekey(id: prekey.id, publicKey: key)],
            generatedAt: 1,
            signature: Data(repeating: 0, count: PrekeyBundle.signatureLength)
        )
        let encoded = try #require(bundle.encode())
        #expect(PrekeyBundle.decode(encoded) == nil)
    }

    // MARK: - Signature binding

    @Test func signVerifyRoundTrip() throws {
        let owner = NoiseEncryptionService(keychain: MockKeychain())
        let bundle = try #require(owner.currentPrekeyBundle())

        #expect(bundle.noiseStaticPublicKey == owner.getStaticPublicKeyData())
        #expect(bundle.prekeys.count == PrekeyBundle.maxPrekeys)
        #expect(owner.verifyPrekeyBundleSignature(bundle, signingPublicKey: owner.getSigningPublicKeyData()))
    }

    @Test func forgedSignatureFailsVerification() throws {
        let owner = NoiseEncryptionService(keychain: MockKeychain())
        let bundle = try #require(owner.currentPrekeyBundle())

        var forgedSignature = bundle.signature
        forgedSignature[0] ^= 0x01
        let forged = PrekeyBundle(
            noiseStaticPublicKey: bundle.noiseStaticPublicKey,
            prekeys: bundle.prekeys,
            generatedAt: bundle.generatedAt,
            signature: forgedSignature
        )
        #expect(!owner.verifyPrekeyBundleSignature(forged, signingPublicKey: owner.getSigningPublicKeyData()))
    }

    @Test func tamperedContentsFailVerification() throws {
        let owner = NoiseEncryptionService(keychain: MockKeychain())
        let bundle = try #require(owner.currentPrekeyBundle())

        // Mallory swaps in her own prekey but keeps the owner's signature.
        var prekeys = bundle.prekeys
        prekeys[0] = PrekeyBundle.Prekey(
            id: prekeys[0].id,
            publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        )
        let tampered = PrekeyBundle(
            noiseStaticPublicKey: bundle.noiseStaticPublicKey,
            prekeys: prekeys,
            generatedAt: bundle.generatedAt,
            signature: bundle.signature
        )
        #expect(!owner.verifyPrekeyBundleSignature(tampered, signingPublicKey: owner.getSigningPublicKeyData()))
    }

    @Test func wrongSigningKeyFailsVerification() throws {
        let owner = NoiseEncryptionService(keychain: MockKeychain())
        let other = NoiseEncryptionService(keychain: MockKeychain())
        let bundle = try #require(owner.currentPrekeyBundle())

        #expect(!owner.verifyPrekeyBundleSignature(bundle, signingPublicKey: other.getSigningPublicKeyData()))
    }
}
