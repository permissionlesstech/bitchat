import BitFoundation
import Foundation

struct BLEFragmentKey: Hashable, Equatable {
    let sender: UInt64
    let id: UInt64
}

struct BLEFragmentHeader: Equatable {
    let key: BLEFragmentKey
    let index: Int
    let total: Int
    let originalType: UInt8
    let fragmentData: Data
    let isBroadcastFragment: Bool

    var idLogString: String {
        String(format: "%016llx", key.id)
    }

    init?(packet: BitchatPacket) {
        // Minimum header: 8 bytes ID + 2 index + 2 total + 1 type.
        guard packet.payload.count >= 13 else { return nil }

        var senderU64: UInt64 = 0
        for byte in packet.senderID.prefix(8) {
            senderU64 = (senderU64 << 8) | UInt64(byte)
        }

        var fragmentU64: UInt64 = 0
        for byte in packet.payload.prefix(8) {
            fragmentU64 = (fragmentU64 << 8) | UInt64(byte)
        }

        let index = Int((UInt16(packet.payload[8]) << 8) | UInt16(packet.payload[9]))
        let total = Int((UInt16(packet.payload[10]) << 8) | UInt16(packet.payload[11]))

        guard total > 0 && total <= 10_000 && index >= 0 && index < total else {
            return nil
        }

        let isBroadcastFragment: Bool = {
            guard let recipient = packet.recipientID else { return true }
            return recipient.count == 8 && recipient.allSatisfy { $0 == 0xFF }
        }()

        self.key = BLEFragmentKey(sender: senderU64, id: fragmentU64)
        self.index = index
        self.total = total
        self.originalType = packet.payload[12]
        self.fragmentData = Data(packet.payload.suffix(from: 13))
        self.isBroadcastFragment = isBroadcastFragment
    }
}

struct BLEFragmentAssemblyBuffer {
    enum AppendResult: Equatable {
        case stored(header: BLEFragmentHeader, started: Bool)
        case complete(header: BLEFragmentHeader, reassembledData: Data, started: Bool)
        case oversized(header: BLEFragmentHeader, projectedSize: Int, limit: Int, started: Bool)
    }

    private struct Metadata {
        let type: UInt8
        let total: Int
        let timestamp: Date
    }

    private var fragmentsByKey: [BLEFragmentKey: [Int: Data]] = [:]
    private var metadataByKey: [BLEFragmentKey: Metadata] = [:]

    mutating func removeAll() {
        fragmentsByKey.removeAll()
        metadataByKey.removeAll()
    }

    @discardableResult
    mutating func removeExpired(before cutoff: Date) -> Int {
        let expiredKeys = metadataByKey
            .filter { $0.value.timestamp < cutoff }
            .map(\.key)

        for key in expiredKeys {
            fragmentsByKey.removeValue(forKey: key)
            metadataByKey.removeValue(forKey: key)
        }

        return expiredKeys.count
    }

    mutating func append(
        _ header: BLEFragmentHeader,
        maxInFlightAssemblies: Int,
        now: Date = Date()
    ) -> AppendResult {
        let started = startAssemblyIfNeeded(for: header, maxInFlightAssemblies: maxInFlightAssemblies, now: now)

        let currentSize = fragmentsByKey[header.key]?.values.reduce(0) { $0 + $1.count } ?? 0
        let limit = Self.assemblyLimit(for: header.originalType)
        let projectedSize = currentSize + header.fragmentData.count

        guard projectedSize <= limit else {
            fragmentsByKey.removeValue(forKey: header.key)
            metadataByKey.removeValue(forKey: header.key)
            return .oversized(header: header, projectedSize: projectedSize, limit: limit, started: started)
        }

        fragmentsByKey[header.key]?[header.index] = header.fragmentData

        guard let fragments = fragmentsByKey[header.key],
              fragments.count == header.total else {
            return .stored(header: header, started: started)
        }

        let reassembled = (0..<header.total).reduce(into: Data()) { data, index in
            if let fragment = fragments[index] {
                data.append(fragment)
            }
        }

        fragmentsByKey.removeValue(forKey: header.key)
        metadataByKey.removeValue(forKey: header.key)

        return .complete(header: header, reassembledData: reassembled, started: started)
    }

    private mutating func startAssemblyIfNeeded(
        for header: BLEFragmentHeader,
        maxInFlightAssemblies: Int,
        now: Date
    ) -> Bool {
        guard fragmentsByKey[header.key] == nil else { return false }

        if fragmentsByKey.count >= maxInFlightAssemblies,
           let oldest = metadataByKey.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
            fragmentsByKey.removeValue(forKey: oldest)
            metadataByKey.removeValue(forKey: oldest)
        }

        fragmentsByKey[header.key] = [:]
        metadataByKey[header.key] = Metadata(type: header.originalType, total: header.total, timestamp: now)
        return true
    }

    private static func assemblyLimit(for originalType: UInt8) -> Int {
        if originalType == MessageType.fileTransfer.rawValue {
            // Allow headroom for TLV metadata and binary framing overhead.
            return FileTransferLimits.maxFramedFileBytes
        }

        return FileTransferLimits.maxPayloadBytes
    }
}
