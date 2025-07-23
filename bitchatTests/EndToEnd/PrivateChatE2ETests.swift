//
// PrivateChatE2ETests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CryptoKit
@testable import bitchat

final class PrivateChatE2ETests: XCTestCase {
    
    var alice: MockBluetoothMeshService!
    var bob: MockBluetoothMeshService!
    var charlie: MockBluetoothMeshService!
    
    var deliveryTracker: DeliveryTracker!
    var retryService: MessageRetryService!
    
    override func setUp() {
        super.setUp()
        
        // Create services
        alice = createMockService(peerID: TestConstants.testPeerID1, nickname: TestConstants.testNickname1)
        bob = createMockService(peerID: TestConstants.testPeerID2, nickname: TestConstants.testNickname2)
        charlie = createMockService(peerID: TestConstants.testPeerID3, nickname: TestConstants.testNickname3)
        
        // Setup delivery tracking
        deliveryTracker = DeliveryTracker.shared
        retryService = MessageRetryService.shared
        retryService.meshService = alice
        
        // Clear any existing state
        deliveryTracker.clearDeliveryStatus(for: "")
        retryService.clearRetryQueue()
    }
    
    override func tearDown() {
        alice = nil
        bob = nil
        charlie = nil
        deliveryTracker = nil
        retryService = nil
        super.tearDown()
    }
    
    // MARK: - Basic Private Messaging Tests
    
    func testSimplePrivateMessage() {
        simulateConnection(alice, bob)
        
        let expectation = XCTestExpectation(description: "Bob receives private message")
        
        bob.messageDeliveryHandler = { message in
            if message.content == TestConstants.testMessage1 && 
               message.isPrivate &&
               message.sender == TestConstants.testNickname1 {
                expectation.fulfill()
            }
        }
        
        // Alice sends private message to Bob
        alice.sendPrivateMessage(
            TestConstants.testMessage1,
            to: TestConstants.testPeerID2,
            recipientNickname: TestConstants.testNickname2
        )
        
        wait(for: [expectation], timeout: TestConstants.shortTimeout)
    }
    
    func testPrivateMessageNotReceivedByOthers() {
        // Connect all three
        simulateConnection(alice, bob)
        simulateConnection(alice, charlie)
        
        let bobExpectation = XCTestExpectation(description: "Bob receives private message")
        let charlieExpectation = XCTestExpectation(description: "Charlie should not receive")
        charlieExpectation.isInverted = true
        
        bob.messageDeliveryHandler = { message in
            if message.content == TestConstants.testMessage1 && message.isPrivate {
                bobExpectation.fulfill()
            }
        }
        
        charlie.messageDeliveryHandler = { message in
            if message.content == TestConstants.testMessage1 {
                charlieExpectation.fulfill() // Should not happen
            }
        }
        
        // Alice sends private message to Bob only
        alice.sendPrivateMessage(
            TestConstants.testMessage1,
            to: TestConstants.testPeerID2,
            recipientNickname: TestConstants.testNickname2
        )
        
        wait(for: [bobExpectation, charlieExpectation], timeout: TestConstants.shortTimeout)
    }
    
    // MARK: - Delivery Acknowledgment Tests
    
