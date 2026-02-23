import XCTest
@testable import bitchat

final class PrivateMessagePacketTests: XCTestCase {
	func testEncodeDecodeSupportsLargeContent() throws {
		let longContent = String(repeating: "A", count: 1024)
		let packet = PrivateMessagePacket(messageID: "msg-123", content: longContent)

		let encoded = try XCTUnwrap(packet.encode())
		let decoded = try XCTUnwrap(PrivateMessagePacket.decode(from: encoded))

		XCTAssertEqual(decoded.messageID, "msg-123")
		XCTAssertEqual(decoded.content, longContent)
	}

	func testEncodeDecodeContentExactly255Bytes() throws {
		let content = String(repeating: "B", count: 255)
		let packet = PrivateMessagePacket(messageID: "msg-255", content: content)

		let encoded = try XCTUnwrap(packet.encode())
		let decoded = try XCTUnwrap(PrivateMessagePacket.decode(from: encoded))

		XCTAssertEqual(decoded.content.count, 255)
		XCTAssertEqual(decoded.content, content)
	}

	func testEncodeRejectsOversizedContent() {
		let oversizedContent = String(repeating: "C", count: 70_000)
		let packet = PrivateMessagePacket(messageID: "msg-oversize", content: oversizedContent)

		XCTAssertNil(packet.encode())
	}

	func testEncodeRejectsOversizedMessageID() {
		let longID = String(repeating: "x", count: 256)
		let packet = PrivateMessagePacket(messageID: longID, content: "ok")

		XCTAssertNil(packet.encode())
	}
}
