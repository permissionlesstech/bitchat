import Foundation
import Testing
@testable import bitchat

struct BLEOutboundWriteBufferTests {
    @Test
    func enqueueOrdersWritesByPriority() {
        var buffer = BLEOutboundWriteBuffer()
        let peerID = "peer-1"

        _ = buffer.enqueue(
            data: Data(repeating: 0x01, count: 4),
            for: peerID,
            priority: .fileTransfer,
            capBytes: 64
        )
        _ = buffer.enqueue(
            data: Data(repeating: 0x02, count: 4),
            for: peerID,
            priority: .high,
            capBytes: 64
        )
        _ = buffer.enqueue(
            data: Data(repeating: 0x03, count: 4),
            for: peerID,
            priority: .fragment(totalFragments: 2),
            capBytes: 64
        )

        let writes = buffer.takeAll(for: peerID)

        #expect(writes.map { Int($0.data.first ?? 0) } == [0x02, 0x03, 0x01])
    }

    @Test
    func enqueueTrimsLowestPriorityItemsToCap() {
        var buffer = BLEOutboundWriteBuffer()
        let peerID = "peer-1"

        _ = buffer.enqueue(data: Data(repeating: 0x01, count: 8), for: peerID, priority: .low, capBytes: 16)
        _ = buffer.enqueue(data: Data(repeating: 0x02, count: 8), for: peerID, priority: .fileTransfer, capBytes: 16)
        let result = buffer.enqueue(data: Data(repeating: 0x03, count: 8), for: peerID, priority: .high, capBytes: 16)

        if case let .enqueued(trimmedBytes, remainingBytes) = result {
            #expect(trimmedBytes == 8)
            #expect(remainingBytes == 16)
        } else {
            Issue.record("Expected buffered write to trim, not drop as oversized")
        }

        let writes = buffer.takeAll(for: peerID)

        #expect(writes.map { Int($0.data.first ?? 0) } == [0x03, 0x02])
    }

    @Test
    func enqueueRejectsOversizedSingleChunk() {
        var buffer = BLEOutboundWriteBuffer()

        let result = buffer.enqueue(
            data: Data(repeating: 0x01, count: 32),
            for: "peer-1",
            priority: .high,
            capBytes: 16
        )

        if case let .oversized(bytes) = result {
            #expect(bytes == 32)
        } else {
            Issue.record("Expected oversized write to be rejected")
        }

        #expect(buffer.peripheralIDs.isEmpty)
    }
}
