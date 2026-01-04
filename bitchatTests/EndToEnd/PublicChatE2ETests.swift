//
// PublicChatE2ETests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import struct Foundation.UUID
@testable import bitchat

struct PublicChatE2ETests {
    
    private let alice: MockBLEService
    private let bob: MockBLEService
    private let charlie: MockBLEService
    private let david: MockBLEService
    private let bus = MockBLEBus()
    
    private var receivedMessages: [String: [BitchatMessage]] = [:]
    
    init() {
        // Create mock services with unique peer IDs to avoid any collision
        alice = MockBLEService(peerID: PeerID(str: UUID().uuidString), nickname: TestConstants.testNickname1, bus: bus)
        bob = MockBLEService(peerID: PeerID(str: UUID().uuidString), nickname: TestConstants.testNickname2, bus: bus)
        charlie = MockBLEService(peerID: PeerID(str: UUID().uuidString), nickname: TestConstants.testNickname3, bus: bus)
        david = MockBLEService(peerID: PeerID(str: UUID().uuidString), nickname: TestConstants.testNickname4, bus: bus)
    }
    
    // MARK: - Basic Broadcasting Tests
    
    @Test func simplePublicMessage() async {
        alice.simulateConnection(with: bob)
        
        await confirmation("Bob receives message") { bobReceivesMessage in
            bob.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 && message.sender == TestConstants.testNickname1 {
                    bobReceivesMessage()
                }
            }
            
            alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        }
    }
    
    @Test func multiRecipientBroadcast() async {
        alice.simulateConnection(with: bob)
        alice.simulateConnection(with: charlie)
        
        var bobReceivedMessage = false
        var charlieReceivedMessage = false
        
        await confirmation("Both recieve message", expectedCount: 2) { receiveMessage in
            bob.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 {
                    if !bobReceivedMessage {
                        bobReceivedMessage = true
                        receiveMessage()
                    } else {
                        Issue.record("Bob received more than once")
                    }
                }
            }
            
            charlie.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 {
                    if !charlieReceivedMessage {
                        charlieReceivedMessage = true
                        receiveMessage()
                    } else {
                        Issue.record("Charlie received more than once")
                    }
                }
            }
            
            alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        }
    }
    
    // MARK: - Message Routing and Relay Tests
    
    @Test func messageRelayChain() async {
        // Linear topology: Alice -> Bob -> Charlie
        alice.simulateConnection(with: bob)
        bob.simulateConnection(with: charlie)

        await confirmation("Charlie receives relayed message") { charlieReceivesMessage in
            // Set up relay in Bob
            bob.packetDeliveryHandler = { packet in
                // Bob should relay to Charlie
                if let message = BitchatMessage(packet.payload),
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
                    charlieReceivesMessage()
                }
            }

            alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        }
    }
    
    @Test func multiHopRelay() async {
        // Topology: Alice -> Bob -> Charlie -> David
        alice.simulateConnection(with: bob)
        bob.simulateConnection(with: charlie)
        charlie.simulateConnection(with: david)
        
        await confirmation("David receives multi-hop message") { davidReceivesMessage in
            // Set up relay chain
            setupRelayHandler(bob, nextHops: [charlie])
            setupRelayHandler(charlie, nextHops: [david])
            
            david.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 &&
                   message.originalSender == TestConstants.testNickname1 &&
                   message.isRelay {
                    davidReceivesMessage()
                }
            }
            
            alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        }
    }
    
    // MARK: - TTL (Time To Live) Tests
    
    @Test func ttlDecrement() async {
        // Create a chain longer than TTL
        let nodes = [alice, bob, charlie, david]
        
        // Connect in chain
        for i in 0..<nodes.count-1 {
            nodes[i].simulateConnection(with: nodes[i+1])
            if i > 0 && i < nodes.count-1 {
                setupRelayHandler(nodes[i], nextHops: [nodes[i+1]])
            }
        }
        
        await confirmation("Message dropped due to TTL", expectedCount: 0) { receiveMessage in
            david.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 {
                    receiveMessage() // This should not happen
                }
            }
            
            // Inject at Bob with TTL=2 so Charlie sees it (TTL->1) and does not relay to David
            let msg = TestHelpers.createTestMessage(
                content: TestConstants.testMessage1,
                sender: TestConstants.testNickname1,
                senderPeerID: alice.peerID
            )

            if let payload = msg.toBinaryPayload() {
                let pkt = TestHelpers.createTestPacket(senderID: alice.peerID, payload: payload, ttl: 2)
                bob.simulateIncomingPacket(pkt)
            }
        }
    }
    
    @Test func zeroTTLNotRelayed() async {
        alice.simulateConnection(with: bob)
        bob.simulateConnection(with: charlie)
        
        await confirmation("Zero TTL message not relayed", expectedCount: 0) { receiveMessage in
            charlie.messageDeliveryHandler = { message in
                if message.content == "Zero TTL message" {
                    receiveMessage() // Should not happen
                }
            }
            
            // Create packet with TTL=0
            let message = TestHelpers.createTestMessage(content: "Zero TTL message")
            if let payload = message.toBinaryPayload() {
                let packet = TestHelpers.createTestPacket(payload: payload, ttl: 0)
                alice.simulateIncomingPacket(packet)
            }
        }
    }
    
    // MARK: - Duplicate Detection Tests
    
    @Test func duplicateMessagePrevention() async {
        alice.simulateConnection(with: bob)
        
        var messageCount = 0
        
        await confirmation("Only one message received") { receiveMessage in
            bob.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 {
                    receiveMessage()
                    messageCount += 1
                    if messageCount == 1 {
                        // Send duplicate after small delay
                        alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil, messageID: message.id)
                    } else {
                        Issue.record("Duplicate message was not filtered")
                    }
                }
            }
            
            // Send original message
            alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        }
    }
    
    @Test func duplicateContentAsNewMessageNotPrevented() async {
        alice.simulateConnection(with: bob)
        
        var messageCount = 0
        
        await confirmation("Only one message received", expectedCount: 2) { receiveMessage in
            bob.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 {
                    receiveMessage()
                    messageCount += 1
                    if messageCount == 1 {
                        // Send the same content as a new message
                        alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
                    }
                }
            }
            
            // Send original message
            alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        }
    }
    
    // MARK: - Mention Tests
    
    @Test func messageWithMentions() async {
        alice.simulateConnection(with: bob)
        alice.simulateConnection(with: charlie)
        
        var mentionedUsers: Set<String> = []
        
        await confirmation("Mentioned users receive notification", expectedCount: 2) { receiveMention in
            bob.messageDeliveryHandler = { message in
                if message.mentions?.contains(TestConstants.testNickname2) == true {
                    mentionedUsers.insert(TestConstants.testNickname2)
                    receiveMention()
                }
            }
            
            charlie.messageDeliveryHandler = { message in
                if message.mentions?.contains(TestConstants.testNickname3) == true {
                    mentionedUsers.insert(TestConstants.testNickname3)
                    receiveMention()
                }
            }
            
            // Alice mentions Bob and Charlie
            alice.sendMessage(
                "Hey @\(TestConstants.testNickname2) and @\(TestConstants.testNickname3)!",
                mentions: [TestConstants.testNickname2, TestConstants.testNickname3],
                to: nil
            )
        }
        
        #expect(mentionedUsers == [TestConstants.testNickname2, TestConstants.testNickname3])
    }
    
    // MARK: - Network Topology Tests
    
    @Test func meshTopologyBroadcast() async {
        // Create mesh: Everyone connected to everyone
        let nodes = [alice, bob, charlie, david]
        for i in 0..<nodes.count {
            for j in i+1..<nodes.count {
                nodes[i].simulateConnection(with: nodes[j])
            }
        }
        
        await confirmation("All nodes receive message", expectedCount: 3) { receiveMessage in
            for (index, node) in nodes.enumerated() where index > 0 {
                node.messageDeliveryHandler = { message in
                    if message.content == TestConstants.testMessage1 {
                        receiveMessage()
                    }
                }
            }
            
            alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        }
    }
    
    @Test func partialMeshRelay() async {
        // Partial mesh: Alice -> Bob, Bob -> Charlie, Charlie -> David, David -> Alice
        alice.simulateConnection(with: bob)
        bob.simulateConnection(with: charlie)
        charlie.simulateConnection(with: david)
        david.simulateConnection(with: alice)
        
        // Setup relay handlers
        setupRelayHandler(bob, nextHops: [charlie])
        setupRelayHandler(charlie, nextHops: [david])
        setupRelayHandler(david, nextHops: [alice])
        
        await confirmation("Message reaches all nodes once", expectedCount: 3) { receiveMessage in
            for node in [bob, charlie, david] {
                node.messageDeliveryHandler = { message in
                    if message.content == TestConstants.testMessage1 {
                        receiveMessage()
                    }
                }
            }
            
            alice.sendMessage(TestConstants.testMessage1, mentions: [], to: nil)
        }
    }
    
    // MARK: - Performance and Stress Tests
    
    @Test func highVolumeMessaging() async {
        alice.simulateConnection(with: bob)
        
        let messageCount = 100
        
        await confirmation("All messages received", expectedCount: messageCount) { receiveMessage in
            bob.messageDeliveryHandler = { message in
                if message.sender == TestConstants.testNickname1 {
                    receiveMessage()
                }
            }
            
            // Send many messages rapidly
            for i in 0..<messageCount {
                alice.sendMessage("Message \(i)", mentions: [], to: nil)
            }
        }
    }
    
    @Test func largeMessageBroadcast() async {
        alice.simulateConnection(with: bob)
        
        await confirmation("Large message received") { receiveLargeMessage in
            bob.messageDeliveryHandler = { message in
                if message.content == TestConstants.testLongMessage {
                    receiveLargeMessage()
                }
            }
            
            alice.sendMessage(TestConstants.testLongMessage, mentions: [], to: nil)
        }
    }
    
    // MARK: - Helper Methods

    private func setupRelayHandler(_ node: MockBLEService, nextHops: [MockBLEService]) {
        node.packetDeliveryHandler = { packet in
            // Check if should relay
            guard packet.ttl > 1 else { return }

            if let message = BitchatMessage(packet.payload) {
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
                        senderID: node.peerID.id.data(using: .utf8)!,
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
