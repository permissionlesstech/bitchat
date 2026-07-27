//
// VouchAttestation.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation

/// A signed statement that the *sender of the enclosing Noise payload* has
/// verified the identity described here ("transitive verification").
///
/// The voucher's identity is deliberately implicit: attestations only travel
/// inside an authenticated Noise session (`NoisePayloadType.vouch`), so the
/// receiver verifies the Ed25519 signature against the session peer's
/// announce-bound signing key and stores the vouch keyed by that peer's
/// fingerprint. Nothing in the attestation names the voucher, so a captured
/// attestation cannot be replayed by a third party whose signing key doesn't
/// match.
///
/// Wire format — single attestation (TLV, 1-byte type + 1-byte length):
/// - `0x01` voucheeFingerprint: 32 bytes, SHA-256 of the vouchee's Noise static key
/// - `0x02` voucheeSigningKey: 32 bytes, Ed25519; anchors the vouch to a concrete identity
/// - `0x03` timestamp: 8 bytes big-endian, milliseconds since 1970
/// - `0x04` signature: 64 bytes, Ed25519 by the VOUCHER's signing key over
///   `"bitchat-vouch-v1" | voucheeFingerprint | voucheeSigningKey | timestamp`
///
/// Unknown TLV types are skipped for forward compatibility.
///
/// Batch format (the `vouch` Noise payload body):
/// `[count: UInt8]` then per attestation `[length: UInt16 BE][attestation TLV]`.
struct VouchAttestation: Equatable {
    static let signingContext = "bitchat-vouch-v1"
    /// Receiver-side expiry for attestations.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    /// Tolerated clock skew for attestations timestamped in the future.
    static let maxClockSkew: TimeInterval = 60 * 60
    /// Upper bound of attestations carried/accepted in one batch payload.
    static let maxBatchCount = 16

    static let fingerprintSize = 32
    static let signingKeySize = 32
    static let signatureSize = 64

    let voucheeFingerprint: Data  // 32 bytes
    let voucheeSigningKey: Data   // 32 bytes
    let timestampMs: UInt64
    let signature: Data           // 64 bytes

    private enum TLVType: UInt8 {
        case voucheeFingerprint = 0x01
        case voucheeSigningKey = 0x02
        case timestamp = 0x03
        case signature = 0x04
    }

    var voucheeFingerprintHex: String { voucheeFingerprint.hexEncodedString() }

