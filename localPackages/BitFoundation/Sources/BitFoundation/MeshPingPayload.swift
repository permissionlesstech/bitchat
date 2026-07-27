//
// MeshPingPayload.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data

/// Wire payload shared by the `ping` (0x26) and `pong` (0x27) message types.
///
/// Layout (9 bytes):
/// - 8 bytes: random nonce (a pong echoes the nonce of the ping it answers)
/// - 1 byte: origin TTL — the TTL the packet was launched with, so the
///   receiver can compute the hop count as `originTTL - receivedTTL`.
///
/// Both directions are unencrypted and unsigned: the payload carries no
/// private data, and the unguessable nonce already binds a pong to a probe
/// the local device actually sent.
public struct MeshPingPayload: Equatable {
    public static let nonceLength = 8
    private static let encodedLength = nonceLength + 1

    public let nonce: Data
    public let originTTL: UInt8

    public init?(nonce: Data, originTTL: UInt8) {
        guard nonce.count == Self.nonceLength else { return nil }
        self.nonce = nonce
        self.originTTL = originTTL
    }

    public func encode() -> Data {
        var data = Data(capacity: Self.encodedLength)
        data.append(nonce)
        data.append(originTTL)
        return data
    }

    /// Accepts payloads with trailing bytes so future revisions can extend
    /// the format without breaking older clients.
    public static func decode(_ data: Data) -> MeshPingPayload? {
        guard data.count >= encodedLength else { return nil }
        let nonce = Data(data.prefix(nonceLength))
        let originTTL = data[data.index(data.startIndex, offsetBy: nonceLength)]
        return MeshPingPayload(nonce: nonce, originTTL: originTTL)
    }

    /// Number of links a packet crossed, derived from TTL decrements plus the
    /// final delivery link (a directly connected peer is 1 hop away).
    /// Returns nil when the TTLs are inconsistent (received above origin).
    public static func hopCount(originTTL: UInt8, receivedTTL: UInt8) -> Int? {
        guard originTTL >= receivedTTL else { return nil }
        return Int(originTTL - receivedTTL) + 1
    }
}