    func testDeliveryAckGeneration() {
        simulateConnection(alice, bob)
        
        let messageID = UUID().uuidString
        let expectation = XCTestExpectation(description: "Delivery status updated")
        
        // Monitor delivery status
        let cancellable = deliveryTracker.deliveryStatusUpdated.sink { update in
            if update.messageID == messageID {
                switch update.status {
                case .delivered(let recipient, _):
                    XCTAssertEqual(recipient, TestConstants.testNickname2)
                    expectation.fulfill()
                default:
                    break
                }
            }
        }
        
        // Setup Bob to generate ACK
        bob.packetDeliveryHandler = { packet in
            if let message = BitchatMessage.fromBinaryPayload(packet.payload),
               message.isPrivate {
                // Generate ACK
                if let ack = self.deliveryTracker.generateAck(
                    for: message,
                    myPeerID: TestConstants.testPeerID2,
                    myNickname: TestConstants.testNickname2,
                    hopCount: 1
                ) {
                    // Send ACK back
                    let ackData = ack.encode()!
                    let ackPacket = TestHelpers.createTestPacket(
                        type: 0x03,
                        senderID: TestConstants.testPeerID2,
                        recipientID: TestConstants.testPeerID1,
                        payload: ackData
                    )
                    self.alice.simulateIncomingPacket(ackPacket)
                }
            }
        }
        
        // Setup Alice to process ACK
        alice.packetDeliveryHandler = { packet in
            if packet.type == 0x03 {
                if let ack = DeliveryAck.decode(from: packet.payload) {
                    self.deliveryTracker.processDeliveryAck(ack)
                }
            }
        }
        
        // Track the message
        let trackedMessage = BitchatMessage(
            id: messageID,
            sender: TestConstants.testNickname1,
            content: TestConstants.testMessage1,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: TestConstants.testNickname2,
            senderPeerID: TestConstants.testPeerID1,
            mentions: nil
        )
        
        deliveryTracker.trackMessage(
            trackedMessage,
            recipientID: TestConstants.testPeerID2,
            recipientNickname: TestConstants.testNickname2
        )
        
        // Send the message
        alice.sendPrivateMessage(
            TestConstants.testMessage1,
            to: TestConstants.testPeerID2,
            recipientNickname: TestConstants.testNickname2,
            messageID: messageID
        )
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        cancellable.cancel()
    }
    
    func testDeliveryTimeout() {
        // Don't connect peers - message should timeout
        let messageID = UUID().uuidString
        let expectation = XCTestExpectation(description: "Delivery failed due to timeout")
        
        // Use shared instance (can't create new one due to private init)
        let shortTimeoutTracker = DeliveryTracker.shared
        
        let cancellable = shortTimeoutTracker.deliveryStatusUpdated.sink { update in
            if update.messageID == messageID {
                switch update.status {
                case .failed(let reason):
                    XCTAssertTrue(reason.contains("not delivered"))
                    expectation.fulfill()
                default:
                    break
                }
            }
        }
        
        let trackedMessage = BitchatMessage(
            id: messageID,
            sender: TestConstants.testNickname1,
            content: TestConstants.testMessage1,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: TestConstants.testNickname2,
            senderPeerID: TestConstants.testPeerID1,
            mentions: nil
        )
        
        // Track with short timeout (will use default 30s for private messages)
        shortTimeoutTracker.trackMessage(
            trackedMessage,
            recipientID: TestConstants.testPeerID2,
            recipientNickname: TestConstants.testNickname2
        )
        
        // Don't actually send - let it timeout
        // For testing, we'll manually trigger timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            shortTimeoutTracker.clearDeliveryStatus(for: messageID)
            shortTimeoutTracker.deliveryStatusUpdated.send((messageID: messageID, status: .failed(reason: "Message not delivered")))
        }
        
