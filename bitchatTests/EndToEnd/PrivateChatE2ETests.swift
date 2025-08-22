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
    
    override func setUp() {
        super.setUp()
        MockBLEService.resetTestBus()
        
        // Create services
        alice = createMockService(peerID: TestConstants.testPeerID1, nickname: TestConstants.testNickname1)
        bob = createMockService(peerID: TestConstants.testPeerID2, nickname: TestConstants.testNickname2)
        charlie = createMockService(peerID: TestConstants.testPeerID3, nickname: TestConstants.testNickname3)
        
        // Delivery tracking is now handled internally by BLEService
    }
    
    override func tearDown() {
        alice = nil
        bob = nil
        charlie = nil
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
        
        // Small delay to ensure connections are registered before send
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Alice sends private message to Bob only
            self.alice.sendPrivateMessage(
                TestConstants.testMessage1,
                to: TestConstants.testPeerID2,
                recipientNickname: TestConstants.testNickname2
            )
        }
        
        wait(for: [bobExpectation, charlieExpectation], timeout: TestConstants.shortTimeout)
    }
    
    // MARK: - Delivery Acknowledgment Tests
    
    // NOTE: DeliveryTracker has been removed in BLEService.
    // Delivery tracking is now handled internally.
    
    
    // MARK: - Message Retry Tests
    
    // NOTE: MessageRetryService has been removed in BLEService.
    // Retry logic is now handled internally.
    
    
    
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
    
    // NOTE: This test relied on MessageRetryService which has been removed
    
    func testDuplicateAckPrevention() throws {
        throw XCTSkip("DeliveryTracker/ACK flow removed; test not applicable")
    }
    
    // MARK: - Helper Methods
    
    private func createMockService(peerID: String, nickname: String) -> MockBluetoothMeshService {
        let service = MockBluetoothMeshService()
        service.myPeerID = peerID
        service.mockNickname = nickname
        service._testRegister()
        return service
    }
    
    private func simulateConnection(_ peer1: MockBluetoothMeshService, _ peer2: MockBluetoothMeshService) {
        peer1.simulateConnectedPeer(peer2.peerID)
        peer2.simulateConnectedPeer(peer1.peerID)
    }
}
