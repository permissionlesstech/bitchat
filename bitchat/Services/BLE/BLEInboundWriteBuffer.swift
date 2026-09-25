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
    private var lastModifiedByCentralID: [String: Date] = [:]

    mutating func removeAll() {
        buffersByCentralID.removeAll()
        lastModifiedByCentralID.removeAll()
    }

    /// Discards one subscribed central's partial write buffer. iOS centrals send
    /// each write frame via write-without-response; a buffer left behind stems
    /// from a write that failed to decode (e.g. truncated or corrupted packet)
    /// rather than a transfer cut off mid-way. Every other exit from `.waiting`
    /// (decode success, the oversized cap, `removeAll()`) already clears its entry.
    /// This runs for subscribed centrals when `didUnsubscribeFrom` fires to ensure
    /// decode failure residuals do not persist across reconnects.
    mutating func removeValue(forCentralID centralID: String) {
        buffersByCentralID.removeValue(forKey: centralID)
        lastModifiedByCentralID.removeValue(forKey: centralID)
    }

    /// Evicts entries untouched for longer than `maxAge` seconds.
    /// Covers centrals that write without subscribing or stay connected after unsubscribing.
    mutating func removeStaleBuffers(olderThan maxAge: TimeInterval, now: Date = Date()) {
        let staleIDs = lastModifiedByCentralID.compactMap { (id, date) -> String? in
            now.timeIntervalSince(date) >= maxAge ? id : nil
        }
        for id in staleIDs {
            buffersByCentralID.removeValue(forKey: id)
            lastModifiedByCentralID.removeValue(forKey: id)
        }
    }

    mutating func append(
        chunks: [BLEInboundWriteChunk],
        for centralID: String,
        capBytes: Int,
        now: Date = Date()
    ) -> AppendResult {
        removeStaleBuffers(olderThan: 60, now: now)
        var combined = buffersByCentralID[centralID] ?? Data()
        var appendedBytes = 0
        var offsets: [Int] = []

        for chunk in chunks where !chunk.data.isEmpty {
            offsets.append(chunk.offset)
            let end = chunk.offset + chunk.data.count

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
            removeValue(forCentralID: centralID)
            return .decoded(packet: packet, metadata: metadata)
        }

        guard combined.count <= capBytes else {
            removeValue(forCentralID: centralID)
            return .oversized(metadata: metadata)
        }

        buffersByCentralID[centralID] = combined
        lastModifiedByCentralID[centralID] = now
        return .waiting(metadata: metadata)
    }
}
