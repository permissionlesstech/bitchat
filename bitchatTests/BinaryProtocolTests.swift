//
// BinaryProtocolTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class BinaryProtocolTests: XCTestCase {
    
    func testPacketEncodingDecoding() {
        // Test basic packet
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data("testuser".utf8),
            recipientID: Data("recipient".utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("Hello, World!".utf8),
            signature: nil,
            ttl: 5
        )
        
        // Encode
        guard let encoded = packet.toBinaryData() else {
            XCTFail("Failed to encode packet")
            return
        }
        
        // Decode
        guard let decoded = BitchatPacket.from(encoded) else {
            XCTFail("Failed to decode packet")
            return
        }
        
        // Verify
        XCTAssertEqual(decoded.version, packet.version)
        XCTAssertEqual(decoded.type, packet.type)
        XCTAssertEqual(decoded.ttl, packet.ttl)
        XCTAssertEqual(decoded.timestamp, packet.timestamp)
        XCTAssertEqual(decoded.payload, packet.payload)
    }
    
    func testBroadcastPacket() {
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data("sender".utf8),
            recipientID: SpecialRecipients.broadcast,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("Broadcast message".utf8),
            signature: nil,
            ttl: 3
        )
        
        guard let encoded = packet.toBinaryData() else {
            XCTFail("Failed to encode broadcast packet")
            return
        }
        
        guard let decoded = BitchatPacket.from(encoded) else {
            XCTFail("Failed to decode broadcast packet")
            return
        }
        
        // Verify broadcast recipient
        XCTAssertEqual(decoded.recipientID, SpecialRecipients.broadcast)
    }
    
    func testPacketWithSignature() {
        let signature = Data(repeating: 0xAB, count: 64)
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data("sender".utf8),
            recipientID: Data("recipient".utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("Signed message".utf8),
            signature: signature,
            ttl: 5
        )
        
        guard let encoded = packet.toBinaryData() else {
            XCTFail("Failed to encode signed packet")
            return
        }
        
        guard let decoded = BitchatPacket.from(encoded) else {
            XCTFail("Failed to decode signed packet")
            return
        }
        
        XCTAssertNotNil(decoded.signature)
        XCTAssertEqual(decoded.signature, signature)
    }
    
    func testInvalidPacketHandling() {
        // Test empty data
        XCTAssertNil(BitchatPacket.from(Data()))
        
        // Test truncated data
        let truncated = Data(repeating: 0, count: 10)
        XCTAssertNil(BitchatPacket.from(truncated))
        
        // Test invalid version
        var invalidVersion = Data(repeating: 0, count: 100)
        invalidVersion[0] = 99 // Invalid version
        XCTAssertNil(BitchatPacket.from(invalidVersion))
    }
}