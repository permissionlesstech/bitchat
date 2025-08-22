//
// BLEServiceTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CoreBluetooth
@testable import bitchat

final class BLEServiceTests: XCTestCase {
    
    var service: MockBLEService!
    
    override func setUp() {
        super.setUp()
        service = MockBLEService()
        service.myPeerID = "TEST1234"
        service.mockNickname = "TestUser"
    }
    
    override func tearDown() {
        service = nil
        super.tearDown()
    }
    
    // MARK: - Basic Functionality Tests
    
    func testServiceInitialization() {
        XCTAssertNotNil(service)
        XCTAssertEqual(service.myPeerID, "TEST1234")
        XCTAssertEqual(service.myNickname, "TestUser")
    }
    
    func testPeerConnection() {
        // Test connecting a peer
        service.simulateConnectedPeer("PEER5678")
        XCTAssertTrue(service.isPeerConnected("PEER5678"))
        XCTAssertEqual(service.getConnectedPeers().count, 1)
        
        // Test disconnecting a peer
        service.simulateDisconnectedPeer("PEER5678")
        XCTAssertFalse(service.isPeerConnected("PEER5678"))
        XCTAssertEqual(service.getConnectedPeers().count, 0)
    }
    
    func testMultiplePeerConnections() {
        service.simulateConnectedPeer("PEER1")
        service.simulateConnectedPeer("PEER2")
        service.simulateConnectedPeer("PEER3")
        
        XCTAssertEqual(service.getConnectedPeers().count, 3)
        XCTAssertTrue(service.isPeerConnected("PEER1"))
        XCTAssertTrue(service.isPeerConnected("PEER2"))
        XCTAssertTrue(service.isPeerConnected("PEER3"))
        
        service.simulateDisconnectedPeer("PEER2")
        XCTAssertEqual(service.getConnectedPeers().count, 2)
        XCTAssertFalse(service.isPeerConnected("PEER2"))
    }
    
    // MARK: - Message Sending Tests
    
    func testSendPublicMessage() {
        let expectation = XCTestExpectation(description: "Message sent")
        
        let delegate = MockBitchatDelegate { message in
            XCTAssertEqual(message.content, "Hello, world!")
            XCTAssertEqual(message.sender, "TestUser")
            XCTAssertFalse(message.isPrivate)
            expectation.fulfill()
        }
        service.delegate = delegate
        
        service.sendMessage("Hello, world!")
        
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(service.sentMessages.count, 1)
    }
    
    func testSendPrivateMessage() {
        let expectation = XCTestExpectation(description: "Private message sent")
        
        let delegate = MockBitchatDelegate { message in
            XCTAssertEqual(message.content, "Secret message")
            XCTAssertEqual(message.sender, "TestUser")
            XCTAssertTrue(message.isPrivate)
            XCTAssertEqual(message.recipientNickname, "Bob")
            expectation.fulfill()
        }
        service.delegate = delegate
        
        service.sendPrivateMessage("Secret message", to: "PEER5678", recipientNickname: "Bob", messageID: "MSG123")
        
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(service.sentMessages.count, 1)
    }
    
    func testSendMessageWithMentions() {
        let expectation = XCTestExpectation(description: "Message with mentions sent")
        
        let delegate = MockBitchatDelegate { message in
            XCTAssertEqual(message.content, "@alice @bob check this out")
            XCTAssertEqual(message.mentions, ["alice", "bob"])
            expectation.fulfill()
        }
        service.delegate = delegate
        
        service.sendMessage("@alice @bob check this out", mentions: ["alice", "bob"])
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Message Reception Tests
    
    func testSimulateIncomingMessage() {
        let expectation = XCTestExpectation(description: "Message received")
        
        let delegate = MockBitchatDelegate { message in
            XCTAssertEqual(message.content, "Incoming message")
            XCTAssertEqual(message.sender, "RemoteUser")
            expectation.fulfill()
        }
        service.delegate = delegate
        
        let incomingMessage = BitchatMessage(
            id: "MSG456",
            sender: "RemoteUser",
            content: "Incoming message",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: "REMOTE123",
            mentions: nil
        )
        
        service.simulateIncomingMessage(incomingMessage)
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testSimulateIncomingPacket() {
        let expectation = XCTestExpectation(description: "Packet processed")
        
        let delegate = MockBitchatDelegate { message in
            XCTAssertEqual(message.content, "Packet message")
            expectation.fulfill()
        }
        service.delegate = delegate
        
        let message = BitchatMessage(
            id: "MSG789",
            sender: "PacketSender",
            content: "Packet message",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: "PACKET123",
            mentions: nil
        )
        
        guard let payload = message.toBinaryPayload() else {
            XCTFail("Failed to create binary payload")
            return
        }
        
        let packet = BitchatPacket(
            type: 0x01,
            senderID: "PACKET123".data(using: .utf8)!,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 3
        )
        
        service.simulateIncomingPacket(packet)
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Peer Nickname Tests
    
    func testGetPeerNicknames() {
        service.simulateConnectedPeer("PEER1")
        service.simulateConnectedPeer("PEER2")
        
        let nicknames = service.getPeerNicknames()
        XCTAssertEqual(nicknames.count, 2)
        XCTAssertEqual(nicknames["PEER1"], "MockPeer_PEER1")
        XCTAssertEqual(nicknames["PEER2"], "MockPeer_PEER2")
    }
    
    // MARK: - Service State Tests
    
    func testStartStopServices() {
        // These are mock implementations, just ensure they don't crash
        service.startServices()
        service.stopServices()
        
        // Service should still be functional after start/stop
        service.simulateConnectedPeer("PEER999")
        XCTAssertTrue(service.isPeerConnected("PEER999"))
    }
    
    // MARK: - Message Delivery Handler Tests
    
    func testMessageDeliveryHandler() {
        let expectation = XCTestExpectation(description: "Delivery handler called")
        
        service.packetDeliveryHandler = { packet in
            if let msg = BitchatMessage.fromBinaryPayload(packet.payload) {
                XCTAssertEqual(msg.content, "Test delivery")
                expectation.fulfill()
            }
        }
        
        service.sendMessage("Test delivery")
        
        wait(for: [expectation], timeout: 1.0)
    }
    
    func testPacketDeliveryHandler() {
        let expectation = XCTestExpectation(description: "Packet handler called")
        
        service.packetDeliveryHandler = { packet in
            XCTAssertEqual(packet.type, 0x01)
            expectation.fulfill()
        }
        
        let message = BitchatMessage(
            id: "PKT123",
            sender: "TestSender",
            content: "Test packet",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: "TEST123",
            mentions: nil
        )
        
        guard let payload = message.toBinaryPayload() else {
            XCTFail("Failed to create payload")
            return
        }
        
        let packet = BitchatPacket(
            type: 0x01,
            senderID: "TEST123".data(using: .utf8)!,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 3
        )
        
        service.simulateIncomingPacket(packet)
        
        wait(for: [expectation], timeout: 1.0)
    }
}

// MARK: - Mock Delegate Helper

private class MockBitchatDelegate: BitchatDelegate {
    private let messageHandler: (BitchatMessage) -> Void
    
    init(_ handler: @escaping (BitchatMessage) -> Void) {
        self.messageHandler = handler
    }
    
    func didReceiveMessage(_ message: BitchatMessage) {
        messageHandler(message)
    }
    
    func didConnectToPeer(_ peerID: String) {}
    func didDisconnectFromPeer(_ peerID: String) {}
    func didUpdatePeerList(_ peers: [String]) {}
    func isFavorite(fingerprint: String) -> Bool { return false }
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {}
}