    var timestamp: Date { Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000) }

    /// The exact bytes the voucher signs.
    static func signableBytes(
        voucheeFingerprint: Data,
        voucheeSigningKey: Data,
        timestampMs: UInt64
    ) -> Data {
        var message = Data(signingContext.utf8)
        message.append(voucheeFingerprint)
        message.append(voucheeSigningKey)
        var timestampBE = timestampMs.bigEndian
        withUnsafeBytes(of: &timestampBE) { message.append(contentsOf: $0) }
        return message
    }

    var signableBytes: Data {
        Self.signableBytes(
            voucheeFingerprint: voucheeFingerprint,
            voucheeSigningKey: voucheeSigningKey,
            timestampMs: timestampMs
        )
    }

    /// Builds and signs an attestation. `sign` is the voucher's Ed25519
    /// signing primitive (e.g. `Transport.noiseSignData`).
    static func build(
        voucheeFingerprint: Data,
        voucheeSigningKey: Data,
        timestampMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        sign: (Data) -> Data?
    ) -> VouchAttestation? {
        guard voucheeFingerprint.count == fingerprintSize,
              voucheeSigningKey.count == signingKeySize else { return nil }
        let message = signableBytes(
            voucheeFingerprint: voucheeFingerprint,
            voucheeSigningKey: voucheeSigningKey,
            timestampMs: timestampMs
        )
        guard let signature = sign(message), signature.count == signatureSize else { return nil }
        return VouchAttestation(
            voucheeFingerprint: voucheeFingerprint,
            voucheeSigningKey: voucheeSigningKey,
            timestampMs: timestampMs,
            signature: signature
        )
    }

    /// Verifies the Ed25519 signature against the voucher's announce-bound
    /// signing key.
    func verifySignature(voucherSigningKey: Data) -> Bool {
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: voucherSigningKey) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: signableBytes)
    }

    /// Whether the attestation is outside its validity window (older than
    /// `maxAge`, or timestamped implausibly far in the future).
    func isExpired(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age > Self.maxAge || age < -Self.maxClockSkew
    }

    // MARK: - Encoding

    func encode() -> Data? {
        guard voucheeFingerprint.count == Self.fingerprintSize,
              voucheeSigningKey.count == Self.signingKeySize,
              signature.count == Self.signatureSize else { return nil }
        var data = Data()
        func appendTLV(_ type: TLVType, _ value: Data) {
            data.append(type.rawValue)
            data.append(UInt8(value.count))
            data.append(value)
        }
        appendTLV(.voucheeFingerprint, voucheeFingerprint)
        appendTLV(.voucheeSigningKey, voucheeSigningKey)
        var timestampBE = timestampMs.bigEndian
        appendTLV(.timestamp, withUnsafeBytes(of: &timestampBE) { Data($0) })
        appendTLV(.signature, signature)
        return data
    }

    static func decode(from data: Data) -> VouchAttestation? {
        var fingerprint: Data?
        var signingKey: Data?
        var timestampMs: UInt64?
        var signature: Data?

        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.index(offset, offsetBy: 2, limitedBy: data.endIndex) != nil,
                  offset + 1 < data.endIndex else { return nil }
            let type = data[offset]
            let length = Int(data[offset + 1])
            let valueStart = offset + 2
            guard let valueEnd = data.index(valueStart, offsetBy: length, limitedBy: data.endIndex) else {
                return nil
            }
            let value = Data(data[valueStart..<valueEnd])
            switch TLVType(rawValue: type) {
            case .voucheeFingerprint:
                guard value.count == fingerprintSize else { return nil }
                fingerprint = value
            case .voucheeSigningKey:
                guard value.count == signingKeySize else { return nil }
                signingKey = value
            case .timestamp:
                guard value.count == 8 else { return nil }
                timestampMs = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            case .signature:
                guard value.count == signatureSize else { return nil }
                signature = value
            case nil:
                break // Unknown TLV: skip for forward compatibility.
            }
            offset = valueEnd
        }

        guard let fingerprint, let signingKey, let timestampMs, let signature else { return nil }
        return VouchAttestation(
            voucheeFingerprint: fingerprint,
            voucheeSigningKey: signingKey,
            timestampMs: timestampMs,
            signature: signature
        )
    }

    // MARK: - Batch encoding

    /// Encodes up to `maxBatchCount` attestations into one payload body.
    static func encodeList(_ attestations: [VouchAttestation]) -> Data? {
        guard !attestations.isEmpty, attestations.count <= maxBatchCount else { return nil }
        var data = Data()
        data.append(UInt8(attestations.count))
        for attestation in attestations {
            guard let encoded = attestation.encode(), encoded.count <= Int(UInt16.max) else { return nil }
            var lengthBE = UInt16(encoded.count).bigEndian
            withUnsafeBytes(of: &lengthBE) { data.append(contentsOf: $0) }
            data.append(encoded)
        }
        return data
    }

    /// Decodes a batch payload, dropping malformed entries and ignoring
    /// anything beyond `maxBatchCount` (sender-declared count is not trusted).
    static func decodeList(from data: Data) -> [VouchAttestation] {
        guard data.count > 1 else { return [] }
        let declaredCount = Int(data[data.startIndex])
        let limit = min(declaredCount, maxBatchCount)
        var attestations: [VouchAttestation] = []
        var offset = data.startIndex + 1
        while attestations.count < limit, offset < data.endIndex {
            guard let lengthEnd = data.index(offset, offsetBy: 2, limitedBy: data.endIndex) else { break }
            let length = Int(data[offset]) << 8 | Int(data[offset + 1])
            guard let entryEnd = data.index(lengthEnd, offsetBy: length, limitedBy: data.endIndex) else { break }
            if let attestation = decode(from: Data(data[lengthEnd..<entryEnd])) {
                attestations.append(attestation)
            }
            offset = entryEnd
        }
        return attestations
    }
}
