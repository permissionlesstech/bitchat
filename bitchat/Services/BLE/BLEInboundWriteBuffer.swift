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
        case invalid(metadata: BLEInboundWriteAppendMetadata)
    }

    private var buffersByCentralID: [String: Data] = [:]

    mutating func removeAll() {
        buffersByCentralID.removeAll()
    }

    mutating func append(
        chunks: [BLEInboundWriteChunk],
        for centralID: String,
        capBytes: Int
    ) -> AppendResult {
        var combined = buffersByCentralID[centralID] ?? Data()
        var appendedBytes = 0
        var offsets: [Int] = []
        var lastEnd = 0

        for chunk in chunks where !chunk.data.isEmpty {
            offsets.append(chunk.offset)

            // Reject malformed writes before touching the buffer: a negative
            // offset traps `Data.replaceSubrange`, and non-monotonic or
            // overlapping offsets corrupt previously written bytes.
            guard chunk.offset >= 0, chunk.offset >= lastEnd else {
                let metadata = BLEInboundWriteAppendMetadata(
                    accumulatedBytes: combined.count,
                    appendedBytes: appendedBytes,
                    offsets: offsets,
                    packetType: combined.count >= 2 ? combined[1] : nil
                )
                buffersByCentralID.removeValue(forKey: centralID)
                return .invalid(metadata: metadata)
            }

            let end = chunk.offset + chunk.data.count
            lastEnd = end

            if combined.count < end {
                combined.append(Data(repeating: 0, count: end - combined.count))
            }

            combined.replaceSubrange(chunk.offset..<end, with: chunk.data)
            appendedBytes += chunk.data.count
        }

        let metadata = BLEInboundWriteAppendMetadata(
            accumulatedBytes: combined.count,
            appendedBytes: appendedBytes,
            offsets: offsets,
            packetType: combined.count >= 2 ? combined[1] : nil
        )

        if let packet = BinaryProtocol.decode(combined) {
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
}
