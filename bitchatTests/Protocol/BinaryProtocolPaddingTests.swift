//
// BinaryProtocolPaddingTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
//

import XCTest
@testable import bitchat

final class BinaryProtocolPaddingTests: XCTestCase {
    func test_padded_vs_unpadded_length() throws {
        // Use helper to create a small test packet
        let packet = TestHelpers.createTestPacket()
        guard let padded = BinaryProtocol.encode(packet, padding: true) else { return XCTFail("encode padded") }
        guard let unpadded = BinaryProtocol.encode(packet, padding: false) else { return XCTFail("encode unpadded") }
        XCTAssertGreaterThanOrEqual(padded.count, unpadded.count, "Padded frame should be >= unpadded")
    }

    func test_decode_padded_and_unpadded_round_trip() throws {
        let packet = TestHelpers.createTestPacket()
        // Padded
        guard let padded = BinaryProtocol.encode(packet, padding: true) else { return XCTFail("encode padded") }
        guard let dec1 = BinaryProtocol.decode(padded) else { return XCTFail("decode padded") }
        XCTAssertEqual(dec1.type, packet.type)
        XCTAssertEqual(dec1.payload, packet.payload)
        // Unpadded
        guard let unpadded = BinaryProtocol.encode(packet, padding: false) else { return XCTFail("encode unpadded") }
        guard let dec2 = BinaryProtocol.decode(unpadded) else { return XCTFail("decode unpadded") }
        XCTAssertEqual(dec2.type, packet.type)
        XCTAssertEqual(dec2.payload, packet.payload)
    }
}

