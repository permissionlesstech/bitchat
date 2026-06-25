import BitFoundation
import Foundation

/// Internal bitfield describing which message types are covered by a REQUEST_SYNC round.
/// The wire TLV uses raw `MessageType` bytes, matching Android's wantedTypes format.
struct SyncTypeFlags: OptionSet {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue & 0x00FF_FFFF_FFFF_FFFF // Trim to max 8 bytes
    }

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
        default:
            return nil
        }
    }

    static let announce = SyncTypeFlags(messageTypes: [.announce])
    static let message = SyncTypeFlags(messageTypes: [.message])
    static let fragment = SyncTypeFlags(messageTypes: [.fragment])
    static let fileTransfer = SyncTypeFlags(messageTypes: [.fileTransfer])

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
        let bytes = toMessageTypes().map(\.rawValue)
        guard !bytes.isEmpty else { return nil }
        return Data(bytes)
    }

    static func decode(_ data: Data) -> SyncTypeFlags? {
        guard !data.isEmpty else { return nil }

        // Prior experimental iOS builds encoded announce+message as the
        // bitfield byte 0x03. Android's upgraded wire format uses the same
        // value for LEAVE, which this sync manager does not store, so prefer
        // the legacy interpretation for the single-byte ambiguous case.
        if data.count == 1 && data[0] == 0x03 {
            return .publicMessages
        }

        let types = data.compactMap { MessageType(rawValue: $0) }
        if !types.isEmpty {
            return SyncTypeFlags(messageTypes: types)
        }

        return decodeLegacyBitfield(data)
    }

    private static func decodeLegacyBitfield(_ data: Data) -> SyncTypeFlags? {
        guard (1...8).contains(data.count) else { return nil }
        var raw: UInt64 = 0
        for (index, byte) in data.enumerated() {
            raw |= UInt64(byte) << UInt64(index * 8)
        }
        let flags = SyncTypeFlags(rawValue: raw)
        return flags.isEmpty ? nil : flags
    }
}
