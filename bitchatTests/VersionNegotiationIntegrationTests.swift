//
// VersionNegotiationIntegrationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CoreBluetooth
@testable import bitchat

class VersionNegotiationIntegrationTests: XCTestCase {
    
    var meshService: BluetoothMeshService!
    var mockDelegate: MockBitchatDelegate!
    
    override func setUp() {
        super.setUp()
        meshService = BluetoothMeshService()
        mockDelegate = MockBitchatDelegate()
        meshService.delegate = mockDelegate
    }
    
    override func tearDown() {
        meshService = nil
        mockDelegate = nil
        super.tearDown()
    }
    
    // MARK: - Version Negotiation Flow Tests
    
    func testVersionNegotiationSuccessFlow() {
        let peerID = "testpeer12345678"
        
        // Simulate receiving version hello
        let hello = VersionHello(
            supportedVersions: [1],
            preferredVersion: 1,
            clientVersion: "1.0.0",
            platform: "iOS"
        )
        
        guard let helloData = hello.encode() else {
            XCTFail("Failed to encode hello")
            return
        }
        
        let helloPacket = BitchatPacket(
            type: MessageType.versionHello.rawValue,
            senderID: Data(hexString: peerID) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: helloData,
            signature: nil,
            ttl: 1
        )
        
        // Process the hello packet
        meshService.handleReceivedPacket(helloPacket, from: peerID, peripheral: nil)
        
        // Verify that version was negotiated
        // Note: We'd need to expose negotiatedVersions or add a getter to properly test this
        // For now, we're testing that the packet is processed without errors
        
        // The service should have sent a version ack
        // In a real test, we'd mock the broadcast mechanism to verify this
    }
    
    func testVersionNegotiationRejectionFlow() {
        let peerID = "incompatiblepeer"
        
        // Simulate receiving version hello with incompatible version
        let hello = VersionHello(
            supportedVersions: [99, 100], // Unsupported versions
            preferredVersion: 100,
            clientVersion: "99.0.0",
            platform: "Unknown"
        )
        
        guard let helloData = hello.encode() else {
            XCTFail("Failed to encode hello")
            return
        }
        
        let helloPacket = BitchatPacket(
            type: MessageType.versionHello.rawValue,
            senderID: Data(hexString: peerID) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: helloData,
            signature: nil,
            ttl: 1
        )
        
        // Process the hello packet
        meshService.handleReceivedPacket(helloPacket, from: peerID, peripheral: nil)
        
        // The service should send a rejection ack
        // In a real implementation, we'd verify the rejection was sent
    }
    
    func testBackwardCompatibilityWithLegacyPeer() {
        let peerID = "legacypeer123456"
        
        // Simulate receiving a Noise handshake init without prior version negotiation
        let handshakePacket = BitchatPacket(
            type: MessageType.noiseHandshakeInit.rawValue,
            senderID: Data(hexString: peerID) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("handshake_data".utf8),
            signature: nil,
            ttl: 3
        )
        
        // Process the handshake packet
        meshService.handleReceivedPacket(handshakePacket, from: peerID, peripheral: nil)
        
        // Should assume version 1 for backward compatibility
        // The handshake should proceed normally
    }
    
