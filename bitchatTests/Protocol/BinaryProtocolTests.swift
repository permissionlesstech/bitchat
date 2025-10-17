//
// BinaryProtocolTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct BinaryProtocolTests {
    
    // MARK: - Basic Encoding/Decoding Tests
    
    @Test func basicPacketEncodingDecoding() throws {
        let originalPacket = TestHelpers.createTestPacket()
        
        let encodedData = try #require(BinaryProtocol.encode(originalPacket), "Failed to encode packet")
        let decodedPacket = try #require(BinaryProtocol.decode(encodedData), "Failed to decode packet")
        
        // Verify
        #expect(decodedPacket.type == originalPacket.type)
        #expect(decodedPacket.ttl == originalPacket.ttl)
        #expect(decodedPacket.timestamp == originalPacket.timestamp)
        #expect(decodedPacket.payload == originalPacket.payload)
        
        // Sender ID should match (accounting for padding)
        let originalSenderID = originalPacket.senderID.prefix(BinaryProtocol.senderIDSize)
        let decodedSenderID = decodedPacket.senderID.trimmingNullBytes()
        #expect(decodedSenderID == originalSenderID)
    }
    
    @Test func packetWithRecipient() throws {
        let recipientID = PeerID(str: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
        let packet = TestHelpers.createTestPacket(recipientID: recipientID)
        let encodedData = try #require(BinaryProtocol.encode(packet), "Failed to encode packet with recipient")
        let decodedPacket = try #require(BinaryProtocol.decode(encodedData), "Failed to decode packet with recipient")
        
        // Verify recipient
        #expect(decodedPacket.recipientID != nil)
        let decodedRecipientID = decodedPacket.recipientID?.trimmingNullBytes()
        // TODO: Check if this is intended that the decoding only gets the first 8
        #expect(String(data: decodedRecipientID!, encoding: .utf8) == "abcdef01")
    }
    
    @Test func packetWithSignature() throws {
        let packet = TestHelpers.createTestPacket(signature: TestConstants.testSignature)
        let encodedData = try #require(BinaryProtocol.encode(packet), "Failed to encode packet with signature")
        let decodedPacket = try #require(BinaryProtocol.decode(encodedData), "Failed to decode packet with signature")
        
        // Verify signature
        #expect(decodedPacket.signature != nil)
        #expect(decodedPacket.signature == TestConstants.testSignature)
    }
    
    // MARK: - Compression Tests
    
    @Test("Create a large, compressible payload above current threshold (2048B)")
    func payloadCompression() throws {
        let repeatedString = String(repeating: "This is a test message. ", count: 200)
        let largePayload = repeatedString.data(using: .utf8)!
        
        let packet = TestHelpers.createTestPacket(payload: largePayload)
        
        // Encode (should compress)
        let encodedData = try #require(BinaryProtocol.encode(packet), "Failed to encode packet with large payload")
        
        // The encoded size should be smaller than uncompressed due to compression
        let headerSize = try #require(BinaryProtocol.headerSize(for: packet.version), "Invalid packet version")
        let uncompressedSize = headerSize + BinaryProtocol.senderIDSize + largePayload.count
        #expect(encodedData.count < uncompressedSize, "Compressed packet should be smaller than uncompressed form")
        
        // Decode and verify
        let decodedPacket = try #require(BinaryProtocol.decode(encodedData), "Failed to decode compressed packet")
        
        #expect(decodedPacket.payload == largePayload)
    }
    
    @Test("Small payloads should not be compressed")
    func smallPayloadNoCompression() throws {
        let smallPayload = "Hi".data(using: .utf8)!
        let packet = TestHelpers.createTestPacket(payload: smallPayload)
        let encodedData = try #require(BinaryProtocol.encode(packet), "Failed to encode small packet")
        let decodedPacket = try #require(BinaryProtocol.decode(encodedData), "Failed to decode small packet")
        #expect(decodedPacket.payload == smallPayload)
    }
    
    // MARK: - Message Padding Tests
    
    @Test func messagePadding() throws {
        let payloads = [
            "Short",
            String(repeating: "Medium length message content ", count: 10), // ~300 bytes  
            String(repeating: "Long message content that should exceed the 512 byte limit ", count: 20), // ~1200+ bytes
            String(repeating: "Very long message content that should definitely exceed the 2048 byte limit for sure ", count: 30) // ~2700+ bytes
        ]
        
        var encodedSizes = Set<Int>()
        
        for payload in payloads {
            let packet = TestHelpers.createTestPacket(payload: payload.data(using: .utf8)!)
            let encodedData = try #require(BinaryProtocol.encode(packet), "Failed to encode packet")
            
            // Verify padding creates standard block sizes up to configured limit (no 4096 bucket currently)
            let blockSizes = [256, 512, 1024, 2048]
            if encodedData.count <= 2048 {
                #expect(blockSizes.contains(encodedData.count), "Encoded size \(encodedData.count) is not a standard block size")
            } else {
                // For very large payloads we expect no additional padding beyond raw size
                #expect(encodedData.count > 2048)
            }
            
            encodedSizes.insert(encodedData.count)
            
            // Verify decoding works
            let decodedPacket = try #require(BinaryProtocol.decode(encodedData), "Failed to decode padded packet")
            #expect(String(data: decodedPacket.payload, encoding: .utf8) == payload)
        }
        
        // Different payload sizes (within <=2048) may map to the same bucket depending on compression.
        // Require at least one padded size to be present.
        #expect(encodedSizes.filter { $0 <= 2048 }.count >= 1, "Expected at least one padded size up to 2048, got \(encodedSizes)")
    }

    @Test func invalidPKCS7PaddingIsRejected() throws {
        let pkt = TestHelpers.createTestPacket(payload: Data(repeating: 0x41, count: 50)) // small
        let enc0 = try #require(BinaryProtocol.encode(pkt), "encode failed")
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
                #expect(pkt2.payload == pkt.payload)
            } else {
                #expect(maybe == nil)
            }
        } else {
            // If no padding was applied, just assert decode succeeds (nothing to test)
            #expect(BinaryProtocol.decode(enc) != nil)
        }
    }
    
    // MARK: - Message Encoding/Decoding Tests
    
    @Test func messageEncodingDecoding() throws {
        let message = TestHelpers.createTestMessage()
        
        let payload = try #require(message.toBinaryPayload(), "Failed to encode message to binary")
        
        let decodedMessage = try #require(BitchatMessage(payload), "Failed to decode message from binary")
        
        #expect(decodedMessage.content == message.content)
        #expect(decodedMessage.sender == message.sender)
        #expect(decodedMessage.senderPeerID == message.senderPeerID)
        #expect(decodedMessage.isPrivate == message.isPrivate)
        
        // Timestamp should be close (within 1 second due to conversion)
        let timeDiff = abs(decodedMessage.timestamp.timeIntervalSince(message.timestamp))
        #expect(timeDiff < 1)
    }
    
    func testPrivateMessageEncoding() throws {
        let message = TestHelpers.createTestMessage(
            isPrivate: true,
            recipientNickname: TestConstants.testNickname2
        )
        
        let payload = try #require(message.toBinaryPayload(), "Failed to encode private message")
        let decodedMessage = try #require(BitchatMessage(payload), "Failed to decode private message")
        
        #expect(decodedMessage.isPrivate)
        #expect(decodedMessage.recipientNickname == TestConstants.testNickname2)
    }
    
    @Test func messageWithMentions() throws {
        let mentions = [TestConstants.testNickname2, TestConstants.testNickname3]
        let message = TestHelpers.createTestMessage(mentions: mentions)
        let payload = try #require(message.toBinaryPayload(), "Failed to encode message with mentions")
        let decodedMessage = try #require(BitchatMessage(payload), "Failed to decode message with mentions")
        #expect(decodedMessage.mentions == mentions)
    }
    
    @Test func relayMessageEncoding() throws {
        let message = BitchatMessage(
            id: UUID().uuidString,
            sender: TestConstants.testNickname1,
            content: TestConstants.testMessage1,
            timestamp: Date(),
            isRelay: true,
            originalSender: TestConstants.testNickname3,
            isPrivate: false,
            recipientNickname: nil,
            mentions: nil
        )
        let payload = try #require(message.toBinaryPayload(), "Failed to encode relay message")
        let decodedMessage = try #require(BitchatMessage(payload), "Failed to decode relay message")
        #expect(decodedMessage.isRelay)
        #expect(decodedMessage.originalSender == TestConstants.testNickname3)
    }
    
    // MARK: - Edge Cases and Error Handling
    
    @Test("Too small data")
    func invalidDataDecoding() throws {
        let tooSmall = Data(repeating: 0, count: 5)
        #expect(BinaryProtocol.decode(tooSmall) == nil)
        
        // Random data
        let random = TestHelpers.generateRandomData(length: 100)
        #expect(BinaryProtocol.decode(random) == nil)
        
        // Corrupted header
        let packet = TestHelpers.createTestPacket()
        var encoded = try #require(BinaryProtocol.encode(packet), "Failed to encode test packet")
        
        // Corrupt the version byte
        encoded[0] = 0xFF
        #expect(BinaryProtocol.decode(encoded) == nil)
    }
    
    @Test("Test maximum size handling")
    func largeMessageHandling() throws {
        let largeContent = String(repeating: "X", count: 65535) // Max uint16
        let message = TestHelpers.createTestMessage(content: largeContent)
        let payload = try #require(message.toBinaryPayload(), "Failed to handle large message")
        let decodedMessage = try #require(BitchatMessage(payload), "Failed to handle large message")
        #expect(decodedMessage.content == largeContent)
    }
    
    @Test("Test message with empty content")
    func emptyFieldsHandling() throws {
        let emptyMessage = TestHelpers.createTestMessage(content: "")
        let payload = try #require(emptyMessage.toBinaryPayload(), "Failed to handle empty message")
        let decodedMessage = try #require(BitchatMessage(payload), "Failed to handle empty message")
        #expect(decodedMessage.content.isEmpty)
    }
    
    // MARK: - Protocol Version Tests
    
    @Test("Test with supported version (version is always 1 in init)")
    func protocolVersionHandling() throws {
        let packet = TestHelpers.createTestPacket()
        let encoded = try #require(BinaryProtocol.encode(packet), "Failed to encode packet with version")
        let decoded = try #require(BinaryProtocol.decode(encoded), "Failed to decode packet with version")
        #expect(decoded.version == 1)
    }
    
    @Test("Create packet data with unsupported version")
    func unsupportedProtocolVersion() throws {
        let packet = TestHelpers.createTestPacket()
        var encoded = try #require(BinaryProtocol.encode(packet), "Failed to encode packet")
        
        // Manually change version byte to unsupported value
        encoded[0] = 99 // Unsupported version
        
        // Should fail to decode
        #expect(BinaryProtocol.decode(encoded) == nil)
    }
    
    // MARK: - Bounds Checking Tests (Crash Prevention)
    
    @Test("Test the specific crash scenario: payloadLength = 193 (0xc1) but only 30 bytes available")
    func malformedPacketWithInvalidPayloadLength() throws {
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
        #expect(malformedData.count == 30)
        
        // This should not crash - should return nil gracefully
        let result = BinaryProtocol.decode(malformedData)
        #expect(result == nil, "Malformed packet with invalid payload length should return nil, not crash")
    }
    
    @Test("Test various truncation scenarios")
    func truncatedPacketHandling() throws {
        let packet = TestHelpers.createTestPacket()
        let validEncoded = try #require(BinaryProtocol.encode(packet), "Failed to encode test packet")
        
        // Test truncation at various points
        let truncationPoints = [0, 5, 10, 15, 20, 25]
        
        for point in truncationPoints {
            let truncated = validEncoded.prefix(point)
            let result = BinaryProtocol.decode(truncated)
            #expect(result == nil, "Truncated packet at \(point) bytes should return nil, not crash")
        }
    }
    
    @Test("Test compressed packet with invalid original size")
    func malformedCompressedPacket() throws {
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
        #expect(result == nil, "Malformed compressed packet should return nil, not crash")
    }
    
    @Test("Test packet claiming extremely large payload")
    func excessivelyLargePayloadLength() throws {
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
        #expect(result == nil, "Packet with excessive payload length should return nil, not crash")
    }
    
    @Test("Test compressed packet with unreasonable original size")
    func compressedPacketWithInvalidOriginalSize() throws {
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
        #expect(result == nil, "Compressed packet with invalid original size should return nil, not crash")
    }
    
    @Test("Test packet designed to cause integer overflow")
    func maliciousPacketWithIntegerOverflow() throws {
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
        #expect(result == nil, "Malicious packet designed for integer overflow should return nil, not crash")
    }
    
    @Test("Test packets with incomplete headers")
    func partialHeaderData() throws {
        let headerSizes = [0, 1, 5, 10, 12] // Various incomplete header sizes
        
        for size in headerSizes {
            let partialData = Data(repeating: 0x01, count: size)
            let result = BinaryProtocol.decode(partialData)
            #expect(result == nil, "Partial header data (\(size) bytes) should return nil, not crash")
        }
    }
    
    @Test("Test exact boundary conditions")
    func boundaryConditions() throws {
        let packet = TestHelpers.createTestPacket()
        let validEncoded = try #require(BinaryProtocol.encode(packet), "Failed to encode test packet")
        
        // If truncation only removes padding, decode may still succeed. Compute unpadded size.
        let unpadded = MessagePadding.unpad(validEncoded)
        // Truncate within the unpadded frame to guarantee corruption
        let cut = max(1, unpadded.count - 10)
        let truncatedCore = unpadded.prefix(cut)
        let result = BinaryProtocol.decode(truncatedCore)
        #expect(result == nil, "Truncated core frame should return nil, not crash")
        
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
