//
// AnnounceV2Packet.swift
// BitFoundation
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// periphery:ignore - intentionally unreferenced by production code; nothing
// emits or consumes this type yet, and BLEService parses it only to ignore it.
// Delete this annotation when the mesh starts using it.
/// Identity-free presence announcement for rotating peer IDs.
///
/// The v1 `AnnouncementPacket` broadcasts, in cleartext, every 4–30 seconds: the
/// nickname, the 32-byte Noise static public key, the 32-byte Ed25519 signing
/// key, and up to ten neighbour IDs. That is a permanent device fingerprint plus
/// the local social graph, free to anyone in radio range. This carries none of
/// it — only an epoch, a fixed-size block of pairwise recognition tags, and
/// capability bits.
///
/// Deliberately absent, with reasons:
/// - **Public keys**: they are the linkage. Peers learn them inside the Noise XX
///   handshake, where they are already encrypted on the wire.
/// - **Nickname**: a self-chosen, frequently reused human label. It moves into
///   the session (`AuthenticatedPeerStatePacket`).
/// - **Neighbour list**: it seeds source routing, whose documented fallback is
///   flooding. Publishing a crowd's adjacency graph is not a reasonable price
///   for routing efficiency.
///
/// **Unsigned, on purpose and not without cost.** There is no key to verify a
/// signature against without disclosing one, so this asserts only "somebody is
/// here, and here are some tags". An attacker can therefore emit noise — bounded
/// by existing announce and connection rate limits — but cannot impersonate a
/// specific peer, because forging a recognition tag needs one of the two private
/// keys, and cannot send anything without completing a handshake. The intended
/// posture is to treat a v2 announce as *unverified presence* and not surface it
/// until a tag matches or a handshake completes. See open question O4 in
/// `docs/PEER-ID-ROTATION.md`.
///
/// Not emitted or consumed by the shipping mesh yet.
public struct AnnounceV2Packet: Equatable, Sendable {
    /// Rotation epoch this announce was built for. Carried explicitly so a
    /// receiver matches against a stated epoch instead of guessing.
    public let epoch: UInt32
    /// Exactly `PeerIDRotation.tagSlots * PeerIDRotation.idLength` bytes.
    public let tagBlock: Data
    public let capabilities: PeerCapabilities?
    /// Coarse rendezvous cell, when bridging. Same semantics as v1.
    public let bridgeGeohash: String?

    public init(
        epoch: UInt32,
        tagBlock: Data,
        capabilities: PeerCapabilities? = nil,
        bridgeGeohash: String? = nil
    ) {
        self.epoch = epoch
        self.tagBlock = tagBlock
        self.capabilities = capabilities
        self.bridgeGeohash = bridgeGeohash
    }

    private enum TLVType: UInt8 {
        case epoch = 0x01
        case tagBlock = 0x02
        case capabilities = 0x03
        case bridgeGeohash = 0x04
    }

    /// Expected tag-block width. A fixed size is load-bearing: it hides how many
    /// mutual favourites a device has.
    public static var tagBlockLength: Int {
        PeerIDRotation.tagSlots * PeerIDRotation.idLength
    }

    public func encode() -> Data? {
        guard tagBlock.count == Self.tagBlockLength else { return nil }

        var writer = TLVWriter(lengthWidth: .oneByte)
        writer.append(TLVType.epoch.rawValue, bigEndian: epoch)
        writer.append(TLVType.tagBlock.rawValue, tagBlock)

        if let capabilities {
            let bytes = capabilities.encoded()
            guard bytes.count <= 255 else { return nil }
            writer.append(TLVType.capabilities.rawValue, bytes)
        }

        if let bridgeGeohash, !bridgeGeohash.isEmpty {
            let bytes = Data(bridgeGeohash.utf8)
            guard bytes.count <= 12 else { return nil }
            writer.append(TLVType.bridgeGeohash.rawValue, bytes)
        }

        return writer.data
    }

    public static func decode(from data: Data) -> AnnounceV2Packet? {
        var reader = TLVReader(data, lengthWidth: .oneByte)
        var epoch: UInt32?
        var tagBlock: Data?
        var capabilities: PeerCapabilities?
        var bridgeGeohash: String?

        loop: while true {
            switch reader.next() {
            case .end:
                break loop
            case .malformed:
                return nil
            case .entry(let rawType, let value):
                switch TLVType(rawValue: rawType) {
                case .epoch:
                    guard let parsed: UInt32 = value.readBigEndian() else { return nil }
                    epoch = parsed
                case .tagBlock:
                    guard value.count == tagBlockLength else { return nil }
                    tagBlock = Data(value)
                case .capabilities:
                    let bytes = Data(value)
                    let decoded = PeerCapabilities(encoded: bytes)
                    // Canonicality check, matching AuthenticatedPeerStatePacket: a
                    // non-minimal encoding would let the same capability set travel
                    // as different bytes.
                    guard decoded.encoded() == bytes else { return nil }
                    capabilities = decoded
                case .bridgeGeohash:
                    guard value.count <= 12, let text = String(data: value, encoding: .utf8) else { return nil }
                    bridgeGeohash = text
                case nil:
                    // Unknown TLV: skip, for forward compatibility.
                    break
                }
            }
        }

        guard let epoch, let tagBlock else { return nil }
        return AnnounceV2Packet(
            epoch: epoch,
            tagBlock: tagBlock,
            capabilities: capabilities,
            bridgeGeohash: bridgeGeohash
        )
    }
}
