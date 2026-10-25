import BitFoundation
import Foundation
import Testing

// Empty stored blocks increase encoded size without changing decoded content.
enum RetainedPacketTestFixture {
    static func frame(
        type: MessageType = .message, sender: Data, recipient: Data? = nil,
        timestamp: UInt64, payload: Data, emptyBlocks: Int = 0
    ) -> Data {
        let size = UInt16(payload.count)
        var compressed = Data()
        for _ in 0..<emptyBlocks { compressed.append(contentsOf: [0, 0, 0, 255, 255]) }
        compressed.append(contentsOf: [1, UInt8(size & 255), UInt8(size >> 8), UInt8((~size) & 255), UInt8((~size) >> 8)])
        compressed.append(payload)
        var frame = Data([2, type.rawValue, 1])
        append(timestamp, width: 8, to: &frame)
        frame.append(4 | (recipient == nil ? 0 : 1))
        append(UInt64(compressed.count + 4), width: 4, to: &frame)
        frame.append(sender)
        if let recipient { frame.append(recipient) }
        append(UInt64(payload.count), width: 4, to: &frame)
        frame.append(compressed)
        return frame
    }

    static func packet(
        type: MessageType = .message, sender: Data, recipient: Data? = nil,
        timestamp: UInt64, payload: Data, emptyBlocks: Int = 0
    ) throws -> BitchatPacket {
        let bytes = frame(type: type, sender: sender, recipient: recipient,
            timestamp: timestamp, payload: payload, emptyBlocks: emptyBlocks)
        let decoded = try #require(BitchatPacket.from(bytes))
        #expect(decoded.payload == payload)
        return decoded
    }

    private static func append(_ value: UInt64, width: Int, to data: inout Data) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            data.append(UInt8((value >> shift) & 255))
        }
    }
}
