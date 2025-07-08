//
// BinaryProtocolSecurityTests.swift
// bitchat
//
// Unit tests for BinaryProtocol security improvements
// Author: Unit 221B
//

import XCTest
@testable import bitchat

class BinaryProtocolSecurityTests: XCTestCase {
    
    // MARK: - Buffer Overflow Tests
    
    func testMalformedHeaderTooShort() {
        // Test with data shorter than header size
        let malformedData = Data([0x01, 0x02, 0x03, 0x04]) // Only 4 bytes
        let packet = BinaryProtocol.decode(malformedData)
        XCTAssertNil(packet, "Should return nil for data shorter than header")
    }
    
    func testInvalidPayloadLength() {
        // Create header with payload length that exceeds actual data
        var data = Data()
        data.append(0x01) // version
        data.append(0x01) // type
        data.append(0x05) // ttl
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]) // timestamp
        data.append(0x00) // flags
        data.append(contentsOf: [0xFF, 0xFF]) // payload length = 65535 (exceeds actual data)
        data.append(contentsOf: Data(repeating: 0x41, count: 8)) // senderID
        
        let packet = BinaryProtocol.decode(data)
        XCTAssertNil(packet, "Should return nil for invalid payload length")
    }
    
    func testPayloadExceedsMaxSize() {
        // Test payload length exceeding maximum allowed size
        var data = Data()
        data.append(0x01) // version
        data.append(0x01) // type
        data.append(0x05) // ttl
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]) // timestamp
        data.append(0x00) // flags
        // Set payload length to exceed max (1MB + 1)
        let oversizeLength = UInt16((BinaryProtocol.maxPayloadSize + 1) & 0xFFFF)
        data.append(UInt8((oversizeLength >> 8) & 0xFF))
        data.append(UInt8(oversizeLength & 0xFF))
        data.append(contentsOf: Data(repeating: 0x41, count: 8)) // senderID
        
        let packet = BinaryProtocol.decode(data)
        XCTAssertNil(packet, "Should return nil for payload exceeding max size")
    }
    
    func testCompressedPayloadInvalidOriginalSize() {
        // Test compressed payload with invalid original size
        var data = Data()
        data.append(0x01) // version
        data.append(0x01) // type
        data.append(0x05) // ttl
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]) // timestamp
        data.append(BinaryProtocol.Flags.isCompressed) // flags with compression
        data.append(contentsOf: [0x00, 0x04]) // payload length = 4 bytes
        data.append(contentsOf: Data(repeating: 0x41, count: 8)) // senderID
        // Compressed payload with invalid original size
        data.append(contentsOf: [0xFF, 0xFF]) // Original size exceeds max
        data.append(contentsOf: [0x00, 0x00]) // Empty compressed data
        
        let packet = BinaryProtocol.decode(data)
        XCTAssertNil(packet, "Should return nil for invalid original size in compressed payload")
    }
    
    // MARK: - Message Binary Protocol Tests
    
    func testMessageMalformedStringLength() {
        // Test message with string length exceeding data
        var data = Data()
        data.append(0x00) // flags
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]) // timestamp
        data.append(0xFF) // ID length = 255 (but no data follows)
        
        let message = BitchatMessage.fromBinaryPayload(data)
        XCTAssertNil(message, "Should return nil for string length exceeding data")
    }
    
    func testMessageExcessiveMentionsCount() {
        // Create valid message data up to mentions
        var data = Data()
        data.append(0x20) // flags with mentions
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]) // timestamp
        data.append(0x04) // ID length
        data.append(contentsOf: "test".data(using: .utf8)!) // ID
        data.append(0x04) // sender length
        data.append(contentsOf: "user".data(using: .utf8)!) // sender
        data.append(contentsOf: [0x00, 0x05]) // content length
        data.append(contentsOf: "hello".data(using: .utf8)!) // content
        data.append(0xFF) // mentions count = 255 (exceeds max)
        
        let message = BitchatMessage.fromBinaryPayload(data)
        XCTAssertNil(message, "Should return nil for excessive mentions count")
    }
    
    func testMessageNegativeContentLength() {
        // Test with content length that would be negative when interpreted
        var data = Data()
        data.append(0x00) // flags
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]) // timestamp
        data.append(0x02) // ID length
        data.append(contentsOf: "id".data(using: .utf8)!) // ID
        data.append(0x04) // sender length
        data.append(contentsOf: "user".data(using: .utf8)!) // sender
        data.append(contentsOf: [0x80, 0x00]) // content length with high bit set
        
        let message = BitchatMessage.fromBinaryPayload(data)
        XCTAssertNil(message, "Should handle potential negative content length")
    }
    
    func testMessageChannelLengthExceedsMax() {
        // Create message with channel flag and excessive channel length
        var data = Data()
        data.append(0x40) // flags with channel
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]) // timestamp
        data.append(0x02) // ID length
        data.append(contentsOf: "id".data(using: .utf8)!) // ID
        data.append(0x04) // sender length
        data.append(contentsOf: "user".data(using: .utf8)!) // sender
        data.append(contentsOf: [0x00, 0x05]) // content length
        data.append(contentsOf: "hello".data(using: .utf8)!) // content
        data.append(0xFF) // channel length = 255 (at max)
        data.append(contentsOf: Data(repeating: 0x41, count: 256)) // Excessive channel data
        
        let message = BitchatMessage.fromBinaryPayload(data)
        XCTAssertNil(message, "Should return nil for excessive channel data")
    }
    
    // MARK: - Valid Data Tests
    
    func testValidPacketEncoding() {
        // Test encoding and decoding a valid packet
        let originalPacket = BitchatPacket(
            type: 0x01,
            senderID: Data("12345678".utf8),
            recipientID: Data("87654321".utf8),
            timestamp: 1234567890,
            payload: Data("Hello, World!".utf8),
            signature: nil,
            ttl: 5
        )
        
        guard let encoded = BinaryProtocol.encode(originalPacket) else {
            XCTFail("Failed to encode valid packet")
            return
        }
        
        guard let decoded = BinaryProtocol.decode(encoded) else {
            XCTFail("Failed to decode valid packet")
            return
        }
        
        XCTAssertEqual(decoded.type, originalPacket.type)
        XCTAssertEqual(decoded.ttl, originalPacket.ttl)
        XCTAssertEqual(decoded.timestamp, originalPacket.timestamp)
        XCTAssertEqual(decoded.payload, originalPacket.payload)
    }
    
    func testValidMessageEncoding() {
        // Test encoding and decoding a valid message
        let originalMessage = BitchatMessage(
            id: "msg123",
            sender: "testuser",
            content: "Hello, this is a test message!",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "recipient",
            senderPeerID: "peer123",
            mentions: ["user1", "user2"],
            channel: "#test",
            encryptedContent: nil,
            isEncrypted: false
        )
        
        guard let encoded = originalMessage.toBinaryPayload() else {
            XCTFail("Failed to encode valid message")
            return
        }
        
        guard let decoded = BitchatMessage.fromBinaryPayload(encoded) else {
            XCTFail("Failed to decode valid message")
            return
        }
        
        XCTAssertEqual(decoded.id, originalMessage.id)
        XCTAssertEqual(decoded.sender, originalMessage.sender)
        XCTAssertEqual(decoded.content, originalMessage.content)
        XCTAssertEqual(decoded.isPrivate, originalMessage.isPrivate)
        XCTAssertEqual(decoded.recipientNickname, originalMessage.recipientNickname)
        XCTAssertEqual(decoded.senderPeerID, originalMessage.senderPeerID)
        XCTAssertEqual(decoded.mentions, originalMessage.mentions)
        XCTAssertEqual(decoded.channel, originalMessage.channel)
    }
    
    // MARK: - Edge Case Tests
    
    func testEmptyPayload() {
        let packet = BitchatPacket(
            type: 0x01,
            senderID: Data("12345678".utf8),
            recipientID: nil,
            timestamp: 1234567890,
            payload: Data(), // Empty payload
            signature: nil,
            ttl: 5
        )
        
        guard let encoded = BinaryProtocol.encode(packet) else {
            XCTFail("Failed to encode packet with empty payload")
            return
        }
        
        guard let decoded = BinaryProtocol.decode(encoded) else {
            XCTFail("Failed to decode packet with empty payload")
            return
        }
        
        XCTAssertEqual(decoded.payload.count, 0)
    }
    
    func testMaxSizeFields() {
        // Test with maximum allowed field sizes
        let longString = String(repeating: "A", count: 255)
        let message = BitchatMessage(
            id: longString,
            sender: longString,
            content: String(repeating: "B", count: 65535),
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: nil,
            mentions: nil,
            channel: nil,
            encryptedContent: nil,
            isEncrypted: false
        )
        
        guard let encoded = message.toBinaryPayload() else {
            XCTFail("Failed to encode message with max size fields")
            return
        }
        
        guard let decoded = BitchatMessage.fromBinaryPayload(encoded) else {
            XCTFail("Failed to decode message with max size fields")
            return
        }
        
        XCTAssertEqual(decoded.id, message.id)
        XCTAssertEqual(decoded.sender, message.sender)
        XCTAssertEqual(decoded.content, message.content)
    }
    
    func testBoundaryConditions() {
        // Test exact boundary conditions
        var data = Data()
        data.append(0x01) // version
        data.append(0x01) // type
        data.append(0x05) // ttl
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]) // timestamp
        data.append(0x00) // flags
        data.append(contentsOf: [0x00, 0x00]) // payload length = 0
        data.append(contentsOf: Data(repeating: 0x41, count: 8)) // senderID
        
        let packet = BinaryProtocol.decode(data)
        XCTAssertNotNil(packet, "Should decode packet at exact boundary")
        XCTAssertEqual(packet?.payload.count, 0)
    }
}