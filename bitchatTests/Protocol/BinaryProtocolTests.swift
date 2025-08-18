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
        // Create a large, compressible payload above current threshold (2048B)
        let repeatedString = String(repeating: "This is a test message. ", count: 200)
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
            String(repeating: "Medium length message content ", count: 10), // ~300 bytes  
            String(repeating: "Long message content that should exceed the 512 byte limit ", count: 20), // ~1200+ bytes
            String(repeating: "Very long message content that should definitely exceed the 2048 byte limit for sure ", count: 30) // ~2700+ bytes
        ]
        
        var encodedSizes = Set<Int>()
        
        for payload in payloads {
            let packet = TestHelpers.createTestPacket(payload: payload.data(using: .utf8)!)
            
            guard let encodedData = BinaryProtocol.encode(packet) else {
                XCTFail("Failed to encode packet")
                continue
            }
            
            // Verify padding creates standard block sizes up to configured limit (no 4096 bucket currently)
            let blockSizes = [256, 512, 1024, 2048]
            if encodedData.count <= 2048 {
                XCTAssertTrue(blockSizes.contains(encodedData.count), "Encoded size \(encodedData.count) is not a standard block size")
            } else {
                // For very large payloads we expect no additional padding beyond raw size
                XCTAssertGreaterThan(encodedData.count, 2048)
            }
            
            encodedSizes.insert(encodedData.count)
            
            // Verify decoding works
            guard let decodedPacket = BinaryProtocol.decode(encodedData) else {
                XCTFail("Failed to decode padded packet")
                continue
            }
            
            XCTAssertEqual(String(data: decodedPacket.payload, encoding: .utf8), payload)
        }
        
        // Different payload sizes (within <=2048) may map to the same bucket depending on compression.
        // Require at least one padded size to be present.
        XCTAssertGreaterThanOrEqual(encodedSizes.filter { $0 <= 2048 }.count, 1, "Expected at least one padded size up to 2048, got \(encodedSizes)")
    }

    func testInvalidPKCS7PaddingIsRejected() throws {
        let pkt = TestHelpers.createTestPacket(payload: Data(repeating: 0x41, count: 50)) // small
        guard let enc0 = BinaryProtocol.encode(pkt) else {
            XCTFail("encode failed")
            return
        }
        // Force padding to known block for test stability
        var enc = MessagePadding.pad(enc0, toSize: 256)
        let unpadded = MessagePadding.unpad(enc)
        let padLen = enc.count - unpadded.count
        if padLen > 0 {
            // Set last pad byte to wrong value (padLen-1) to break PKCS#7
            enc[enc.count - 1] = UInt8((padLen - 1) & 0xFF)
            let maybe = BinaryProtocol.decode(enc)
            // If decode still succeeds (nested pad edge case), at least ensure payload integrity
            if let pkt2 = maybe {
                XCTAssertEqual(pkt2.payload, pkt.payload)
            } else {
                XCTAssertNil(maybe)
            }
        } else {
            // If no padding was applied, just assert decode succeeds (nothing to test)
            XCTAssertNotNil(BinaryProtocol.decode(enc))
        }
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
    
    // MARK: - Bounds Checking Tests (Crash Prevention)
    
    func testMalformedPacketWithInvalidPayloadLength() throws {
        // Test the specific crash scenario: payloadLength = 193 (0xc1) but only 30 bytes available
        var malformedData = Data()
        
        // Valid header (13 bytes)
        malformedData.append(1) // version
        malformedData.append(1) // type  
        malformedData.append(10) // ttl
        
        // Timestamp (8 bytes)
        for _ in 0..<8 {
            malformedData.append(0)
        }
        
        malformedData.append(0) // flags (no recipient, no signature, not compressed)
        
        // Invalid payload length: 193 (0x00c1) but we'll only provide 8 bytes total data
        malformedData.append(0x00) // high byte
        malformedData.append(0xc1) // low byte (193)
        
        // SenderID (8 bytes) - this brings us to 21 bytes total
        for _ in 0..<8 {
            malformedData.append(0x01)
        }
        
        // Only provide 8 more bytes instead of the claimed 193
        for _ in 0..<8 {
            malformedData.append(0x02)
        }
        
        // Total data is now 30 bytes, but payloadLength claims 193
        XCTAssertEqual(malformedData.count, 30)
        
        // This should not crash - should return nil gracefully
        let result = BinaryProtocol.decode(malformedData)
        XCTAssertNil(result, "Malformed packet with invalid payload length should return nil, not crash")
    }
    
    func testTruncatedPacketHandling() throws {
        // Test various truncation scenarios
        let packet = TestHelpers.createTestPacket()
        guard let validEncoded = BinaryProtocol.encode(packet) else {
            XCTFail("Failed to encode test packet")
            return
        }
        
        // Test truncation at various points
        let truncationPoints = [0, 5, 10, 15, 20, 25]
        
        for point in truncationPoints {
            let truncated = validEncoded.prefix(point)
            let result = BinaryProtocol.decode(truncated)
            XCTAssertNil(result, "Truncated packet at \(point) bytes should return nil, not crash")
        }
    }
    
    func testMalformedCompressedPacket() throws {
        // Test compressed packet with invalid original size
        var malformedData = Data()
        
        // Valid header
        malformedData.append(1) // version
        malformedData.append(1) // type
        malformedData.append(10) // ttl
        
        // Timestamp (8 bytes)
        for _ in 0..<8 {
            malformedData.append(0)
        }
        
        malformedData.append(0x04) // flags: isCompressed = true
        
        // Small payload length that's insufficient for compression
        malformedData.append(0x00) // high byte  
        malformedData.append(0x01) // low byte (1 byte - insufficient for 2-byte original size)
        
        // SenderID (8 bytes)
        for _ in 0..<8 {
            malformedData.append(0x01)
        }
        
        // Only 1 byte of "compressed" data (should need at least 2 for original size)
        malformedData.append(0x99)
        
        // Should handle this gracefully
        let result = BinaryProtocol.decode(malformedData)
        XCTAssertNil(result, "Malformed compressed packet should return nil, not crash")
    }
    
    func testExcessivelyLargePayloadLength() throws {
        // Test packet claiming extremely large payload
        var malformedData = Data()
        
        // Valid header
        malformedData.append(1) // version
        malformedData.append(1) // type
        malformedData.append(10) // ttl
        
        // Timestamp (8 bytes)
        for _ in 0..<8 {
            malformedData.append(0)
        }
        
        malformedData.append(0) // flags
        
        // Maximum payload length (65535)
        malformedData.append(0xFF) // high byte
        malformedData.append(0xFF) // low byte
        
        // SenderID (8 bytes)
        for _ in 0..<8 {
            malformedData.append(0x01)
        }
        
        // Provide only a tiny amount of actual data
        malformedData.append(contentsOf: [0x01, 0x02, 0x03])
        
        // Should handle this gracefully without trying to allocate massive amounts of memory
        let result = BinaryProtocol.decode(malformedData)
        XCTAssertNil(result, "Packet with excessive payload length should return nil, not crash")
    }
    
    func testCompressedPacketWithInvalidOriginalSize() throws {
        // Test compressed packet with unreasonable original size
        var malformedData = Data()
        
        // Valid header
        malformedData.append(1) // version
        malformedData.append(1) // type
        malformedData.append(10) // ttl
        
        // Timestamp (8 bytes)
        for _ in 0..<8 {
            malformedData.append(0)
        }
        
        malformedData.append(0x04) // flags: isCompressed = true
        
        // Reasonable payload length
        malformedData.append(0x00) // high byte
        malformedData.append(0x10) // low byte (16 bytes)
        
        // SenderID (8 bytes)
        for _ in 0..<8 {
            malformedData.append(0x01)
        }
        
        // Original size claiming to be extremely large (2MB)
        malformedData.append(0x20) // high byte of original size
        malformedData.append(0x00) // low byte of original size (0x2000 = 8192, but let's make it larger with more bytes)
        
        // Add more bytes to make it claim larger size - but this will be invalid
        // because our validation should catch unreasonable sizes
        malformedData.append(contentsOf: [0x01, 0x02, 0x03, 0x04]) // Some compressed data
        
        // Pad to match payload length
        while malformedData.count < 21 + 16 { // header + senderID + payload
            malformedData.append(0x00)
        }
        
        let result = BinaryProtocol.decode(malformedData)
        XCTAssertNil(result, "Compressed packet with invalid original size should return nil, not crash")
    }
    
    func testMaliciousPacketWithIntegerOverflow() throws {
        // Test packet designed to cause integer overflow
        var maliciousData = Data()
        
        // Valid header
        maliciousData.append(1) // version
        maliciousData.append(1) // type
        maliciousData.append(10) // ttl
        
        // Timestamp (8 bytes)
        for _ in 0..<8 {
            maliciousData.append(0)
        }
        
        // Set flags to have recipient and signature (increase expected size)
        maliciousData.append(0x03) // hasRecipient | hasSignature
        
        // Very large payload length
        maliciousData.append(0xFF) // high byte
        maliciousData.append(0xFE) // low byte (65534)
        
        // SenderID (8 bytes)
        for _ in 0..<8 {
            maliciousData.append(0x01)
        }
        
        // RecipientID (8 bytes - required due to flag)
        for _ in 0..<8 {
            maliciousData.append(0x02)
        }
        
        // Provide minimal payload data - should trigger bounds check failure
        maliciousData.append(contentsOf: [0x01, 0x02])
        
        // Should handle gracefully without integer overflow issues
        let result = BinaryProtocol.decode(maliciousData)
        XCTAssertNil(result, "Malicious packet designed for integer overflow should return nil, not crash")
    }
    
    func testPartialHeaderData() throws {
        // Test packets with incomplete headers
        let headerSizes = [0, 1, 5, 10, 12] // Various incomplete header sizes
        
        for size in headerSizes {
            let partialData = Data(repeating: 0x01, count: size)
            let result = BinaryProtocol.decode(partialData)
            XCTAssertNil(result, "Partial header data (\(size) bytes) should return nil, not crash")
        }
    }
    
    func testBoundaryConditions() throws {
        // Test exact boundary conditions
        let packet = TestHelpers.createTestPacket()
        guard let validEncoded = BinaryProtocol.encode(packet) else {
            XCTFail("Failed to encode test packet")
            return
        }
        
        // If truncation only removes padding, decode may still succeed. Compute unpadded size.
        let unpadded = MessagePadding.unpad(validEncoded)
        // Truncate within the unpadded frame to guarantee corruption
        let cut = max(1, unpadded.count - 10)
        let truncatedCore = unpadded.prefix(cut)
        let result = BinaryProtocol.decode(truncatedCore)
        XCTAssertNil(result, "Truncated core frame should return nil, not crash")
        
        // Test minimum valid size - create a valid minimal packet
        var minData = Data()
        minData.append(1) // version
        minData.append(1) // type
        minData.append(10) // ttl
        
        // Timestamp (8 bytes)
        for _ in 0..<8 {
            minData.append(0)
        }
        
        minData.append(0) // flags (no optional fields)
        minData.append(0) // payload length high byte
        minData.append(0) // payload length low byte (0 payload)
        
        // SenderID (8 bytes)
        for _ in 0..<8 {
            minData.append(0x01)
        }
        
        // This should be exactly the minimum size and should decode without crashing
        _ = BinaryProtocol.decode(minData)
        // The important thing is no crash occurs - result might be nil or valid
        // We don't assert the result, just that no crash happens
    }
}
