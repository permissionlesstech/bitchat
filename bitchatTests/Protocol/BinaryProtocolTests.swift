//
// BinaryProtocolTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

final class BinaryProtocolTests: XCTestCase {
    
    // MARK: - Basic Encoding/Decoding Tests
    
    func testBasicPacketEncodingDecoding() throws {
        let originalPacket = TestHelpers.createTestPacket()
        
        // Encode
        guard let encodedData = BinaryProtocol.encode(originalPacket) else {
            XCTFail("Failed to encode packet")
            return
        }
        
        // Decode
        guard let decodedPacket = BinaryProtocol.decode(encodedData) else {
            XCTFail("Failed to decode packet")
            return
        }
        
        // Verify
        XCTAssertEqual(decodedPacket.type, originalPacket.type)
        XCTAssertEqual(decodedPacket.ttl, originalPacket.ttl)
        XCTAssertEqual(decodedPacket.timestamp, originalPacket.timestamp)
        XCTAssertEqual(decodedPacket.payload, originalPacket.payload)
        
        // Sender ID should match (accounting for padding)
        let originalSenderID = originalPacket.senderID.prefix(BinaryProtocol.senderIDSize)
        let decodedSenderID = decodedPacket.senderID.trimmingNullBytes()
        XCTAssertEqual(decodedSenderID, originalSenderID)
    }
    
    func testPacketWithRecipient() throws {
        let recipientID = TestConstants.testPeerID2
        let packet = TestHelpers.createTestPacket(recipientID: recipientID)
        
        // Encode and decode
        guard let encodedData = BinaryProtocol.encode(packet),
              let decodedPacket = BinaryProtocol.decode(encodedData) else {
            XCTFail("Failed to encode/decode packet with recipient")
            return
        }
        
        // Verify recipient
        XCTAssertNotNil(decodedPacket.recipientID)
        let decodedRecipientID = decodedPacket.recipientID?.trimmingNullBytes()
        XCTAssertEqual(String(data: decodedRecipientID!, encoding: .utf8), recipientID)
    }
    
    func testPacketWithSignature() throws {
        let packet = TestHelpers.createTestPacket(
            signature: TestConstants.testSignature
        )
        
        // Encode and decode
        guard let encodedData = BinaryProtocol.encode(packet),
              let decodedPacket = BinaryProtocol.decode(encodedData) else {
            XCTFail("Failed to encode/decode packet with signature")
            return
        }
        
        // Verify signature
        XCTAssertNotNil(decodedPacket.signature)
        XCTAssertEqual(decodedPacket.signature, TestConstants.testSignature)
    }
    
    // MARK: - Compression Tests
    
    func testPayloadCompression() throws {
        // Create a large, compressible payload
        let repeatedString = String(repeating: "This is a test message. ", count: 50)
        let largePayload = repeatedString.data(using: .utf8)!
        
        let packet = TestHelpers.createTestPacket(payload: largePayload)
        
        // Encode (should compress)
        guard let encodedData = BinaryProtocol.encode(packet) else {
            XCTFail("Failed to encode packet with large payload")
            return
        }
        
        // The encoded size should be smaller than uncompressed due to compression
        let uncompressedSize = BinaryProtocol.headerSize + BinaryProtocol.senderIDSize + largePayload.count
        XCTAssertLessThan(encodedData.count, uncompressedSize)
        
        // Decode and verify
        guard let decodedPacket = BinaryProtocol.decode(encodedData) else {
            XCTFail("Failed to decode compressed packet")
            return
        }
        
        XCTAssertEqual(decodedPacket.payload, largePayload)
    }
    
    func testSmallPayloadNoCompression() throws {
        // Small payloads should not be compressed
        let smallPayload = "Hi".data(using: .utf8)!
        let packet = TestHelpers.createTestPacket(payload: smallPayload)
        
        guard let encodedData = BinaryProtocol.encode(packet),
              let decodedPacket = BinaryProtocol.decode(encodedData) else {
            XCTFail("Failed to encode/decode small packet")
            return
        }
        
        XCTAssertEqual(decodedPacket.payload, smallPayload)
    }
    
    // MARK: - Message Padding Tests
    
    func testMessagePadding() throws {
        let payloads = [
            "Short",
            "This is a medium length message for testing",
            TestConstants.testLongMessage
        ]
        
        var encodedSizes = Set<Int>()
        
        for payload in payloads {
            let packet = TestHelpers.createTestPacket(payload: payload.data(using: .utf8)!)
            
            guard let encodedData = BinaryProtocol.encode(packet) else {
                XCTFail("Failed to encode packet")
                continue
            }
            
            // Verify padding creates standard block sizes
            let blockSizes = [256, 512, 1024, 2048, 4096]
            XCTAssertTrue(blockSizes.contains(encodedData.count), "Encoded size \(encodedData.count) is not a standard block size")
            
            encodedSizes.insert(encodedData.count)
            
            // Verify decoding works
            guard let decodedPacket = BinaryProtocol.decode(encodedData) else {
                XCTFail("Failed to decode padded packet")
                continue
            }
            
            XCTAssertEqual(String(data: decodedPacket.payload, encoding: .utf8), payload)
        }
        
        // Different payload sizes should result in different padded sizes
        XCTAssertGreaterThan(encodedSizes.count, 1)
    }
    
