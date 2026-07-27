import BitFoundation
import Foundation

/// Bitfield describing which message types are covered by a REQUEST_SYNC round.
/// Matches the Android mapping (bit index -> message type).
struct SyncTypeFlags: OptionSet {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        // Drop any bit that doesn't map to a known message type. Wire data can
        // carry up to 8 bytes of flags; without this mask, bits with no type
        // (a truncated/garbled field, or a type a newer peer added) would live
        // in the set as phantom membership that no `contains` check matches and
        // `toData` re-serializes — a meaningless "accepted but does nothing"
        // state. Masking here keeps every instance normalized at the source.
        self.rawValue = rawValue & SyncTypeFlags.knownTypeMask
    }

    /// Union of every bit that maps to a message type. Derived from the
    /// bit↔type table so it tracks automatically when a type is added.
    private static let knownTypeMask: UInt64 = {
        var mask: UInt64 = 0
        for bit in 0..<64 where SyncTypeFlags.type(forBit: bit) != nil {
            mask |= (1 << UInt64(bit))
        }
        return mask
    }()

    private static func bitIndex(for type: MessageType) -> Int? {
        switch type {
        case .announce: return 0
        case .message: return 1
        case .leave: return 2
        case .noiseHandshake: return 3
        case .noiseEncrypted: return 4
        case .fragment: return 5
        case .requestSync: return 6
        case .fileTransfer: return 7
        case .boardPost: return 8
        // Extended bits are compat-safe by construction: `toData()` encodes
        // the bitfield little-endian with trailing zero bytes trimmed (bit 10
        // widens the wire form from 1 to 2 bytes inside the length-prefixed
        // REQUEST_SYNC TLV 0x04), and `decode(_:)` accepts 1...8 bytes while
        // `type(forBit:)` maps unknown bits to nil — so old clients simply
        // ignore the group bit and answer with the types they know.
        case .groupMessage: return 10
        // Courier envelopes are directed deposits between trusted peers and
        // must never spread via gossip sync.
        case .courierEnvelope: return nil
        // Ping/pong are ephemeral directed probes; replaying them via gossip
        // sync would only produce stale, unanswerable echoes.
        case .ping, .pong: return nil
        // Gateway carriers are ephemeral live traffic (uplinks are directed,
        // downlinks are rate-budgeted rebroadcasts); replaying them via sync
        // would waste airtime and extend their lifetime.
        case .nostrCarrier: return nil
        // Live voice is only useful now; replaying stale audio frames via
        // sync would waste airtime (receivers drop them as stale anyway).
        case .voiceFrame: return nil
        // Prekey bundles gossip like board posts. The bitfield is a
        // wire-tolerant little-endian UInt64 (1-8 bytes, unknown high bits
        // ignored by `type(forBit:)`), so bits 8+ need no format change: old
        // clients decode the wider flags and simply never match the new bits.
        case .prekeyBundle: return 9
        }
    }

    private static func type(forBit index: Int) -> MessageType? {
        switch index {
        case 0: return .announce
        case 1: return .message
        case 2: return .leave
        case 3: return .noiseHandshake
        case 4: return .noiseEncrypted
        case 5: return .fragment
        case 6: return .requestSync
        case 7: return .fileTransfer
        // Bit 8 spills the encoded bitfield into a second byte. Decoders since
        // type-aware sync (#853) accept 1-8 bytes and map unknown bits to no
        // known type, so old clients ignore board rounds instead of choking.
        case 8: return .boardPost
        case 9: return .prekeyBundle
        case 10: return .groupMessage
        default:
            return nil
        }
    }

    static let announce = SyncTypeFlags(messageTypes: [.announce])
    static let message = SyncTypeFlags(messageTypes: [.message])
    static let fragment = SyncTypeFlags(messageTypes: [.fragment])
    static let fileTransfer = SyncTypeFlags(messageTypes: [.fileTransfer])
    static let board = SyncTypeFlags(messageTypes: [.boardPost])
    static let prekeyBundle = SyncTypeFlags(messageTypes: [.prekeyBundle])
    static let groupMessage = SyncTypeFlags(messageTypes: [.groupMessage])

    static let publicMessages = SyncTypeFlags(messageTypes: [.announce, .message])

    init(messageTypes: [MessageType]) {
        var raw: UInt64 = 0
        for type in messageTypes {
            guard let bit = SyncTypeFlags.bitIndex(for: type) else { continue }
            raw |= (1 << UInt64(bit))
        }
        self.init(rawValue: raw)
    }

    func contains(_ type: MessageType) -> Bool {
        guard let bit = SyncTypeFlags.bitIndex(for: type) else { return false }
        return contains(SyncTypeFlags(rawValue: 1 << UInt64(bit)))
    }

    func union(_ other: SyncTypeFlags) -> SyncTypeFlags {
        SyncTypeFlags(rawValue: rawValue | other.rawValue)
    }

    func intersection(_ other: SyncTypeFlags) -> SyncTypeFlags {
        SyncTypeFlags(rawValue: rawValue & other.rawValue)
    }

    /// Compact form for logs, e.g. "message+fragment". Without this, the
    /// per-schedule periodic sync rounds log identical lines and read as
    /// duplicated sends (misdiagnosed twice during July 2026 device testing).
    var logDescription: String {
        let types = toMessageTypes()
        guard !types.isEmpty else { return "none" }
        return types.map { String(describing: $0) }.joined(separator: "+")
    }

    func toMessageTypes() -> [MessageType] {
        guard rawValue != 0 else { return [] }
        var types: [MessageType] = []
        for bit in 0..<64 {
            guard (rawValue & (1 << UInt64(bit))) != 0 else { continue }
            if let type = SyncTypeFlags.type(forBit: bit) {
                types.append(type)
            }
        }
        return types
    }

    func toData() -> Data? {
        guard rawValue != 0 else { return nil }
        var value = rawValue
        var bytes: [UInt8] = []
        while value > 0 && bytes.count < 8 {
            bytes.append(UInt8(value & 0xFF))
            value >>= 8
        }
        while let last = bytes.last, last == 0 {
            bytes.removeLast()
        }
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        return Data(bytes)
    }

    static func decode(_ data: Data) -> SyncTypeFlags? {
        guard (1...8).contains(data.count) else { return nil }
        var raw: UInt64 = 0
        for (index, byte) in data.enumerated() {
            raw |= UInt64(byte) << UInt64(index * 8)
        }
        return SyncTypeFlags(rawValue: raw)
    }
}
