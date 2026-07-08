import Foundation

/// Feature capabilities a peer advertises in its announce packet.
///
/// Encoded as a little-endian bitfield with trailing zero bytes dropped, so the
/// wire form grows only when high bits are assigned. Decoders keep the low 64
/// bits and ignore any longer field, and unknown bits are preserved verbatim —
/// old clients skip the TLV entirely, new clients degrade per-feature.
public struct PeerCapabilities: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let prekeys = PeerCapabilities(rawValue: 1 << 0)
    public static let wifiBulk = PeerCapabilities(rawValue: 1 << 1)
    public static let gateway = PeerCapabilities(rawValue: 1 << 2)
    public static let groups = PeerCapabilities(rawValue: 1 << 3)
    public static let board = PeerCapabilities(rawValue: 1 << 4)
    public static let vouch = PeerCapabilities(rawValue: 1 << 5)
    public static let meshDiagnostics = PeerCapabilities(rawValue: 1 << 6)
    /// Bridges the local mesh channel to the geohash-cell rendezvous on Nostr
    /// (uplink/downlink carriers for mesh-only peers). Advertised alongside
    /// a `bridgeGeohash` TLV carrying the rendezvous cell.
    public static let bridge = PeerCapabilities(rawValue: 1 << 7)

    /// Minimal little-endian byte encoding; always at least one byte so an
    /// empty set is distinguishable from an absent TLV.
    public func encoded() -> Data {
        var value = rawValue
        var bytes = Data()
        repeat {
            bytes.append(UInt8(truncatingIfNeeded: value))
            value >>= 8
        } while value != 0
        return bytes
    }

    /// Accepts any length; bytes beyond the low 64 bits are ignored for
    /// forward compatibility.
    public init(encoded data: Data) {
        var value: UInt64 = 0
        for (index, byte) in data.prefix(8).enumerated() {
            value |= UInt64(byte) << (8 * index)
        }
        self.init(rawValue: value)
    }
}
