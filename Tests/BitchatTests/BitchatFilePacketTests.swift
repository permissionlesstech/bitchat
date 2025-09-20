import XCTest
@testable import bitchat

final class BitchatFilePacketTests: XCTestCase {
    func testRoundTripSmallImage() throws {
        let name = "cat.jpg"
        let mime = "image/jpeg"
        let bytes = Data(repeating: 0xAB, count: 1024)
        let pkt = BitchatFilePacket(fileName: name, fileSize: UInt64(bytes.count), mimeType: mime, content: bytes)
        let enc = try pkt.encode()
        let dec = try BitchatFilePacket.decode(enc)
        XCTAssertEqual(dec.fileName, name)
        XCTAssertEqual(dec.mimeType, mime)
        XCTAssertEqual(dec.content.count, bytes.count)
        XCTAssertEqual(dec.content.prefix(16), bytes.prefix(16))
    }

    func testDecodeToleratesLegacy2ByteContentLen() throws {
        // Build a payload where CONTENT uses 2-byte length (legacy tolerance test)
        let name = "file.bin"
        let mime = "application/octet-stream"
        let body = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        var d = Data()
        // name TLV
        d.append(0x01)
        var nlen: UInt16 = UInt16(name.utf8.count).bigEndian
        withUnsafeBytes(of: &nlen) { d.append($0) }
        d.append(name.data(using: .utf8)!)
        // filesize TLV (len=4)
        d.append(0x02)
        var four: UInt16 = 4.bigEndian
        withUnsafeBytes(of: &four) { d.append($0) }
        var fsz = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &fsz) { d.append($0) }
        // mime TLV
        d.append(0x03)
        var mlen: UInt16 = UInt16(mime.utf8.count).bigEndian
        withUnsafeBytes(of: &mlen) { d.append($0) }
        d.append(mime.data(using: .utf8)!)
        // content TLV (legacy 2-byte len variant for tolerance)
        d.append(0x04)
        var blen: UInt16 = UInt16(body.count).bigEndian
        withUnsafeBytes(of: &blen) { d.append($0) }
        d.append(body)
        let dec = try BitchatFilePacket.decode(d)
        XCTAssertEqual(dec.fileName, name)
        XCTAssertEqual(dec.content, body)
    }

    func testOversizeRejected() {
        let huge = Data(repeating: 0x00, count: NoiseSecurityConstants.maxMessageSize + 1)
        let pkt = BitchatFilePacket(fileName: "big.bin", fileSize: UInt64(huge.count), mimeType: "application/octet-stream", content: huge)
        XCTAssertThrowsError(try pkt.encode())
    }
}
