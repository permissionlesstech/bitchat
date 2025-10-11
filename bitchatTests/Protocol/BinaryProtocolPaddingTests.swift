//
// BinaryProtocolPaddingTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
//

import Testing
@testable import bitchat

struct BinaryProtocolPaddingTests {
    @Test func padded_vs_unpadded_length() throws {
        // Use helper to create a small test packet
        let packet = TestHelpers.createTestPacket()
        let padded = try #require(BinaryProtocol.encode(packet, padding: true), "encode padded")
        let unpadded = try #require(BinaryProtocol.encode(packet, padding: false), "encode unpadded")
        #expect(padded.count >= unpadded.count, "Padded frame should be >= unpadded")
    }

    @Test func decode_padded_and_unpadded_round_trip() throws {
        let packet = TestHelpers.createTestPacket()

        let padded = try #require(BinaryProtocol.encode(packet, padding: true), "encode padded")
        let dec1 = try #require(BinaryProtocol.decode(padded), "decode padded")
        #expect(dec1.type == packet.type)
        #expect(dec1.payload == packet.payload)

        let unpadded = try #require(BinaryProtocol.encode(packet, padding: false), "encode unpadded")
        let dec2 = try #require(BinaryProtocol.decode(unpadded), "decode unpadded")
        #expect(dec2.type == packet.type)
        #expect(dec2.payload == packet.payload)
    }
}