    // MARK: - Message Encoding/Decoding Tests
    
    func testMessageEncodingDecoding() throws {
        let message = TestHelpers.createTestMessage()
        
        guard let payload = message.toBinaryPayload() else {
            XCTFail("Failed to encode message to binary")
            return
        }
        
        guard let decodedMessage = BitchatMessage.fromBinaryPayload(payload) else {
            XCTFail("Failed to decode message from binary")
            return
        }
        
        XCTAssertEqual(decodedMessage.content, message.content)
        XCTAssertEqual(decodedMessage.sender, message.sender)
        XCTAssertEqual(decodedMessage.senderPeerID, message.senderPeerID)
        XCTAssertEqual(decodedMessage.isPrivate, message.isPrivate)
        
        // Timestamp should be close (within 1 second due to conversion)
        let timeDiff = abs(decodedMessage.timestamp.timeIntervalSince(message.timestamp))
        XCTAssertLessThan(timeDiff, 1.0)
    }
    
    func testPrivateMessageEncoding() throws {
        let message = TestHelpers.createTestMessage(
            isPrivate: true,
            recipientNickname: TestConstants.testNickname2
        )
        
        guard let payload = message.toBinaryPayload(),
              let decodedMessage = BitchatMessage.fromBinaryPayload(payload) else {
            XCTFail("Failed to encode/decode private message")
            return
        }
        
        XCTAssertTrue(decodedMessage.isPrivate)
        XCTAssertEqual(decodedMessage.recipientNickname, TestConstants.testNickname2)
    }
    
    func testMessageWithMentions() throws {
        let mentions = [TestConstants.testNickname2, TestConstants.testNickname3]
        let message = TestHelpers.createTestMessage(mentions: mentions)
        
        guard let payload = message.toBinaryPayload(),
              let decodedMessage = BitchatMessage.fromBinaryPayload(payload) else {
            XCTFail("Failed to encode/decode message with mentions")
            return
        }
        
        XCTAssertEqual(decodedMessage.mentions, mentions)
    }
    
    func testRelayMessageEncoding() throws {
        let message = BitchatMessage(
            id: UUID().uuidString,
            sender: TestConstants.testNickname1,
            content: TestConstants.testMessage1,
            timestamp: Date(),
            isRelay: true,
            originalSender: TestConstants.testNickname3,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: TestConstants.testPeerID1,
            mentions: nil
        )
        
        guard let payload = message.toBinaryPayload(),
              let decodedMessage = BitchatMessage.fromBinaryPayload(payload) else {
            XCTFail("Failed to encode/decode relay message")
            return
        }
        
        XCTAssertTrue(decodedMessage.isRelay)
        XCTAssertEqual(decodedMessage.originalSender, TestConstants.testNickname3)
    }
    
    // MARK: - Edge Cases and Error Handling
    
    func testInvalidDataDecoding() {
        // Too small data
        let tooSmall = Data(repeating: 0, count: 5)
        XCTAssertNil(BinaryProtocol.decode(tooSmall))
        
        // Random data
        let random = TestHelpers.generateRandomData(length: 100)
        XCTAssertNil(BinaryProtocol.decode(random))
        
        // Corrupted header
        let packet = TestHelpers.createTestPacket()
        guard var encoded = BinaryProtocol.encode(packet) else {
            XCTFail("Failed to encode test packet")
            return
        }
        
        // Corrupt the version byte
        encoded[0] = 0xFF
        XCTAssertNil(BinaryProtocol.decode(encoded))
    }
    
    func testLargeMessageHandling() throws {
        // Test maximum size handling
        let largeContent = String(repeating: "X", count: 65535) // Max uint16
        let message = TestHelpers.createTestMessage(content: largeContent)
        
        guard let payload = message.toBinaryPayload(),
              let decodedMessage = BitchatMessage.fromBinaryPayload(payload) else {
            XCTFail("Failed to handle large message")
            return
        }
        
        XCTAssertEqual(decodedMessage.content, largeContent)
    }
    
    func testEmptyFieldsHandling() throws {
        // Test message with empty content
        let emptyMessage = TestHelpers.createTestMessage(content: "")
        
        guard let payload = emptyMessage.toBinaryPayload(),
              let decodedMessage = BitchatMessage.fromBinaryPayload(payload) else {
            XCTFail("Failed to handle empty message")
            return
        }
        
        XCTAssertEqual(decodedMessage.content, "")
    }
    
    // MARK: - Protocol Version Tests
    
    func testProtocolVersionHandling() throws {
        // Test with supported version (version is always 1 in init)
        let packet = TestHelpers.createTestPacket()
        
        guard let encoded = BinaryProtocol.encode(packet),
              let decoded = BinaryProtocol.decode(encoded) else {
            XCTFail("Failed to encode/decode packet with version")
            return
        }
        
        XCTAssertEqual(decoded.version, 1)
    }
    
    func testUnsupportedProtocolVersion() throws {
        // Create packet data with unsupported version
        let packet = TestHelpers.createTestPacket()
        
        guard var encoded = BinaryProtocol.encode(packet) else {
            XCTFail("Failed to encode packet")
            return
        }
        
        // Manually change version byte to unsupported value
        encoded[0] = 99 // Unsupported version
        
        // Should fail to decode
        XCTAssertNil(BinaryProtocol.decode(encoded))
    }
}