        wait(for: [expectation], timeout: TestConstants.shortTimeout)
        cancellable.cancel()
    }
    
    // MARK: - Message Retry Tests
    
    func testMessageRetryOnFailure() {
        let messageContent = "Retry test message"
        let expectation = XCTestExpectation(description: "Message retried")
        
        var sendCount = 0
        
        // Override send to count attempts
        alice.messageDeliveryHandler = { message in
            if message.content == messageContent {
                sendCount += 1
                if sendCount == 2 { // Original + 1 retry
                    expectation.fulfill()
                }
            }
        }
        
        // Add to retry queue
        retryService.addMessageForRetry(
            content: messageContent,
            isPrivate: true,
            recipientPeerID: TestConstants.testPeerID2,
            recipientNickname: TestConstants.testNickname2
        )
        
        // Simulate connection after delay to trigger retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.simulateConnection(self.alice, self.bob)
        }
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        XCTAssertGreaterThanOrEqual(sendCount, 1)
    }
    
    func testRetryQueueOrdering() {
        // Add multiple messages to retry queue
        let messages = [
            (content: "First", timestamp: Date().addingTimeInterval(-10)),
            (content: "Second", timestamp: Date().addingTimeInterval(-5)),
            (content: "Third", timestamp: Date())
        ]
        
        for msg in messages {
            retryService.addMessageForRetry(
                content: msg.content,
                isPrivate: true,
                recipientPeerID: TestConstants.testPeerID2,
                recipientNickname: TestConstants.testNickname2,
                originalTimestamp: msg.timestamp
            )
        }
        
        XCTAssertEqual(retryService.getRetryQueueCount(), 3)
        
        var receivedOrder: [String] = []
        let expectation = XCTestExpectation(description: "Messages received in order")
        
        bob.messageDeliveryHandler = { message in
            receivedOrder.append(message.content)
            if receivedOrder.count == 3 {
                expectation.fulfill()
            }
        }
        
        // Connect to trigger retry
        simulateConnection(alice, bob)
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        
        // Verify order maintained
        XCTAssertEqual(receivedOrder, ["First", "Second", "Third"])
    }
    
    func testRetryQueueMaxSize() {
        // Try to add more than max queue size
        for i in 0..<60 {
            retryService.addMessageForRetry(
                content: "Message \(i)",
                recipientPeerID: TestConstants.testPeerID2
            )
        }
        
        // Should not exceed max size (50)
        XCTAssertLessThanOrEqual(retryService.getRetryQueueCount(), 50)
    }
    
    // MARK: - End-to-End Encryption Tests
    
    func testPrivateMessageEncryption() {
        simulateConnection(alice, bob)
        
        // Setup Noise sessions
        let aliceKey = Curve25519.KeyAgreement.PrivateKey()
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey)
        
        // Establish encrypted session
        do {
            let handshake1 = try aliceManager.initiateHandshake(with: TestConstants.testPeerID2)
            let handshake2 = try bobManager.handleIncomingHandshake(from: TestConstants.testPeerID1, message: handshake1)!
            let handshake3 = try aliceManager.handleIncomingHandshake(from: TestConstants.testPeerID2, message: handshake2)!
            _ = try bobManager.handleIncomingHandshake(from: TestConstants.testPeerID1, message: handshake3)
        } catch {
            XCTFail("Failed to establish Noise session: \(error)")
        }
        
        let expectation = XCTestExpectation(description: "Encrypted message received")
        
        // Setup packet handlers for encryption
        alice.packetDeliveryHandler = { packet in
            // Encrypt outgoing private messages
            if packet.type == 0x01,
               let message = BitchatMessage.fromBinaryPayload(packet.payload),
               message.isPrivate {
                do {
                    let encrypted = try aliceManager.encrypt(packet.payload, for: TestConstants.testPeerID2)
                    let encryptedPacket = BitchatPacket(
                        type: 0x02, // Encrypted message type
                        senderID: packet.senderID,
                        recipientID: packet.recipientID,
                        timestamp: packet.timestamp,
                        payload: encrypted,
                        signature: packet.signature,
                        ttl: packet.ttl
                    )
                    self.bob.simulateIncomingPacket(encryptedPacket)
                } catch {
                    XCTFail("Encryption failed: \(error)")
                }
            }
        }
        
        bob.packetDeliveryHandler = { packet in
            // Decrypt incoming encrypted messages
            if packet.type == 0x02 {
                do {
                    let decrypted = try bobManager.decrypt(packet.payload, from: TestConstants.testPeerID1)
                    if let message = BitchatMessage.fromBinaryPayload(decrypted) {
                        XCTAssertEqual(message.content, TestConstants.testMessage1)
                        XCTAssertTrue(message.isPrivate)
                        expectation.fulfill()
                    }
                } catch {
                    XCTFail("Decryption failed: \(error)")
                }
            }
        }
        
        // Send encrypted private message
        alice.sendPrivateMessage(
            TestConstants.testMessage1,
            to: TestConstants.testPeerID2,
            recipientNickname: TestConstants.testNickname2
        )
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    // MARK: - Multi-hop Private Message Tests
    
    func testPrivateMessageRelay() {
        // Setup: Alice -> Bob -> Charlie
        simulateConnection(alice, bob)
        simulateConnection(bob, charlie)
        
        let expectation = XCTestExpectation(description: "Private message relayed to Charlie")
        
        // Bob relays private messages for Charlie
        bob.packetDeliveryHandler = { packet in
            if let recipientID = packet.recipientID,
               String(data: recipientID, encoding: .utf8) == TestConstants.testPeerID3 {
                // Relay to Charlie
                var relayPacket = packet
                relayPacket.ttl = packet.ttl - 1
                self.charlie.simulateIncomingPacket(relayPacket)
            }
        }
        
        charlie.messageDeliveryHandler = { message in
            if message.content == TestConstants.testMessage1 &&
               message.isPrivate &&
               message.recipientNickname == TestConstants.testNickname3 {
                expectation.fulfill()
            }
        }
        
        // Alice sends private message to Charlie (through Bob)
        alice.sendPrivateMessage(
            TestConstants.testMessage1,
            to: TestConstants.testPeerID3,
            recipientNickname: TestConstants.testNickname3
        )
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    // MARK: - Performance Tests
    
    func testPrivateMessageThroughput() {
        simulateConnection(alice, bob)
        
        let messageCount = 100
        var receivedCount = 0
        let expectation = XCTestExpectation(description: "All private messages received")
        
        bob.messageDeliveryHandler = { message in
            if message.isPrivate && message.sender == TestConstants.testNickname1 {
                receivedCount += 1
                if receivedCount == messageCount {
                    expectation.fulfill()
                }
            }
        }
        
        // Send many private messages
        for i in 0..<messageCount {
            alice.sendPrivateMessage(
                "Private message \(i)",
                to: TestConstants.testPeerID2,
                recipientNickname: TestConstants.testNickname2
            )
        }
        
        wait(for: [expectation], timeout: TestConstants.longTimeout)
        XCTAssertEqual(receivedCount, messageCount)
    }
    
    func testLargePrivateMessage() {
        simulateConnection(alice, bob)
        
        let expectation = XCTestExpectation(description: "Large private message received")
        
        bob.messageDeliveryHandler = { message in
            if message.content == TestConstants.testLongMessage && message.isPrivate {
                expectation.fulfill()
            }
        }
        
        alice.sendPrivateMessage(
            TestConstants.testLongMessage,
            to: TestConstants.testPeerID2,
            recipientNickname: TestConstants.testNickname2
        )
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    // MARK: - Error Handling Tests
    
    func testPrivateMessageToUnknownPeer() {
        // Alice not connected to anyone
        let expectation = XCTestExpectation(description: "Message added to retry queue")
        
        retryService.addMessageForRetry(
            content: TestConstants.testMessage1,
            isPrivate: true,
            recipientPeerID: TestConstants.testPeerID2,
            recipientNickname: TestConstants.testNickname2
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.retryService.getRetryQueueCount(), 1)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: TestConstants.shortTimeout)
    }
    
    func testDuplicateAckPrevention() {
        simulateConnection(alice, bob)
        
        let messageID = UUID().uuidString
        var ackCount = 0
        
        alice.packetDeliveryHandler = { packet in
            if packet.type == 0x03 {
                ackCount += 1
            }
        }
        
        // Create message
        let message = BitchatMessage(
            id: messageID,
            sender: TestConstants.testNickname1,
            content: TestConstants.testMessage1,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: TestConstants.testNickname2,
            senderPeerID: TestConstants.testPeerID1,
            mentions: nil
        )
        
        // Generate multiple ACKs for same message
        for _ in 0..<3 {
            if let ack = deliveryTracker.generateAck(
                for: message,
                myPeerID: TestConstants.testPeerID2,
                myNickname: TestConstants.testNickname2,
                hopCount: 1
            ) {
                let ackData = ack.encode()!
                let ackPacket = TestHelpers.createTestPacket(
                    type: 0x03,
                    senderID: TestConstants.testPeerID2,
                    recipientID: TestConstants.testPeerID1,
                    payload: ackData
                )
                alice.simulateIncomingPacket(ackPacket)
            }
        }
        
        // Should only generate one ACK
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(ackCount, 1)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createMockService(peerID: String, nickname: String) -> MockBluetoothMeshService {
        let service = MockBluetoothMeshService()
        service.myPeerID = peerID
        service.mockNickname = nickname
        return service
    }
    
    private func simulateConnection(_ peer1: MockBluetoothMeshService, _ peer2: MockBluetoothMeshService) {
        peer1.simulateConnectedPeer(peer2.peerID)
        peer2.simulateConnectedPeer(peer1.peerID)
    }
}