import CryptoKit
import Foundation
import Testing

@testable import bitchat

struct VouchAttestationTests {
    private let voucherKey = Curve25519.Signing.PrivateKey()

    private func makeAttestation(
        fingerprint: Data = Data(repeating: 0xAA, count: 32),
        signingKey: Data = Data(repeating: 0xBB, count: 32),
        timestampMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        signedBy key: Curve25519.Signing.PrivateKey? = nil
    ) throws -> VouchAttestation {
        let signer = key ?? voucherKey
        return try #require(
            VouchAttestation.build(
                voucheeFingerprint: fingerprint,
                voucheeSigningKey: signingKey,
                timestampMs: timestampMs,
                sign: { try? signer.signature(for: $0) }
            )
        )
    }

    @Test
    func roundTripsAndVerifiesSignature() throws {
        let attestation = try makeAttestation()
        let encoded = try #require(attestation.encode())
        let decoded = try #require(VouchAttestation.decode(from: encoded))

        #expect(decoded == attestation)
        #expect(decoded.voucheeFingerprintHex == String(repeating: "aa", count: 32))
        #expect(decoded.verifySignature(voucherSigningKey: voucherKey.publicKey.rawRepresentation))
    }

    @Test
    func decodeSkipsUnknownTLVsAndRejectsMalformedInput() throws {
        let attestation = try makeAttestation()
        var encoded = try #require(attestation.encode())

        // Unknown TLV appended: skipped for forward compatibility.
        encoded.append(contentsOf: [0x7F, 0x02, 0x01, 0x02])
        #expect(VouchAttestation.decode(from: encoded) == attestation)

        // Truncation and missing fields are rejected.
        #expect(VouchAttestation.decode(from: encoded.dropLast()) == nil)
        #expect(VouchAttestation.decode(from: Data([0x01, 0x20])) == nil)
        #expect(VouchAttestation.decode(from: Data()) == nil)

        // Wrong field sizes are rejected.
        var wrongSize = Data([0x01, 0x10])
        wrongSize.append(Data(repeating: 0xAA, count: 16))
        #expect(VouchAttestation.decode(from: wrongSize) == nil)
    }

    @Test
    func buildRejectsWrongKeyAndFingerprintSizes() {
        let sign: (Data) -> Data? = { try? self.voucherKey.signature(for: $0) }
        #expect(VouchAttestation.build(
            voucheeFingerprint: Data(repeating: 0xAA, count: 16),
            voucheeSigningKey: Data(repeating: 0xBB, count: 32),
            sign: sign
        ) == nil)
        #expect(VouchAttestation.build(
            voucheeFingerprint: Data(repeating: 0xAA, count: 32),
            voucheeSigningKey: Data(repeating: 0xBB, count: 16),
            sign: sign
        ) == nil)
    }

    @Test
    func forgedSignatureFailsVerification() throws {
        let attestation = try makeAttestation()
        let otherKey = Curve25519.Signing.PrivateKey()

        // Verifying against a key that didn't sign fails.
        #expect(!attestation.verifySignature(voucherSigningKey: otherKey.publicKey.rawRepresentation))

        // An attestation signed by an imposter fails against the real key.
        let forged = try makeAttestation(signedBy: otherKey)
        #expect(!forged.verifySignature(voucherSigningKey: voucherKey.publicKey.rawRepresentation))
        #expect(!attestation.verifySignature(voucherSigningKey: Data(repeating: 0x01, count: 3)))
    }

    @Test
    func tamperedFieldsFailVerification() throws {
        let attestation = try makeAttestation()
        let publicKey = voucherKey.publicKey.rawRepresentation

        var tamperedFingerprint = attestation.voucheeFingerprint
        tamperedFingerprint[0] ^= 0xFF
        let tampered = VouchAttestation(
            voucheeFingerprint: tamperedFingerprint,
            voucheeSigningKey: attestation.voucheeSigningKey,
            timestampMs: attestation.timestampMs,
            signature: attestation.signature
        )
        #expect(!tampered.verifySignature(voucherSigningKey: publicKey))

        let backdated = VouchAttestation(
            voucheeFingerprint: attestation.voucheeFingerprint,
            voucheeSigningKey: attestation.voucheeSigningKey,
            timestampMs: attestation.timestampMs - 1,
            signature: attestation.signature
        )
        #expect(!backdated.verifySignature(voucherSigningKey: publicKey))
    }

    @Test
    func expiryWindowIsEnforced() throws {
        let now = Date()
        let fresh = try makeAttestation(timestampMs: UInt64(now.timeIntervalSince1970 * 1000))
        #expect(!fresh.isExpired(now: now))

        let thirtyOneDaysAgo = now.addingTimeInterval(-31 * 24 * 60 * 60)
        let expired = try makeAttestation(timestampMs: UInt64(thirtyOneDaysAgo.timeIntervalSince1970 * 1000))
        #expect(expired.isExpired(now: now))

        let farFuture = now.addingTimeInterval(2 * 60 * 60)
        let fromTheFuture = try makeAttestation(timestampMs: UInt64(farFuture.timeIntervalSince1970 * 1000))
        #expect(fromTheFuture.isExpired(now: now))

        // A verified-but-expired attestation still has a valid signature; the
        // two checks are independent gates.
        #expect(expired.verifySignature(voucherSigningKey: voucherKey.publicKey.rawRepresentation))
    }

    @Test
    func batchRoundTripsAndEnforcesCap() throws {
        let attestations = try (0..<3).map { index in
            try makeAttestation(fingerprint: Data(repeating: UInt8(index + 1), count: 32))
        }
        let payload = try #require(VouchAttestation.encodeList(attestations))
        #expect(VouchAttestation.decodeList(from: payload) == attestations)

        #expect(VouchAttestation.encodeList([]) == nil)

        let tooMany = try (0..<17).map { index in
            try makeAttestation(fingerprint: Data(repeating: UInt8(index + 1), count: 32))
        }
        #expect(VouchAttestation.encodeList(tooMany) == nil)
    }

    @Test
    func decodeListIgnoresEntriesBeyondCapAndMalformedEntries() throws {
        let attestations = try (0..<17).map { index in
            try makeAttestation(fingerprint: Data(repeating: UInt8(index + 1), count: 32))
        }
        // Hand-build an oversized batch that lies about its count.
        var payload = Data([UInt8(attestations.count)])
        for attestation in attestations {
            let encoded = try #require(attestation.encode())
            payload.append(UInt8(encoded.count >> 8))
            payload.append(UInt8(encoded.count & 0xFF))
            payload.append(encoded)
        }
        let decoded = VouchAttestation.decodeList(from: payload)
        #expect(decoded.count == VouchAttestation.maxBatchCount)
        #expect(decoded == Array(attestations.prefix(VouchAttestation.maxBatchCount)))

        // A malformed middle entry is dropped without killing the batch.
        let good = try makeAttestation()
        let goodEncoded = try #require(good.encode())
        var mixed = Data([2])
        mixed.append(contentsOf: [0x00, 0x03, 0xDE, 0xAD, 0xBE])
        mixed.append(UInt8(goodEncoded.count >> 8))
        mixed.append(UInt8(goodEncoded.count & 0xFF))
        mixed.append(goodEncoded)
        #expect(VouchAttestation.decodeList(from: mixed) == [good])

        #expect(VouchAttestation.decodeList(from: Data()) == [])
        #expect(VouchAttestation.decodeList(from: Data([5])) == [])
    }
}
