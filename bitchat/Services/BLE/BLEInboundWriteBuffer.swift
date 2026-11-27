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
    enum AppendResult {
        case decoded(packet: BitchatPacket, metadata: BLEInboundWriteAppendMetadata)
        case waiting(metadata: BLEInboundWriteAppendMetadata)
        case oversized(metadata: BLEInboundWriteAppendMetadata)
    }

    private var buffersByCentralID: [String: Data] = [:]

    mutating func removeAll() {
        buffersByCentralID.removeAll()
    }

    mutating func remove(for centralID: String) {
        buffersByCentralID.removeValue(forKey: centralID)
    }

    mutating func append(
        chunks: [BLEInboundWriteChunk],
        for centralID: String,
        capBytes: Int
    ) -> AppendResult {
        var combined = buffersByCentralID[centralID] ?? Data()
        var appendedBytes = 0
        var offsets: [Int] = []
        offsets.reserveCapacity(chunks.count)

        for chunk in chunks where !chunk.data.isEmpty {
            offsets.append(chunk.offset)
            let end = chunk.offset + chunk.data.count

            if chunk.offset == combined.count {
                if combined.isEmpty {
                    combined = chunk.data
                } else {
                    combined.append(chunk.data)
                }
            } else {
                if combined.count < end {
                    combined.append(Data(repeating: 0, count: end - combined.count))
                }
                combined.replaceSubrange(chunk.offset..<end, with: chunk.data)
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
            buffersByCentralID.removeValue(forKey: centralID)
            return .decoded(packet: packet, metadata: metadata)
        }

        guard combined.count <= capBytes else {
            buffersByCentralID.removeValue(forKey: centralID)
            return .oversized(metadata: metadata)
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
