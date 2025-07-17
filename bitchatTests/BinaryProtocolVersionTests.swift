//
// BinaryProtocolVersionTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class BinaryProtocolVersionTests: XCTestCase {
    
    // MARK: - Version Support Tests
    
    func testCurrentVersionIsSupported() {
        // Current version should always be supported
        XCTAssertTrue(ProtocolVersion.isSupported(ProtocolVersion.current))
    }
    
    func testVersion1IsSupported() {
        // Version 1 must be supported for backward compatibility
        XCTAssertTrue(ProtocolVersion.isSupported(1))
    }
    
    func testUnsupportedVersionsRejected() {
        // Test various unsupported versions
        XCTAssertFalse(ProtocolVersion.isSupported(0))
        XCTAssertFalse(ProtocolVersion.isSupported(2))
        XCTAssertFalse(ProtocolVersion.isSupported(99))
        XCTAssertFalse(ProtocolVersion.isSupported(255))
    }
    
    // MARK: - Binary Protocol Version Handling
    
    func testBinaryProtocolRejectsUnsupportedVersion() {
        // Create a packet with unsupported version
        var data = Data()
        
        // Header
        data.append(99) // Unsupported version
        data.append(MessageType.message.rawValue)
        data.append(5) // TTL
        
        // Timestamp (8 bytes)
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        for i in (0..<8).reversed() {
            data.append(UInt8((timestamp >> (i * 8)) & 0xFF))
        }
        
        // Flags (no recipient, no signature)
        data.append(0)
        
        // Payload length (2 bytes)
        let payload = Data("test".utf8)
        let payloadLength = UInt16(payload.count)
        data.append(UInt8((payloadLength >> 8) & 0xFF))
        data.append(UInt8(payloadLength & 0xFF))
        
        // SenderID (8 bytes)
        data.append(Data(repeating: 0x01, count: 8))
        
        // Payload
        data.append(payload)
        
        // Try to decode - should fail due to unsupported version
        let decoded = BinaryProtocol.decode(data)
        XCTAssertNil(decoded, "Should reject packet with unsupported version")
    }
    
    func testBinaryProtocolAcceptsVersion1() {
        // Create a valid version 1 packet
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data("sender12".utf8),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("Hello".utf8),
            signature: nil,
            ttl: 3
        )
        
        // Encode
        guard let encoded = packet.toBinaryData() else {
            XCTFail("Failed to encode version 1 packet")
            return
        }
        
        // Decode
        guard let decoded = BitchatPacket.from(encoded) else {
            XCTFail("Failed to decode version 1 packet")
            return
        }
        
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.payload, Data("Hello".utf8))
    }
    
    // MARK: - Version Message Type Tests
    
    func testVersionHelloMessageType() {
        let hello = VersionHello(
            clientVersion: "1.0.0",
            platform: "iOS"
        )
        
        guard let helloData = hello.encode() else {
            XCTFail("Failed to encode VersionHello")
            return
        }
        
        let packet = BitchatPacket(
            type: MessageType.versionHello.rawValue,
            ttl: 1,
            senderID: "testpeer",
            payload: helloData
        )
        
        XCTAssertEqual(packet.type, MessageType.versionHello.rawValue)
        XCTAssertEqual(MessageType.versionHello.description, "versionHello")
    }
    
    func testVersionAckMessageType() {
        let ack = VersionAck(
            agreedVersion: 1,
            serverVersion: "1.0.0",
            platform: "macOS"
        )
        
        guard let ackData = ack.encode() else {
            XCTFail("Failed to encode VersionAck")
            return
        }
        
        let packet = BitchatPacket(
            type: MessageType.versionAck.rawValue,
            ttl: 1,
            senderID: "testpeer",
            payload: ackData
        )
        
        XCTAssertEqual(packet.type, MessageType.versionAck.rawValue)
        XCTAssertEqual(MessageType.versionAck.description, "versionAck")
    }
    
    // MARK: - Compression Compatibility Tests
    
    func testCompressedPacketWithVersion() {
        // Create a large payload that will trigger compression
        let largeContent = String(repeating: "Hello World! ", count: 100)
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data("sender12".utf8),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(largeContent.utf8),
            signature: nil,
            ttl: 3
        )
        
        // Encode (should compress)
        guard let encoded = packet.toBinaryData() else {
            XCTFail("Failed to encode packet with compression")
            return
        }
        
        // Decode
        guard let decoded = BitchatPacket.from(encoded) else {
            XCTFail("Failed to decode compressed packet")
            return
        }
        
        // Verify version is preserved
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.payload, Data(largeContent.utf8))
    }
    
    // MARK: - Future Version Migration Tests
    
    func testVersionSetConsistency() {
        // Ensure version constants are consistent
        XCTAssertTrue(ProtocolVersion.supportedVersions.contains(ProtocolVersion.current))
        XCTAssertTrue(ProtocolVersion.supportedVersions.contains(ProtocolVersion.minimum))
        XCTAssertGreaterThanOrEqual(ProtocolVersion.current, ProtocolVersion.minimum)
        XCTAssertLessThanOrEqual(ProtocolVersion.current, ProtocolVersion.maximum)
    }
    
    func testVersionNegotiationAlwaysPicksHighest() {
        // When multiple versions are supported, should pick highest
        let clientVersions: [UInt8] = [1, 2, 3, 4, 5]
        let serverVersions: [UInt8] = [3, 4, 5, 6, 7]
        
        let agreed = ProtocolVersion.negotiateVersion(
            clientVersions: clientVersions,
            serverVersions: serverVersions
        )
        
        XCTAssertEqual(agreed, 5) // Highest common version
    }
    
    // MARK: - Packet Size Tests with Version Negotiation
    
    func testVersionNegotiationPacketsAreSmall() {
        // Version negotiation should use minimal bandwidth
        let hello = VersionHello(
            clientVersion: "1.0.0",
            platform: "iOS"
        )
        
        guard let helloData = hello.encode() else {
            XCTFail("Failed to encode hello")
            return
        }
        
        let packet = BitchatPacket(
            type: MessageType.versionHello.rawValue,
            ttl: 1,
            senderID: "12345678",
            payload: helloData
        )
        
        guard let encoded = packet.toBinaryData() else {
            XCTFail("Failed to encode packet")
            return
        }
        
        // Version negotiation packets should be reasonably small
        XCTAssertLessThan(encoded.count, 512, "Version negotiation packet too large")
    }
}