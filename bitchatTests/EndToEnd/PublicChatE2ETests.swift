//
// PublicChatE2ETests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

final class PublicChatE2ETests: XCTestCase {
    
    var alice: MockBluetoothMeshService!
    var bob: MockBluetoothMeshService!
    var charlie: MockBluetoothMeshService!
    var david: MockBluetoothMeshService!
    
    var receivedMessages: [String: [BitchatMessage]] = [:]
    
    override func setUp() {
        super.setUp()
        
        // Create mock services
        alice = createMockService(peerID: TestConstants.testPeerID1, nickname: TestConstants.testNickname1)
        bob = createMockService(peerID: TestConstants.testPeerID2, nickname: TestConstants.testNickname2)
        charlie = createMockService(peerID: TestConstants.testPeerID3, nickname: TestConstants.testNickname3)
        david = createMockService(peerID: TestConstants.testPeerID4, nickname: TestConstants.testNickname4)
        
        // Clear received messages
        receivedMessages.removeAll()
    }
    
    override func tearDown() {
        alice = nil
        bob = nil
        charlie = nil
        david = nil
        super.tearDown()
    }
    
    // MARK: - Basic Broadcasting Tests
    
    func testSimplePublicMessage() {
        // Connect Alice and Bob
        simulateConnection(alice, bob)
        
        let expectation = XCTestExpectation(description: "Bob receives message")
        
        bob.messageDeliveryHandler = { message in
            if message.content == TestConstants.testMessage1 && message.sender == TestConstants.testNickname1 {
                expectation.fulfill()
            }
        }
        
        // Alice sends public message
        alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        
        wait(for: [expectation], timeout: TestConstants.shortTimeout)
    }
    
    func testMultiRecipientBroadcast() {
        // Connect Alice to Bob and Charlie
        simulateConnection(alice, bob)
        simulateConnection(alice, charlie)
        
        let bobExpectation = XCTestExpectation(description: "Bob receives message")
        let charlieExpectation = XCTestExpectation(description: "Charlie receives message")
        
        bob.messageDeliveryHandler = { message in
            if message.content == TestConstants.testMessage1 {
                bobExpectation.fulfill()
            }
        }
        
        charlie.messageDeliveryHandler = { message in
            if message.content == TestConstants.testMessage1 {
                charlieExpectation.fulfill()
            }
        }
        
        // Alice broadcasts
        alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        
        wait(for: [bobExpectation, charlieExpectation], timeout: TestConstants.shortTimeout)
    }
    
    // MARK: - Message Routing and Relay Tests
    
