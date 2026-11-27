//
// NostrCarrierPacket.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Wire payload for `MessageType.nostrCarrier` (0x28): a complete, signed
/// Nostr event ferried over the mesh between a mesh-only peer and an
/// internet gateway peer.
///
/// - `toGateway` rides a DIRECTED packet (recipientID = the gateway peer):
///   a mesh-only sender asks the gateway to publish its locally signed
///   geohash event to Nostr relays.
/// - `fromGateway` rides a BROADCAST packet (default TTL): the gateway
///   rebroadcasts inbound relay events so mesh-only peers see the channel.
///
/// The carried event is public geohash chat — already plaintext on Nostr —
/// so the carrier adds no encryption. It IS signed by the originator's
/// per-geohash identity, so neither the gateway nor any mesh relay can forge
/// or alter it undetected: gateways and receivers verify the Schnorr
/// signature before acting on it.
///
/// TLV encoding with 2-byte big-endian lengths (the event JSON exceeds the
/// 1-byte TLV range used by smaller packets). Unknown TLV types are skipped
/// for forward compatibility.
struct NostrCarrierPacket: Equatable {
    enum Direction: UInt8 {
        case toGateway = 0x01
        case fromGateway = 0x02
        /// Mesh-bridge uplink: a mesh-only peer asks a bridge gateway to
        /// publish its signed rendezvous event. Directed, like `toGateway`.
        case toBridge = 0x03
        /// Mesh-bridge downlink: a bridge gateway rebroadcasts a rendezvous
        /// event from a remote island. Broadcast, like `fromGateway`.
        /// Old clients fail the Direction decode on 0x03/0x04 and drop the
        /// carrier quietly — bridge traffic degrades to invisible, not junk.
        case fromBridge = 0x04
    }

    let direction: Direction
    let geohash: String
    /// Complete signed Nostr event JSON (id, pubkey, created_at, kind, tags,
    /// content, sig).
    let eventJSON: Data

    /// BLE airtime cap for a carried event.
    static let maxEventJSONBytes = 16 * 1024
    static let maxGeohashLength = 12

    private enum TLVType: UInt8 {
        case direction = 0x01
        case geohash = 0x02
        case eventJSON = 0x03
    }

    init?(direction: Direction, geohash: String, eventJSON: Data) {
        let geohashBytes = Data(geohash.utf8)
        guard !geohashBytes.isEmpty,
              geohashBytes.count <= Self.maxGeohashLength,
              !eventJSON.isEmpty,
              eventJSON.count <= Self.maxEventJSONBytes else {
            return nil
        }
        self.direction = direction
        self.geohash = geohash
        self.eventJSON = eventJSON
    }

    init?(direction: Direction, geohash: String, event: NostrEvent) {
        guard let json = try? event.jsonString(), !json.isEmpty else { return nil }
        self.init(direction: direction, geohash: geohash, eventJSON: Data(json.utf8))
    }

    /// Decodes the carried event. Callers MUST still verify
    /// `event.isValidSignature()` before publishing or displaying it.
    func event() -> NostrEvent? {
        guard let dict = try? JSONSerialization.jsonObject(with: eventJSON) as? [String: Any] else {
            return nil
        }
        return try? NostrEvent(from: dict)
    }

    func encode() -> Data? {
        var writer = TLVWriter(
            lengthWidth: .twoBytes,
            capacity: eventJSON.count + geohash.utf8.count + 12
        )
        writer.append(TLVType.direction.rawValue, byte: direction.rawValue)
        writer.append(TLVType.geohash.rawValue, Data(geohash.utf8))
        writer.append(TLVType.eventJSON.rawValue, eventJSON)
        return writer.data
    }

    static func decode(_ data: Data) -> NostrCarrierPacket? {
        var reader = TLVReader(data, lengthWidth: .twoBytes)
        var direction: Direction?
        var geohash: String?
        var eventJSON: Data?

        loop: while true {
            switch reader.next() {
            case .end:
                break loop
            case .malformed:
                return nil
            case .entry(let typeRaw, let value):
                switch TLVType(rawValue: typeRaw) {
                case .direction:
                    guard value.count == 1, let parsed = Direction(rawValue: value[value.startIndex]) else { return nil }
                    direction = parsed
                case .geohash:
                    guard let parsed = String(data: value, encoding: .utf8) else { return nil }
                    geohash = parsed
                case .eventJSON:
                    eventJSON = Data(value)
                case nil:
                    // Unknown TLV; skip (tolerant decoder for forward compatibility).
                    continue
                }
            }
        }

        guard let direction, let geohash, let eventJSON else { return nil }
        return NostrCarrierPacket(direction: direction, geohash: geohash, eventJSON: eventJSON)
    }
}
