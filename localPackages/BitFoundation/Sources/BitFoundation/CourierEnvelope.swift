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
    /// Spray-and-wait copy budget: how many redundant copies of this envelope
    /// the holder may still hand to other couriers (binary split on each
    /// spray). 1 means carry-only — deliver to the recipient, never re-spray.
    public let copies: UInt8
    /// Seal-format discriminator: nil means v1 (ciphertext is one-way Noise X
    /// to the recipient's *static* key); a value means v2 (Noise X to the
    /// recipient's one-time prekey with this ID, forward secret). Encoded as
    /// an optional TLV so v1 decoders skip it as unknown: an old client still
    /// carries and hands over v2 envelopes opaquely, and when one is addressed
    /// to it the static-key open simply fails and is dropped quietly.
    public let prekeyID: UInt32?

    public static let tagLength = 16
    /// Couriered messages are text-sized; media transfers are out of scope.
    public static let maxCiphertextBytes = 16 * 1024
    /// Matches the outbox retention policy in MessageRouter.
    public static let maxLifetimeSeconds: TimeInterval = 24 * 60 * 60
    /// Cap on the copy budget a depositor can claim, so a malicious envelope
    /// cannot turn the courier network into an amplifier.
    public static let maxCopies: UInt8 = 8

    private enum TLVType: UInt8 {
        case recipientTag = 0x01
        case expiry = 0x02
        case ciphertext = 0x03
        case copies = 0x04
        case prekeyID = 0x05
    }

    public init(recipientTag: Data, expiry: UInt64, ciphertext: Data, copies: UInt8 = 1, prekeyID: UInt32? = nil) {
        self.recipientTag = recipientTag
        self.expiry = expiry
        self.ciphertext = ciphertext
        self.copies = min(max(copies, 1), Self.maxCopies)
        self.prekeyID = prekeyID
    }

    /// The same envelope with a different remaining copy budget.
    public func withCopies(_ copies: UInt8) -> CourierEnvelope {
        CourierEnvelope(recipientTag: recipientTag, expiry: expiry, ciphertext: ciphertext, copies: copies, prekeyID: prekeyID)
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

        var writer = TLVWriter(
            lengthWidth: .twoBytes,
            capacity: 3 * 3 + Self.tagLength + 8 + ciphertext.count
        )
        writer.append(TLVType.recipientTag.rawValue, recipientTag)
        writer.append(TLVType.expiry.rawValue, bigEndian: expiry)
        writer.append(TLVType.ciphertext.rawValue, ciphertext)

        // Omitted when 1 so carry-only envelopes stay byte-identical to the
        // pre-spray wire format (old clients skip the TLV as unknown anyway).
        if copies > 1 {
            writer.append(TLVType.copies.rawValue, byte: copies)
        }

        // Omitted for v1 static-sealed envelopes so they stay byte-identical
        // to the pre-prekey wire format.
        if let prekeyID {
            writer.append(TLVType.prekeyID.rawValue, bigEndian: prekeyID)
        }

        return writer.data
    }

    public static func decode(_ data: Data) -> CourierEnvelope? {
        var reader = TLVReader(data, lengthWidth: .twoBytes)
        var recipientTag: Data?
        var expiry: UInt64?
        var ciphertext: Data?
        var copies: UInt8 = 1
        var prekeyID: UInt32?

        loop: while true {
            switch reader.next() {
            case .end:
                break loop
            case .malformed:
                return nil
            case .entry(let typeRaw, let value):
                switch TLVType(rawValue: typeRaw) {
                case .recipientTag:
                    guard value.count == tagLength else { return nil }
                    recipientTag = Data(value)
                case .expiry:
                    guard let parsed: UInt64 = value.readBigEndian() else { return nil }
                    expiry = parsed
                case .ciphertext:
                    guard !value.isEmpty, value.count <= maxCiphertextBytes else { return nil }
                    ciphertext = Data(value)
                case .copies:
                    guard value.count == 1 else { return nil }
                    copies = value.first ?? 1
                case .prekeyID:
                    guard let parsed: UInt32 = value.readBigEndian() else { return nil }
                    prekeyID = parsed
                case nil:
                    // Unknown TLV: skip for forward compatibility.
                    continue
                }
            }
        }

        guard let recipientTag, let expiry, let ciphertext else { return nil }
        return CourierEnvelope(recipientTag: recipientTag, expiry: expiry, ciphertext: ciphertext, copies: copies, prekeyID: prekeyID)
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
