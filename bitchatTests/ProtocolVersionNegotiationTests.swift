//
// ProtocolVersionNegotiationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class ProtocolVersionNegotiationTests: XCTestCase {
    
    // MARK: - VersionHello Tests
    
    func testVersionHelloEncodingDecoding() {
        let hello = VersionHello(
            supportedVersions: [1, 2, 3],
            preferredVersion: 3,
            clientVersion: "1.2.3",
            platform: "iOS",
            capabilities: ["noise", "compression"]
        )
        
        // Encode
        guard let encoded = hello.encode() else {
            XCTFail("Failed to encode VersionHello")
            return
        }
        
        // Decode
        guard let decoded = VersionHello.decode(from: encoded) else {
            XCTFail("Failed to decode VersionHello")
            return
        }
        
        // Verify
        XCTAssertEqual(decoded.supportedVersions, hello.supportedVersions)
        XCTAssertEqual(decoded.preferredVersion, hello.preferredVersion)
        XCTAssertEqual(decoded.clientVersion, hello.clientVersion)
        XCTAssertEqual(decoded.platform, hello.platform)
        XCTAssertEqual(decoded.capabilities, hello.capabilities)
    }
    
    func testVersionHelloDefaults() {
        let hello = VersionHello(
            clientVersion: "1.0.0",
            platform: "macOS"
        )
        
        XCTAssertEqual(hello.supportedVersions, Array(ProtocolVersion.supportedVersions))
        XCTAssertEqual(hello.preferredVersion, ProtocolVersion.current)
        XCTAssertNil(hello.capabilities)
    }
    
    // MARK: - VersionAck Tests
    
    func testVersionAckEncodingDecoding() {
        let ack = VersionAck(
            agreedVersion: 2,
            serverVersion: "1.1.0",
            platform: "iOS",
            capabilities: ["noise"],
            rejected: false,
            reason: nil
        )
        
        // Encode
        guard let encoded = ack.encode() else {
            XCTFail("Failed to encode VersionAck")
            return
        }
        
        // Decode
        guard let decoded = VersionAck.decode(from: encoded) else {
            XCTFail("Failed to decode VersionAck")
            return
        }
        
        // Verify
        XCTAssertEqual(decoded.agreedVersion, ack.agreedVersion)
        XCTAssertEqual(decoded.serverVersion, ack.serverVersion)
        XCTAssertEqual(decoded.platform, ack.platform)
        XCTAssertEqual(decoded.capabilities, ack.capabilities)
        XCTAssertEqual(decoded.rejected, ack.rejected)
        XCTAssertNil(decoded.reason)
    }
    
    func testVersionAckRejection() {
        let ack = VersionAck(
            agreedVersion: 0,
            serverVersion: "2.0.0",
            platform: "macOS",
            rejected: true,
            reason: "No compatible version found"
        )
        
        guard let encoded = ack.encode(),
              let decoded = VersionAck.decode(from: encoded) else {
            XCTFail("Failed to encode/decode rejection VersionAck")
            return
        }
        
        XCTAssertTrue(decoded.rejected)
        XCTAssertEqual(decoded.reason, "No compatible version found")
        XCTAssertEqual(decoded.agreedVersion, 0)
    }
    
    // MARK: - ProtocolVersion Tests
    
    func testIsSupported() {
        XCTAssertTrue(ProtocolVersion.isSupported(1))
        XCTAssertFalse(ProtocolVersion.isSupported(99))
        XCTAssertFalse(ProtocolVersion.isSupported(0))
    }
    
    func testVersionNegotiation() {
        // Test successful negotiation
        let clientVersions: [UInt8] = [1, 2, 3]
        let serverVersions: [UInt8] = [1, 3, 4]
        
        let agreed = ProtocolVersion.negotiateVersion(
            clientVersions: clientVersions,
            serverVersions: serverVersions
        )
        
        XCTAssertEqual(agreed, 3) // Should pick highest common version
    }
    
    func testVersionNegotiationNoCommon() {
        // Test no common version
        let clientVersions: [UInt8] = [2, 3]
        let serverVersions: [UInt8] = [4, 5]
        
        let agreed = ProtocolVersion.negotiateVersion(
            clientVersions: clientVersions,
            serverVersions: serverVersions
        )
        
        XCTAssertNil(agreed)
    }
    
    func testVersionNegotiationSingleCommon() {
        // Test single common version
        let clientVersions: [UInt8] = [1]
        let serverVersions: [UInt8] = [1, 2, 3]
        
        let agreed = ProtocolVersion.negotiateVersion(
            clientVersions: clientVersions,
            serverVersions: serverVersions
        )
        
        XCTAssertEqual(agreed, 1)
    }
    
    func testVersionNegotiationEmpty() {
        // Test empty version lists
        let agreed1 = ProtocolVersion.negotiateVersion(
            clientVersions: [],
            serverVersions: [1, 2]
        )
        XCTAssertNil(agreed1)
        
        let agreed2 = ProtocolVersion.negotiateVersion(
            clientVersions: [1, 2],
            serverVersions: []
        )
        XCTAssertNil(agreed2)
    }
    
    // MARK: - Binary Protocol Integration Tests
    
    func testVersionHelloPacketEncoding() {
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
        
        guard let encoded = packet.toBinaryData() else {
            XCTFail("Failed to encode packet")
            return
        }
        
        guard let decoded = BitchatPacket.from(encoded) else {
            XCTFail("Failed to decode packet")
            return
        }
        
        XCTAssertEqual(decoded.type, MessageType.versionHello.rawValue)
        XCTAssertEqual(decoded.ttl, 1)
        
        // Verify payload can be decoded back to VersionHello
        guard let decodedHello = VersionHello.decode(from: decoded.payload) else {
            XCTFail("Failed to decode VersionHello from packet payload")
            return
        }
        
        XCTAssertEqual(decodedHello.clientVersion, "1.0.0")
        XCTAssertEqual(decodedHello.platform, "iOS")
    }
    
    func testVersionAckPacketEncoding() {
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
            senderID: Data("sender".utf8),
            recipientID: Data("recipient".utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: ackData,
            signature: nil,
            ttl: 1
        )
        
        guard let encoded = packet.toBinaryData() else {
            XCTFail("Failed to encode packet")
            return
        }
        
        guard let decoded = BitchatPacket.from(encoded) else {
            XCTFail("Failed to decode packet")
            return
        }
        
        XCTAssertEqual(decoded.type, MessageType.versionAck.rawValue)
        
        // Verify payload can be decoded back to VersionAck
        guard let decodedAck = VersionAck.decode(from: decoded.payload) else {
            XCTFail("Failed to decode VersionAck from packet payload")
            return
        }
        
        XCTAssertEqual(decodedAck.agreedVersion, 1)
        XCTAssertEqual(decodedAck.serverVersion, "1.0.0")
        XCTAssertEqual(decodedAck.platform, "macOS")
    }
    
    // MARK: - Version State Management Tests
    
    func testVersionNegotiationStateTransitions() {
        var state = VersionNegotiationState.none
        
        // Test transition to helloSent
        state = .helloSent
        if case .helloSent = state {
            // Success
        } else {
            XCTFail("State should be helloSent")
        }
        
        // Test transition to ackReceived
        state = .ackReceived(version: 2)
        if case .ackReceived(let version) = state {
            XCTAssertEqual(version, 2)
        } else {
            XCTFail("State should be ackReceived")
        }
        
        // Test transition to failed
        state = .failed(reason: "Version mismatch")
        if case .failed(let reason) = state {
            XCTAssertEqual(reason, "Version mismatch")
        } else {
            XCTFail("State should be failed")
        }
    }
    
    // MARK: - Edge Cases
    
    func testLargeVersionNumbers() {
        let hello = VersionHello(
            supportedVersions: [1, 127, 255],
            preferredVersion: 255,
            clientVersion: "99.99.99",
            platform: "iOS"
        )
        
        guard let encoded = hello.encode(),
              let decoded = VersionHello.decode(from: encoded) else {
            XCTFail("Failed to encode/decode with large version numbers")
            return
        }
        
        XCTAssertEqual(decoded.supportedVersions, [1, 127, 255])
        XCTAssertEqual(decoded.preferredVersion, 255)
    }
    
    func testEmptyCapabilities() {
        let hello = VersionHello(
            clientVersion: "1.0.0",
            platform: "iOS",
            capabilities: []
        )
        
        guard let encoded = hello.encode(),
              let decoded = VersionHello.decode(from: encoded) else {
            XCTFail("Failed to encode/decode with empty capabilities")
            return
        }
        
        XCTAssertEqual(decoded.capabilities, [])
    }
    
    func testLongCapabilityStrings() {
        let longCapability = String(repeating: "a", count: 1000)
        let hello = VersionHello(
            clientVersion: "1.0.0",
            platform: "iOS",
            capabilities: [longCapability, "normal"]
        )
        
        guard let encoded = hello.encode(),
              let decoded = VersionHello.decode(from: encoded) else {
            XCTFail("Failed to encode/decode with long capability strings")
            return
        }
        
        XCTAssertEqual(decoded.capabilities?.count, 2)
        XCTAssertEqual(decoded.capabilities?[0], longCapability)
        XCTAssertEqual(decoded.capabilities?[1], "normal")
    }
    
    func testInvalidJSON() {
        let invalidData = Data("not json".utf8)
        
        XCTAssertNil(VersionHello.decode(from: invalidData))
        XCTAssertNil(VersionAck.decode(from: invalidData))
    }
    
    func testEmptyData() {
        let emptyData = Data()
        
        XCTAssertNil(VersionHello.decode(from: emptyData))
        XCTAssertNil(VersionAck.decode(from: emptyData))
    }
}