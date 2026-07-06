//
// PrekeyBundle.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// TLV payload for gossiped one-time prekey bundles (MessageType 0x24).
///
/// A bundle publishes a batch of one-time Curve25519 public prekeys bound to
/// the owner's Noise static key by an Ed25519 signature over domain-prefixed
/// canonical bytes. Anyone holding the owner's announce-verified signing key
/// can verify a bundle offline, which is what lets bundles spread and persist
/// mesh-wide via gossip sync while the owner is away. Senders seal courier
/// mail to one of these prekeys (one-way Noise X) instead of the owner's
/// long-lived static key, restoring forward secrecy for async first contact.
public struct PrekeyBundle: Equatable {
    public struct Prekey: Equatable {
        public let id: UInt32
        /// Curve25519.KeyAgreement public key (32 bytes).
        public let publicKey: Data

        public init(id: UInt32, publicKey: Data) {
            self.id = id
            self.publicKey = publicKey
        }
    }

    /// Noise static public key identifying whose prekeys these are (32 bytes).
    public let noiseStaticPublicKey: Data
    /// One-time prekeys, at most `maxPrekeys` per bundle.
    public let prekeys: [Prekey]
    /// Milliseconds since epoch when this bundle was generated; newer bundles
    /// replace older ones for the same noise key.
    public let generatedAt: UInt64
    /// Ed25519 signature over `signableBytes()` by the owner's announce-bound
    /// signing key.
    public let signature: Data

    public static let keyLength = 32
    public static let signatureLength = 64
    public static let maxPrekeys = 8
    private static let prekeyEntryLength = 4 + keyLength

    /// Domain separation for the bundle signature so it can never be confused
    /// with announce or packet signatures.
    private static let signingContext = Data("bitchat-prekey-bundle-v1".utf8)

    private enum TLVType: UInt8 {
        case noiseStaticPublicKey = 0x01
        case prekeys = 0x02
        case generatedAt = 0x03
        case signature = 0x04
    }

    public init(noiseStaticPublicKey: Data, prekeys: [Prekey], generatedAt: UInt64, signature: Data) {
        self.noiseStaticPublicKey = noiseStaticPublicKey
        self.prekeys = prekeys
        self.generatedAt = generatedAt
        self.signature = signature
    }

    /// Canonical bytes covered by the Ed25519 signature: domain context,
    /// owner key, prekey count, each (id, key) pair, and the generation time.
    /// Encoders and verifiers must derive these identically.
    public func signableBytes() -> Data {
        var out = Data()
        out.reserveCapacity(1 + Self.signingContext.count + Self.keyLength + 1
            + prekeys.count * Self.prekeyEntryLength + 8)
        out.append(UInt8(min(Self.signingContext.count, 255)))
        out.append(Self.signingContext.prefix(255))
        out.append(paddedKey(noiseStaticPublicKey))
        out.append(UInt8(min(prekeys.count, 255)))
        for prekey in prekeys.prefix(255) {
            appendBE(prekey.id, into: &out)
            out.append(paddedKey(prekey.publicKey))
        }
        appendBE(generatedAt, into: &out)
        return out
    }

    public func encode() -> Data? {
        guard noiseStaticPublicKey.count == Self.keyLength,
              signature.count == Self.signatureLength,
              !prekeys.isEmpty, prekeys.count <= Self.maxPrekeys,
              prekeys.allSatisfy({ $0.publicKey.count == Self.keyLength }) else {
            return nil
        }

        var entries = Data()
        entries.reserveCapacity(prekeys.count * Self.prekeyEntryLength)
        for prekey in prekeys {
            appendBE(prekey.id, into: &entries)
            entries.append(prekey.publicKey)
        }

        var encoded = Data()
        encoded.reserveCapacity(4 * 3 + Self.keyLength + entries.count + 8 + Self.signatureLength)

        encoded.append(TLVType.noiseStaticPublicKey.rawValue)
        appendBE(UInt16(noiseStaticPublicKey.count), into: &encoded)
        encoded.append(noiseStaticPublicKey)

        encoded.append(TLVType.prekeys.rawValue)
        appendBE(UInt16(entries.count), into: &encoded)
        encoded.append(entries)

        encoded.append(TLVType.generatedAt.rawValue)
        appendBE(UInt16(8), into: &encoded)
        appendBE(generatedAt, into: &encoded)

        encoded.append(TLVType.signature.rawValue)
        appendBE(UInt16(signature.count), into: &encoded)
        encoded.append(signature)

        return encoded
    }

    public static func decode(_ data: Data) -> PrekeyBundle? {
        var cursor = data.startIndex
        let end = data.endIndex

        var noiseStaticPublicKey: Data?
        var prekeys: [Prekey]?
        var generatedAt: UInt64?
        var signature: Data?

        while cursor < end {
            let typeRaw = data[cursor]
            cursor = data.index(after: cursor)

            guard data.distance(from: cursor, to: end) >= 2 else { return nil }
            let length = Int(data[cursor]) << 8 | Int(data[data.index(after: cursor)])
            cursor = data.index(cursor, offsetBy: 2)
            guard data.distance(from: cursor, to: end) >= length else { return nil }
            let value = data[cursor..<data.index(cursor, offsetBy: length)]
            cursor = data.index(cursor, offsetBy: length)

            switch TLVType(rawValue: typeRaw) {
            case .noiseStaticPublicKey:
                guard length == keyLength else { return nil }
                noiseStaticPublicKey = Data(value)
            case .prekeys:
                guard length > 0, length % prekeyEntryLength == 0,
                      length / prekeyEntryLength <= maxPrekeys else { return nil }
                var parsed: [Prekey] = []
                var entryStart = value.startIndex
                while entryStart < value.endIndex {
                    let idEnd = value.index(entryStart, offsetBy: 4)
                    let id = value[entryStart..<idEnd].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    let keyEnd = value.index(idEnd, offsetBy: keyLength)
                    parsed.append(Prekey(id: id, publicKey: Data(value[idEnd..<keyEnd])))
                    entryStart = keyEnd
                }
                prekeys = parsed
            case .generatedAt:
                guard length == 8 else { return nil }
                generatedAt = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            case .signature:
                guard length == signatureLength else { return nil }
                signature = Data(value)
            case nil:
                // Unknown TLV: skip for forward compatibility.
                continue
            }
        }

        guard let noiseStaticPublicKey, let prekeys, let generatedAt, let signature,
              !prekeys.isEmpty else { return nil }
        // Duplicate prekey IDs would let one consumed ID shadow another.
        guard Set(prekeys.map(\.id)).count == prekeys.count else { return nil }
        return PrekeyBundle(
            noiseStaticPublicKey: noiseStaticPublicKey,
            prekeys: prekeys,
            generatedAt: generatedAt,
            signature: signature
        )
    }

    // MARK: - Helpers

    private func paddedKey(_ key: Data) -> Data {
        let fixed = key.prefix(Self.keyLength)
        guard fixed.count < Self.keyLength else { return Data(fixed) }
        return Data(fixed) + Data(repeating: 0, count: Self.keyLength - fixed.count)
    }
}

private func appendBE<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
}
