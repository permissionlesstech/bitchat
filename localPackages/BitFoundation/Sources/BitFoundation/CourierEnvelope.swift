//
// CourierEnvelope.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
private import CryptoKit

/// TLV payload for store-and-forward courier envelopes.
///
/// A courier envelope lets a mutual favorite physically carry an encrypted
/// message to a peer who is currently offline. The envelope is opaque to the
/// courier: the only routing information is a rotating recipient tag derived
/// from the recipient's Noise static public key and the UTC day, so envelopes
/// addressed to the same peer on different days do not correlate for
/// observers who don't already know that peer's public key.
public struct CourierEnvelope: Equatable {
    /// Rotating recipient hint: HMAC-SHA256(recipient static key, context || epoch day), truncated.
    public let recipientTag: Data
    /// Milliseconds since epoch after which the envelope must be discarded.
    public let expiry: UInt64
    /// Opaque one-way Noise X ciphertext (sender identity rides inside).
    public let ciphertext: Data

    public static let tagLength = 16
    /// Couriered messages are text-sized; media transfers are out of scope.
    public static let maxCiphertextBytes = 16 * 1024
    /// Matches the outbox retention policy in MessageRouter.
    public static let maxLifetimeSeconds: TimeInterval = 24 * 60 * 60

    private enum TLVType: UInt8 {
        case recipientTag = 0x01
        case expiry = 0x02
        case ciphertext = 0x03
    }

    public init(recipientTag: Data, expiry: UInt64, ciphertext: Data) {
        self.recipientTag = recipientTag
        self.expiry = expiry
        self.ciphertext = ciphertext
    }

    public var isExpired: Bool {
        isExpired(at: Date())
    }

    public func isExpired(at date: Date) -> Bool {
        UInt64(max(0, date.timeIntervalSince1970 * 1000)) >= expiry
    }

    public func encode() -> Data? {
        guard recipientTag.count == Self.tagLength else { return nil }
        guard !ciphertext.isEmpty, ciphertext.count <= Self.maxCiphertextBytes else { return nil }

        func appendBE<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }

        var encoded = Data()
        encoded.reserveCapacity(3 * 3 + Self.tagLength + 8 + ciphertext.count)

        encoded.append(TLVType.recipientTag.rawValue)
        appendBE(UInt16(recipientTag.count), into: &encoded)
        encoded.append(recipientTag)

        encoded.append(TLVType.expiry.rawValue)
        appendBE(UInt16(8), into: &encoded)
        appendBE(expiry, into: &encoded)

        encoded.append(TLVType.ciphertext.rawValue)
        appendBE(UInt16(ciphertext.count), into: &encoded)
        encoded.append(ciphertext)

        return encoded
    }

    public static func decode(_ data: Data) -> CourierEnvelope? {
        var cursor = data.startIndex
        let end = data.endIndex

        var recipientTag: Data?
        var expiry: UInt64?
        var ciphertext: Data?

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
            case .recipientTag:
                guard length == tagLength else { return nil }
                recipientTag = Data(value)
            case .expiry:
                guard length == 8 else { return nil }
                expiry = value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            case .ciphertext:
                guard length > 0, length <= maxCiphertextBytes else { return nil }
                ciphertext = Data(value)
            case nil:
                // Unknown TLV: skip for forward compatibility.
                continue
            }
        }

        guard let recipientTag, let expiry, let ciphertext else { return nil }
        return CourierEnvelope(recipientTag: recipientTag, expiry: expiry, ciphertext: ciphertext)
    }

    // MARK: - Recipient Tags

    private static let tagContext = Data("bitchat-courier-tag-v1".utf8)

    /// UTC day number used to rotate recipient tags.
    public static func epochDay(for date: Date) -> UInt32 {
        UInt32(max(0, date.timeIntervalSince1970) / 86_400)
    }

    /// Rotating recipient hint for a given day. Computable only by parties
    /// who already know the recipient's Noise static public key.
    public static func recipientTag(noiseStaticKey: Data, epochDay: UInt32) -> Data {
        var message = tagContext
        withUnsafeBytes(of: epochDay.bigEndian) { message.append(contentsOf: $0) }
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: noiseStaticKey))
        return Data(mac).prefix(tagLength)
    }

    /// Tags to test when checking whether an envelope is addressed to a peer.
    /// Covers the adjacent days so envelopes sealed near midnight (or across
    /// modest clock skew) still match while being carried.
    public static func candidateTags(noiseStaticKey: Data, around date: Date) -> [Data] {
        let day = epochDay(for: date)
        return [day == 0 ? 0 : day - 1, day, day + 1].map {
            recipientTag(noiseStaticKey: noiseStaticKey, epochDay: $0)
        }
    }
}
