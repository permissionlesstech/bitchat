import BitFoundation
import Foundation

struct BLEInboundWriteChunk: Equatable {
    let offset: Int
    let data: Data
}

struct BLEInboundWriteAppendMetadata: Equatable {
    let accumulatedBytes: Int
    let appendedBytes: Int
    let offsets: [Int]
    let packetType: UInt8?
}

struct BLEInboundWriteBuffer {
    static let defaultMaxTrackedCentrals = 64

    enum AppendResult {
        case decoded(packet: BitchatPacket, metadata: BLEInboundWriteAppendMetadata)
        case waiting(metadata: BLEInboundWriteAppendMetadata)
        case oversized(metadata: BLEInboundWriteAppendMetadata)
    }

    private var buffersByCentralID: [String: Data] = [:]
    private var centralOrder: [String] = []

    mutating func removeAll() {
        buffersByCentralID.removeAll()
        centralOrder.removeAll()
    }

    mutating func remove(for centralID: String) {
        buffersByCentralID.removeValue(forKey: centralID)
        centralOrder.removeAll { $0 == centralID }
    }

    mutating func append(
        chunks: [BLEInboundWriteChunk],
        for centralID: String,
        capBytes: Int,
        maxTrackedCentrals: Int = BLEInboundWriteBuffer.defaultMaxTrackedCentrals
    ) -> AppendResult {
        var combined = buffersByCentralID[centralID] ?? Data()
        var appendedBytes = 0
        var offsets: [Int] = []
        offsets.reserveCapacity(chunks.count)

        for chunk in chunks where !chunk.data.isEmpty {
            offsets.append(chunk.offset)
            let (end, overflow) = chunk.offset.addingReportingOverflow(chunk.data.count)

            guard chunk.offset >= 0, !overflow, end <= capBytes else {
                remove(for: centralID)
                let reportedAccumulated = (chunk.offset < 0 || overflow)
                    ? max(combined.count, capBytes + 1)
                    : max(combined.count, end)
                let metadata = BLEInboundWriteAppendMetadata(
                    accumulatedBytes: reportedAccumulated,
                    appendedBytes: appendedBytes + chunk.data.count,
                    offsets: offsets,
                    packetType: combined.count >= 2
                        ? combined[combined.startIndex + 1]
                        : (chunk.offset == 0 && chunk.data.count >= 2 ? chunk.data[chunk.data.startIndex + 1] : nil)
                )
                return .oversized(metadata: metadata)
            }

            if chunk.offset == combined.count {
                if combined.isEmpty {
                    combined = chunk.data.startIndex == 0 ? chunk.data : Data(chunk.data)
                } else {
                    combined.append(chunk.data)
                }
            } else {
                if combined.count < end {
                    combined.append(Data(repeating: 0, count: end - combined.count))
                }
                let base = combined.startIndex
                combined.replaceSubrange((base + chunk.offset)..<(base + end), with: chunk.data)
            }
            appendedBytes += chunk.data.count
        }

        let metadata = BLEInboundWriteAppendMetadata(
            accumulatedBytes: combined.count,
            appendedBytes: appendedBytes,
            offsets: offsets,
            packetType: combined.count >= 2 ? combined[combined.startIndex + 1] : nil
        )

        if Self.hasCompleteFrame(combined), let packet = BinaryProtocol.decode(combined) {
            remove(for: centralID)
            return .decoded(packet: packet, metadata: metadata)
        }

        guard combined.count <= capBytes else {
            remove(for: centralID)
            return .oversized(metadata: metadata)
        }

        if buffersByCentralID[centralID] == nil {
            let cap = max(1, maxTrackedCentrals)
            while buffersByCentralID.count >= cap, !centralOrder.isEmpty {
                let oldest = centralOrder.removeFirst()
                buffersByCentralID.removeValue(forKey: oldest)
            }
            centralOrder.append(centralID)
        }
        buffersByCentralID[centralID] = combined
        return .waiting(metadata: metadata)
    }

    /// Cheap wire-header length pre-check so multi-chunk long writes avoid
    /// running `BinaryProtocol.decode` and PKCS#7 unpadding on incomplete frames.
    private static func hasCompleteFrame(_ data: Data) -> Bool {
        guard case .length(let required) = BinaryProtocol.expectedFrameLength(for: data) else {
            return false
        }
        return data.count >= required
    }
}
