import XCTest
@testable import bitchat

final class BitchatFilePacketTests: XCTestCase {

    func testRoundTripPreservesFields() throws {
        let content = Data((0..<4096).map { UInt8($0 % 251) })
        let packet = BitchatFilePacket(
            fileName: "sample.jpg",
            fileSize: UInt64(content.count),
            mimeType: "image/jpeg",
            content: content
        )

        guard let encoded = packet.encode() else {
            return XCTFail("Failed to encode file packet")
        }
        guard let decoded = BitchatFilePacket.decode(encoded) else {
            return XCTFail("Failed to decode file packet")
        }

        XCTAssertEqual(decoded.fileName, packet.fileName)
        XCTAssertEqual(decoded.fileSize, packet.fileSize)
        XCTAssertEqual(decoded.mimeType, packet.mimeType)
        XCTAssertEqual(decoded.content, packet.content)
    }

    func testDecodeFallsBackToContentSizeWhenFileSizeMissing() throws {
        let content = Data(repeating: 0x7F, count: 1024)
        let packet = BitchatFilePacket(
            fileName: nil,
            fileSize: nil,
            mimeType: nil,
            content: content
        )

        guard let encoded = packet.encode() else {
            return XCTFail("Failed to encode file packet")
        }
        guard let decoded = BitchatFilePacket.decode(encoded) else {
            return XCTFail("Failed to decode file packet")
        }

        XCTAssertEqual(decoded.fileSize, UInt64(content.count))
        XCTAssertEqual(decoded.content, content)
    }

    func testDecodeSupportsLegacyEightByteFileSizeTLV() throws {
        let content = Data([0x01, 0x02, 0x03, 0x04])
        var data = Data()

        data.append(0x02)
        data.append(contentsOf: [0x00, 0x08])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00])
        data.append(0x04)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x04])
        data.append(content)

        let decoded = try XCTUnwrap(BitchatFilePacket.decode(data))
        XCTAssertEqual(decoded.fileSize, 256)
        XCTAssertEqual(decoded.content, content)
    }

    func testDecodeUsesContentCountWhenFileSizeTLVIsMissing() throws {
        let content = Data([0xAA, 0xBB, 0xCC])
        var data = Data()

        data.append(0x04)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x03])
        data.append(content)

        let decoded = try XCTUnwrap(BitchatFilePacket.decode(data))
        XCTAssertEqual(decoded.fileSize, UInt64(content.count))
        XCTAssertEqual(decoded.content, content)
    }
}