    func testVersionAckHandling() {
        let peerID = "ackpeer12345678"
        
        // Simulate receiving version ack
        let ack = VersionAck(
            agreedVersion: 1,
            serverVersion: "1.0.0",
            platform: "macOS"
        )
        
        guard let ackData = ack.encode() else {
            XCTFail("Failed to encode ack")
            return
        }
        
        let ackPacket = BitchatPacket(
            type: MessageType.versionAck.rawValue,
            senderID: Data(hexString: peerID) ?? Data(),
            recipientID: meshService.getMyPeerID().data(using: .utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: ackData,
            signature: nil,
            ttl: 1
        )
        
        // Process the ack packet
        meshService.handleReceivedPacket(ackPacket, from: peerID, peripheral: nil)
        
        // Should update negotiated version and proceed with handshake
    }
    
    func testVersionAckRejectionHandling() {
        let peerID = "rejectpeer123456"
        
        // Simulate receiving rejection ack
        let ack = VersionAck(
            agreedVersion: 0,
            serverVersion: "2.0.0",
            platform: "iOS",
            rejected: true,
            reason: "No compatible protocol version"
        )
        
        guard let ackData = ack.encode() else {
            XCTFail("Failed to encode rejection ack")
            return
        }
        
        let ackPacket = BitchatPacket(
            type: MessageType.versionAck.rawValue,
            senderID: Data(hexString: peerID) ?? Data(),
            recipientID: meshService.getMyPeerID().data(using: .utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: ackData,
            signature: nil,
            ttl: 1
        )
        
        // Process the rejection ack
        meshService.handleReceivedPacket(ackPacket, from: peerID, peripheral: nil)
        
        // Should mark negotiation as failed
    }
    
    // MARK: - State Management Tests
    
    func testVersionStateCleanupOnDisconnect() {
        let peerID = "disconnectpeer12"
        
        // First establish some version negotiation state
        let hello = VersionHello(
            clientVersion: "1.0.0",
            platform: "iOS"
        )
        
        guard let helloData = hello.encode() else {
            XCTFail("Failed to encode hello")
            return
        }
        
        let helloPacket = BitchatPacket(
            type: MessageType.versionHello.rawValue,
            senderID: Data(hexString: peerID) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: helloData,
            signature: nil,
            ttl: 1
        )
        
        // Process hello to establish state
        meshService.handleReceivedPacket(helloPacket, from: peerID, peripheral: nil)
        
        // Simulate disconnect
        // In real implementation, we'd trigger the disconnect logic
        // and verify state is cleaned up
    }
    
    // MARK: - Error Handling Tests
    
    func testMalformedVersionHello() {
        let peerID = "malformedpeer123"
        
        // Send malformed data
        let malformedPacket = BitchatPacket(
            type: MessageType.versionHello.rawValue,
            senderID: Data(hexString: peerID) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("not valid json".utf8),
            signature: nil,
            ttl: 1
        )
        
        // Should handle gracefully without crashing
        meshService.handleReceivedPacket(malformedPacket, from: peerID, peripheral: nil)
    }
    
    func testMalformedVersionAck() {
        let peerID = "malformedackpeer"
        
        // Send malformed ack data
        let malformedPacket = BitchatPacket(
            type: MessageType.versionAck.rawValue,
            senderID: Data(hexString: peerID) ?? Data(),
            recipientID: meshService.getMyPeerID().data(using: .utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data("{invalid json}".utf8),
            signature: nil,
            ttl: 1
        )
        
        // Should handle gracefully without crashing
        meshService.handleReceivedPacket(malformedPacket, from: peerID, peripheral: nil)
    }
    
    // MARK: - Performance Tests
    
    func testVersionNegotiationPerformance() {
        measure {
            // Test encoding/decoding performance
            for i in 0..<1000 {
                let hello = VersionHello(
                    supportedVersions: [1, 2, 3],
                    preferredVersion: 3,
                    clientVersion: "1.\(i).0",
                    platform: "iOS",
                    capabilities: ["cap1", "cap2", "cap3"]
                )
                
                if let data = hello.encode(),
                   let _ = VersionHello.decode(from: data) {
                    // Success
                } else {
                    XCTFail("Failed at iteration \(i)")
                }
            }
        }
    }
}

// MARK: - Mock Delegate

class MockBitchatDelegate: BitchatDelegate {
    var receivedMessages: [BitchatMessage] = []
    var connectedPeers: [String] = []
    var disconnectedPeers: [String] = []
    
    func didReceiveMessage(_ message: BitchatMessage) {
        receivedMessages.append(message)
    }
    
    func didConnectToPeer(_ peerID: String) {
        connectedPeers.append(peerID)
    }
    
    func didDisconnectFromPeer(_ peerID: String) {
        disconnectedPeers.append(peerID)
    }
    
    func didUpdatePeerList(_ peers: [String]) {
        // Not used in these tests
    }
    
    func didReceiveChannelLeave(_ channel: String, from peerID: String) {
        // Not used in these tests
    }
    
    func didReceivePasswordProtectedChannelAnnouncement(_ channel: String, isProtected: Bool, creatorID: String?, keyCommitment: String?) {
        // Not used in these tests
    }
    
    func didReceiveChannelRetentionAnnouncement(_ channel: String, enabled: Bool, creatorID: String?) {
        // Not used in these tests
    }
    
    func decryptChannelMessage(_ encryptedContent: Data, channel: String) -> String? {
        return nil
    }
}