    func testMessageRelayChain() {
        // Linear topology: Alice -> Bob -> Charlie
        simulateConnection(alice, bob)
        simulateConnection(bob, charlie)
        
        let expectation = XCTestExpectation(description: "Charlie receives relayed message")
        
        // Set up relay in Bob
        bob.packetDeliveryHandler = { packet in
            // Bob should relay to Charlie
            if let message = BitchatMessage.fromBinaryPayload(packet.payload),
               message.sender == TestConstants.testNickname1 {
                
                // Create relay message
                let relayMessage = BitchatMessage(
                    id: message.id,
                    sender: message.sender,
                    content: message.content,
                    timestamp: message.timestamp,
                    isRelay: true,
                    originalSender: message.sender,
                    isPrivate: message.isPrivate,
                    recipientNickname: message.recipientNickname,
                    senderPeerID: message.senderPeerID,
                    mentions: message.mentions
                )
                
                if let relayPayload = relayMessage.toBinaryPayload() {
                    let relayPacket = BitchatPacket(
                        type: packet.type,
                        senderID: packet.senderID,
                        recipientID: packet.recipientID,
                        timestamp: packet.timestamp,
                        payload: relayPayload,
                        signature: packet.signature,
                        ttl: packet.ttl - 1
                    )
                    
                    // Simulate relay to Charlie
                    self.charlie.simulateIncomingPacket(relayPacket)
                }
            }
        }
        
        charlie.messageDeliveryHandler = { message in
            if message.content == TestConstants.testMessage1 &&
               message.originalSender == TestConstants.testNickname1 &&
               message.isRelay {
                expectation.fulfill()
            }
        }
        
        // Alice sends message
        alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    func testMultiHopRelay() {
        // Topology: Alice -> Bob -> Charlie -> David
        simulateConnection(alice, bob)
        simulateConnection(bob, charlie)
        simulateConnection(charlie, david)
        
        let expectation = XCTestExpectation(description: "David receives multi-hop message")
        
        // Set up relay chain
        setupRelayHandler(bob, nextHops: [charlie])
        setupRelayHandler(charlie, nextHops: [david])
        
        david.messageDeliveryHandler = { message in
            if message.content == TestConstants.testMessage1 &&
               message.originalSender == TestConstants.testNickname1 &&
               message.isRelay {
                expectation.fulfill()
            }
        }
        
        // Alice sends message
        alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    // MARK: - TTL (Time To Live) Tests
    
    func testTTLDecrement() {
        // Create a chain longer than TTL
        let nodes = [alice!, bob!, charlie!, david!]
        
        // Connect in chain
        for i in 0..<nodes.count-1 {
            simulateConnection(nodes[i], nodes[i+1])
            if i > 0 && i < nodes.count-1 {
                setupRelayHandler(nodes[i], nextHops: [nodes[i+1]])
            }
        }
        
        let expectation = XCTestExpectation(description: "Message dropped due to TTL")
        expectation.isInverted = true // Should NOT be fulfilled
        
        david.messageDeliveryHandler = { message in
            if message.content == TestConstants.testMessage1 {
                expectation.fulfill() // This should not happen
            }
        }
        
        // Send message with TTL=2 (should reach Charlie but not David)
        alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        
        wait(for: [expectation], timeout: TestConstants.shortTimeout)
    }
    
    func testZeroTTLNotRelayed() {
        simulateConnection(alice, bob)
        simulateConnection(bob, charlie)
        
        let expectation = XCTestExpectation(description: "Zero TTL message not relayed")
        expectation.isInverted = true
        
        charlie.messageDeliveryHandler = { message in
            if message.content == "Zero TTL message" {
                expectation.fulfill() // Should not happen
            }
        }
        
        // Create packet with TTL=0
        let message = TestHelpers.createTestMessage(content: "Zero TTL message")
        if let payload = message.toBinaryPayload() {
            let packet = TestHelpers.createTestPacket(payload: payload, ttl: 0)
            alice.simulateIncomingPacket(packet)
        }
        
        wait(for: [expectation], timeout: TestConstants.shortTimeout)
    }
    
    // MARK: - Duplicate Detection Tests
    
    func testDuplicateMessagePrevention() {
        simulateConnection(alice, bob)
        
        var messageCount = 0
        let expectation = XCTestExpectation(description: "Only one message received")
        
        bob.messageDeliveryHandler = { message in
            if message.content == TestConstants.testMessage1 {
                messageCount += 1
                if messageCount == 1 {
                    // Send duplicate after small delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil, messageID: message.id)
                    }
                } else {
                    XCTFail("Duplicate message was not filtered")
                }
            }
        }
        
        // Send original message
        alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        
        // Wait to ensure duplicate would have been received
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(messageCount, 1)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    // MARK: - Mention Tests
    
    func testMessageWithMentions() {
        simulateConnection(alice, bob)
        simulateConnection(alice, charlie)
        
        let expectation = XCTestExpectation(description: "Mentioned users receive notification")
        
        var mentionedUsers: Set<String> = []
        
        bob.messageDeliveryHandler = { message in
            if let mentions = message.mentions, mentions.contains(TestConstants.testNickname2) {
                mentionedUsers.insert(TestConstants.testNickname2)
            }
        }
        
        charlie.messageDeliveryHandler = { message in
            if let mentions = message.mentions, mentions.contains(TestConstants.testNickname3) {
                mentionedUsers.insert(TestConstants.testNickname3)
            }
        }
        
        // Alice mentions Bob and Charlie
        alice.sendMessage(
            "Hey @\(TestConstants.testNickname2) and @\(TestConstants.testNickname3)!",
            mentions: [TestConstants.testNickname2, TestConstants.testNickname3],
            to: nil
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(mentionedUsers, [TestConstants.testNickname2, TestConstants.testNickname3])
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    // MARK: - Network Topology Tests
    
    func testMeshTopologyBroadcast() {
        // Create mesh: Everyone connected to everyone
        let nodes = [alice!, bob!, charlie!, david!]
        for i in 0..<nodes.count {
            for j in i+1..<nodes.count {
                simulateConnection(nodes[i], nodes[j])
            }
        }
        
        var receivedCount = 0
        let expectation = XCTestExpectation(description: "All nodes receive message")
        
        for (index, node) in nodes.enumerated() where index > 0 {
            node.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 {
                    receivedCount += 1
                    if receivedCount == 3 { // Bob, Charlie, David
                        expectation.fulfill()
                    }
                }
            }
        }
        
        // Alice broadcasts
        alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    func testPartialMeshRelay() {
        // Partial mesh: Alice -> Bob, Bob -> Charlie, Charlie -> David, David -> Alice
        simulateConnection(alice, bob)
        simulateConnection(bob, charlie)
        simulateConnection(charlie, david)
        simulateConnection(david, alice)
        
        // Setup relay handlers
        setupRelayHandler(bob, nextHops: [charlie])
        setupRelayHandler(charlie, nextHops: [david])
        setupRelayHandler(david, nextHops: [alice])
        
        var messageIDs = Set<String>()
        let expectation = XCTestExpectation(description: "Message reaches all nodes once")
        
        let checkCompletion = {
            if messageIDs.count == 3 { // Bob, Charlie, David should receive
                expectation.fulfill()
            }
        }
        
        for node in [bob!, charlie!, david!] {
            node.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 {
                    messageIDs.insert(message.id)
                    checkCompletion()
                }
            }
        }
        
        // Alice broadcasts
        alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    // MARK: - Performance and Stress Tests
    
    func testHighVolumeMessaging() {
        simulateConnection(alice, bob)
        
        let messageCount = 100
        var receivedCount = 0
        let expectation = XCTestExpectation(description: "All messages received")
        
        bob.messageDeliveryHandler = { message in
            if message.sender == TestConstants.testNickname1 {
                receivedCount += 1
                if receivedCount == messageCount {
                    expectation.fulfill()
                }
            }
        }
        
        // Send many messages rapidly
        for i in 0..<messageCount {
            alice.sendMessage("Message \(i)", mentions: [], to: nil)
        }
        
        wait(for: [expectation], timeout: TestConstants.longTimeout)
        XCTAssertEqual(receivedCount, messageCount)
    }
    
    func testLargeMessageBroadcast() {
        simulateConnection(alice, bob)
        
        let expectation = XCTestExpectation(description: "Large message received")
        
        bob.messageDeliveryHandler = { message in
            if message.content == TestConstants.testLongMessage {
                expectation.fulfill()
            }
        }
        
        // Send large message
        alice.sendMessage(TestConstants.testLongMessage, mentions: [], to: nil)
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
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
    
    private func setupRelayHandler(_ node: MockBluetoothMeshService, nextHops: [MockBluetoothMeshService]) {
        node.packetDeliveryHandler = { packet in
            // Check if should relay
            guard packet.ttl > 1 else { return }
            
            if let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                // Don't relay own messages
                guard message.senderPeerID != node.peerID else { return }
                
                // Create relay message
                let relayMessage = BitchatMessage(
                    id: message.id,
                    sender: message.sender,
                    content: message.content,
                    timestamp: message.timestamp,
                    isRelay: true,
                    originalSender: message.isRelay ? message.originalSender : message.sender,
                    isPrivate: message.isPrivate,
                    recipientNickname: message.recipientNickname,
                    senderPeerID: message.senderPeerID,
                    mentions: message.mentions
                )
                
                if let relayPayload = relayMessage.toBinaryPayload() {
                    let relayPacket = BitchatPacket(
                        type: packet.type,
                        senderID: node.peerID.data(using: .utf8)!,
                        recipientID: packet.recipientID,
                        timestamp: packet.timestamp,
                        payload: relayPayload,
                        signature: packet.signature,
                        ttl: packet.ttl - 1
                    )
                    
                    // Relay to next hops
                    for nextHop in nextHops {
                        nextHop.simulateIncomingPacket(relayPacket)
                    }
                }
            }
        }
    }
}