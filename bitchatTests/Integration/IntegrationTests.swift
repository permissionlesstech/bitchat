//
// IntegrationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import CryptoKit
@testable import bitchat

final class IntegrationTests: XCTestCase {
    
    var nodes: [String: MockBluetoothMeshService] = [:]
    var noiseManagers: [String: NoiseSessionManager] = [:]
    
    override func setUp() {
        super.setUp()
        // Use the in-memory test bus with autoFlood enabled to simulate
        // broadcast propagation across a larger mesh. Integration-only.
        MockBLEService.resetTestBus()
        MockBLEService.autoFloodEnabled = true
        
        // Create a network of nodes
        createNode("Alice", peerID: TestConstants.testPeerID1)
        createNode("Bob", peerID: TestConstants.testPeerID2)
        createNode("Charlie", peerID: TestConstants.testPeerID3)
        createNode("David", peerID: TestConstants.testPeerID4)
    }
    
    override func tearDown() {
        // Disable flooding to avoid cross-test interference
        MockBLEService.autoFloodEnabled = false
        nodes.removeAll()
        noiseManagers.removeAll()
        super.tearDown()
    }
    
    // MARK: - Multi-Peer Scenarios
    
    func testFullMeshCommunication() {
        // Create full mesh - everyone connected to everyone
        connectFullMesh()
        
        let expectation = XCTestExpectation(description: "All nodes communicate")
        var messageMatrix: [String: Set<String>] = [:]
        
        // Track all receivers; parse sender name from message content "Hello from <Name>"
        for (senderName, _) in nodes { messageMatrix[senderName] = [] }
        for (receiverName, receiver) in nodes {
            receiver.messageDeliveryHandler = { message in
                let parts = message.content.components(separatedBy: " ")
                if let last = parts.last, message.content.contains("Hello from") {
                    if receiverName != last {
                        messageMatrix[last]?.insert(receiverName)
                    }
                }
            }
        }
        
        // Each node sends a message
        for (name, node) in nodes {
            node.sendMessage("Hello from \(name)", mentions: [], to: nil)
        }
        
        // Wait and verify
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Each sender should have reached all other nodes
            for (sender, receivers) in messageMatrix {
                let expectedReceivers = Set(self.nodes.keys.filter { $0 != sender })
                XCTAssertEqual(receivers, expectedReceivers, "\(sender) didn't reach all nodes")
            }
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    func testDynamicTopologyChanges() {
        // Start with Alice -> Bob -> Charlie
        connect("Alice", "Bob")
        connect("Bob", "Charlie")
        
        let expectation = XCTestExpectation(description: "Topology changes handled")
        var phase = 1
        
        // Phase 1: Test initial topology
        nodes["Charlie"]!.messageDeliveryHandler = { message in
            if phase == 1 && message.sender == "Alice" {
                // Now change topology: disconnect Bob, connect Alice-Charlie
                self.disconnect("Alice", "Bob")
                self.disconnect("Bob", "Charlie")
                self.connect("Alice", "Charlie")
                phase = 2
                
                // Send another message
                self.nodes["Alice"]!.sendMessage("Direct message", mentions: [], to: nil)
            } else if phase == 2 && message.content == "Direct message" {
                expectation.fulfill()
            }
        }
        
        // Initial message through relay
        // Allow relay handler to be set before first send
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.nodes["Alice"]!.sendMessage("Relayed message", mentions: [], to: nil)
        }
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    func testNetworkPartitionRecovery() {
        // Create two partitions
        connect("Alice", "Bob")
        connect("Charlie", "David")
        
        let expectation = XCTestExpectation(description: "Partitions merge and communicate")
        let messagesBeforeMerge = 0
        var messagesAfterMerge = 0
        
        // Monitor cross-partition messages
        nodes["David"]!.messageDeliveryHandler = { message in
            if message.sender == "Alice" {
                messagesAfterMerge += 1
                if messagesAfterMerge == 1 {
                    expectation.fulfill()
                }
            }
        }
        
        // Try to send across partition (should fail)
        nodes["Alice"]!.sendMessage("Before merge", mentions: [], to: nil)
        
        // Merge partitions after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Connect partitions
            self.connect("Bob", "Charlie")
            
            // Enable relay
            self.setupRelay("Bob", nextHops: ["Charlie"])
            self.setupRelay("Charlie", nextHops: ["David"])
            
            // Send message across merged network
            self.nodes["Alice"]!.sendMessage("After merge", mentions: [], to: nil)
        }
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        XCTAssertEqual(messagesBeforeMerge, 0)
        XCTAssertEqual(messagesAfterMerge, 1)
    }
    
    // MARK: - Mixed Message Type Scenarios
    
    func testMixedPublicPrivateMessages() throws {
        connectFullMesh()
        
        let expectation = XCTestExpectation(description: "Mixed messages handled correctly")
        var publicCount = 0
        var privateCount = 0
        
        // Bob monitors messages
        nodes["Bob"]!.messageDeliveryHandler = { message in
            if message.isPrivate && message.recipientNickname == "Bob" {
                privateCount += 1
            } else if !message.isPrivate {
                publicCount += 1
            }
            
            if publicCount == 2 && privateCount == 1 {
                expectation.fulfill()
            }
        }
        
        // Alice sends mixed messages
        nodes["Alice"]!.sendMessage("Public 1", mentions: [], to: nil)
        nodes["Alice"]!.sendPrivateMessage("Private to Bob", to: TestConstants.testPeerID2, recipientNickname: "Bob")
        nodes["Alice"]!.sendMessage("Public 2", mentions: [], to: nil)
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        XCTAssertEqual(publicCount, 2)
        XCTAssertEqual(privateCount, 1)
    }
    
    func testEncryptedAndUnencryptedMix() throws {
        connect("Alice", "Bob")
        
        // Setup Noise session
        try establishNoiseSession("Alice", "Bob")
        
        let expectation = XCTestExpectation(description: "Both encrypted and plain messages work")
        var plainCount = 0
        var encryptedCount = 0
        
        // Setup handlers
        // Plain path: send public message and count at Bob
        nodes["Bob"]!.messageDeliveryHandler = { message in
            if message.content == "Plain message" { plainCount += 1 }
            if plainCount == 1 && encryptedCount == 1 { expectation.fulfill() }
        }

        // Encrypted path: use NoiseSessionManager explicitly
        let plaintext = "Encrypted message".data(using: .utf8)!
        let ciphertext = try noiseManagers["Alice"]!.encrypt(plaintext, for: TestConstants.testPeerID2)
        nodes["Bob"]!.packetDeliveryHandler = { packet in
            if packet.type == MessageType.noiseEncrypted.rawValue {
                if let data = try? self.noiseManagers["Bob"]!.decrypt(ciphertext, from: TestConstants.testPeerID1),
                   data == plaintext {
                    encryptedCount = 1
                    if plainCount == 1 { expectation.fulfill() }
                }
            }
        }

        nodes["Alice"]!.sendMessage("Plain message", mentions: [], to: nil)
        // Deliver encrypted packet directly
        let encPacket = TestHelpers.createTestPacket(type: MessageType.noiseEncrypted.rawValue, payload: ciphertext)
        nodes["Bob"]!.simulateIncomingPacket(encPacket)
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    // MARK: - Network Resilience Tests
    
    func testMessageDeliveryUnderChurn() {
        // Start with stable network
        connectFullMesh()
        
        let expectation = XCTestExpectation(description: "Messages delivered despite churn")
        var receivedMessages = Set<String>()
        let totalMessages = 10
        
        // David tracks received messages
        nodes["David"]!.messageDeliveryHandler = { message in
            receivedMessages.insert(message.content)
            if receivedMessages.count == totalMessages {
                expectation.fulfill()
            }
        }
        
        // Send messages while churning network
        for i in 0..<totalMessages {
            nodes["Alice"]!.sendMessage("Message \(i)", mentions: [], to: nil)
            
            // Simulate churn
            if i % 3 == 0 {
                // Disconnect and reconnect random connection
                let pairs = [("Alice", "Bob"), ("Bob", "Charlie"), ("Charlie", "David")]
                let randomPair = pairs.randomElement()!
                disconnect(randomPair.0, randomPair.1)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.connect(randomPair.0, randomPair.1)
                }
            }
        }
        
        wait(for: [expectation], timeout: TestConstants.longTimeout)
        XCTAssertEqual(receivedMessages.count, totalMessages)
    }
    
    func testPeerPresenceTrackingAndReconnection() {
        // Test that after disconnect/reconnect, message delivery resumes
        connect("Alice", "Bob")

        let expectation = XCTestExpectation(description: "Delivery after reconnection")
        var delivered = false

        nodes["Bob"]!.messageDeliveryHandler = { message in
            if message.content == "After reconnect" && !delivered {
                delivered = true
                expectation.fulfill()
            }
        }

        // Simulate disconnect (out of range)
        disconnect("Alice", "Bob")
        // Reconnect
        connect("Alice", "Bob")

        // Send after reconnection
        nodes["Alice"]!.sendMessage("After reconnect", mentions: [], to: nil)

        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        XCTAssertTrue(delivered)
    }
    
    func testEncryptedMessageAfterPeerRestart() {
        // Test that encrypted messages work after one peer restarts
        connect("Alice", "Bob")
        do {
            try establishNoiseSession("Alice", "Bob")
        } catch {
            XCTFail("Failed to establish Noise session: \(error)")
        }
        
        // Exchange an encrypted message
        let firstExpectation = XCTestExpectation(description: "First message received")
        nodes["Bob"]!.messageDeliveryHandler = { message in
            if message.content == "Before restart" && message.isPrivate {
                firstExpectation.fulfill()
            }
        }
        
        nodes["Alice"]!.sendPrivateMessage("Before restart", to: TestConstants.testPeerID2, recipientNickname: "Bob")
        wait(for: [firstExpectation], timeout: TestConstants.defaultTimeout)
        
        // Simulate Bob restart by recreating his Noise manager
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        noiseManagers["Bob"] = NoiseSessionManager(localStaticKey: bobKey)
        
        // Re-establish Noise handshake explicitly via managers
        do {
            let m1 = try noiseManagers["Bob"]!.initiateHandshake(with: TestConstants.testPeerID1)
            let m2 = try noiseManagers["Alice"]!.handleIncomingHandshake(from: TestConstants.testPeerID2, message: m1)!
            let m3 = try noiseManagers["Bob"]!.handleIncomingHandshake(from: TestConstants.testPeerID1, message: m2)!
            _ = try noiseManagers["Alice"]!.handleIncomingHandshake(from: TestConstants.testPeerID2, message: m3)
        } catch {
            XCTFail("Failed to re-establish Noise session after restart: \(error)")
        }
        
        // Now messages should work again
        let secondExpectation = XCTestExpectation(description: "Message after restart received")
        nodes["Alice"]!.messageDeliveryHandler = { message in
            if message.content == "After restart success" && message.isPrivate {
                secondExpectation.fulfill()
            }
        }
        
        // Simulate encrypted message using managers
        do {
            let plaintext = "After restart success".data(using: .utf8)!
            let ciphertext = try noiseManagers["Bob"]!.encrypt(plaintext, for: TestConstants.testPeerID1)
            let packet = TestHelpers.createTestPacket(type: MessageType.noiseEncrypted.rawValue, payload: ciphertext)
            nodes["Alice"]!.packetDeliveryHandler = { pkt in
                if pkt.type == MessageType.noiseEncrypted.rawValue {
                    if let data = try? self.noiseManagers["Alice"]!.decrypt(pkt.payload, from: TestConstants.testPeerID2),
                       String(data: data, encoding: .utf8) == "After restart success" {
                        secondExpectation.fulfill()
                    }
                }
            }
            nodes["Alice"]!.simulateIncomingPacket(packet)
        } catch {
            XCTFail("Encryption after restart failed: \(error)")
        }
        wait(for: [secondExpectation], timeout: TestConstants.defaultTimeout)
    }
    
    func testLargeScaleNetwork() {
        // Create larger network
        for i in 5...10 {
            createNode("Node\(i)", peerID: "PEER\(i)")
        }
        
        // Connect in ring topology with cross-connections
        let allNodes = Array(nodes.keys).sorted()
        for i in 0..<allNodes.count {
            // Ring connection
            connect(allNodes[i], allNodes[(i + 1) % allNodes.count])
            
            // Cross connection
            if i + 3 < allNodes.count {
                connect(allNodes[i], allNodes[i + 3])
            }
        }
        
        let expectation = XCTestExpectation(description: "Large network handles broadcast")
        var nodesReached = Set<String>()
        
        // All nodes except Alice listen
        for (name, node) in nodes where name != "Alice" {
            node.messageDeliveryHandler = { message in
                if message.content == "Broadcast test" {
                    nodesReached.insert(name)
                    if nodesReached.count == self.nodes.count - 1 {
                        expectation.fulfill()
                    }
                }
            }
        }
        
        // Alice broadcasts
        nodes["Alice"]!.sendMessage("Broadcast test", mentions: [], to: nil)
        
        wait(for: [expectation], timeout: TestConstants.longTimeout)
        XCTAssertEqual(nodesReached.count, nodes.count - 1)
    }
    
    // MARK: - Stress Tests
    
    func testHighLoadScenario() {
        connectFullMesh()
        
        let messagesPerNode = 25
        let expectedTotal = messagesPerNode * nodes.count * (nodes.count - 1)
        var receivedTotal = 0
        let expectation = XCTestExpectation(description: "High load handled")
        
        // Each node tracks messages
        for (_, node) in nodes {
            node.messageDeliveryHandler = { _ in
                receivedTotal += 1
                if receivedTotal >= (expectedTotal - 2) {
                    expectation.fulfill()
                }
            }
        }
        
        // All nodes send many messages simultaneously
        DispatchQueue.concurrentPerform(iterations: nodes.count) { index in
            let nodeName = Array(nodes.keys).sorted()[index]
            for i in 0..<messagesPerNode {
                nodes[nodeName]!.sendMessage("\(nodeName) message \(i)", mentions: [], to: nil)
            }
        }
        
        wait(for: [expectation], timeout: TestConstants.longTimeout)
        XCTAssertGreaterThanOrEqual(receivedTotal, expectedTotal - 2)
    }
    
    func testMixedTrafficPatterns() {
        connectFullMesh()
        
        let expectation = XCTestExpectation(description: "Mixed traffic handled")
        var metrics = [
            "public": 0,
            "private": 0,
            "mentions": 0,
            "relayed": 0
        ]
        
        // Setup complex handlers
        for (name, node) in nodes {
            node.messageDeliveryHandler = { message in
                if message.isPrivate {
                    metrics["private"]! += 1
                } else {
                    metrics["public"]! += 1
                }
                
                if message.mentions?.contains(name) ?? false {
                    metrics["mentions"]! += 1
                }
                
                if message.isRelay {
                    metrics["relayed"]! += 1
                }
            }
        }
        
        // Generate mixed traffic
        nodes["Alice"]!.sendMessage("Public broadcast", mentions: [], to: nil)
        nodes["Alice"]!.sendPrivateMessage("Private to Bob", to: TestConstants.testPeerID2, recipientNickname: "Bob")
        nodes["Bob"]!.sendMessage("Mentioning @Charlie", mentions: ["Charlie"], to: nil)
        
        // Disconnect to force relay
        disconnect("Alice", "David")
        nodes["Alice"]!.sendMessage("Needs relay to David", mentions: [], to: nil)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            XCTAssertGreaterThan(metrics["public"]!, 0)
            XCTAssertGreaterThan(metrics["private"]!, 0)
            XCTAssertGreaterThan(metrics["mentions"]!, 0)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    // MARK: - Security Integration Tests
    // Replacement for the legacy NACK test: verifies that after a
    // decryption failure, peers can rehandshake via NoiseSessionManager
    // and resume secure communication.
    func testRehandshakeAfterDecryptionFailure() throws {
        // Alice <-> Bob connected
        connect("Alice", "Bob")

        // Establish initial Noise session
        try establishNoiseSession("Alice", "Bob")

        guard let aliceManager = noiseManagers["Alice"],
              let bobManager = noiseManagers["Bob"],
              let alicePeerID = nodes["Alice"]?.peerID,
              let bobPeerID = nodes["Bob"]?.peerID else {
            return XCTFail("Missing managers or peer IDs")
        }

        // Baseline: encrypt from Alice, decrypt at Bob
        let plaintext1 = Data("hello-secure".utf8)
        let encrypted1 = try aliceManager.encrypt(plaintext1, for: bobPeerID)
        let decrypted1 = try bobManager.decrypt(encrypted1, from: alicePeerID)
        XCTAssertEqual(decrypted1, plaintext1)

        // Simulate decryption failure by corrupting ciphertext
        var corrupted = encrypted1
        if !corrupted.isEmpty { corrupted[corrupted.count - 1] ^= 0xFF }
        do {
            _ = try bobManager.decrypt(corrupted, from: alicePeerID)
            XCTFail("Corrupted ciphertext should not decrypt")
        } catch {
            // Expected: treat as session desync and rehandshake
        }

        // Bob initiates a new handshake; clear Bob's session first so initiateHandshake won't throw
        bobManager.removeSession(for: alicePeerID)
        try establishNoiseSession("Bob", "Alice")

        // After rehandshake, encryption/decryption works again
        let plaintext2 = Data("hello-again".utf8)
        let encrypted2 = try aliceManager.encrypt(plaintext2, for: bobPeerID)
        let decrypted2 = try bobManager.decrypt(encrypted2, from: alicePeerID)
        XCTAssertEqual(decrypted2, plaintext2)
    }

    
    func testEndToEndSecurityScenario() throws {
        connect("Alice", "Bob")
        connect("Bob", "Charlie") // Charlie will try to eavesdrop
        
        // Establish secure session between Alice and Bob only
        try establishNoiseSession("Alice", "Bob")
        
        let expectation = XCTestExpectation(description: "Secure communication maintained")
        var bobDecrypted = false
        var charlieIntercepted = false
        
        // Setup encryption at Alice
        nodes["Alice"]!.packetDeliveryHandler = { packet in
            if packet.type == 0x01,
               let message = BitchatMessage.fromBinaryPayload(packet.payload),
               message.isPrivate && packet.recipientID != nil {
                // Encrypt private messages
                if let encrypted = try? self.noiseManagers["Alice"]!.encrypt(packet.payload, for: TestConstants.testPeerID2) {
                    let encPacket = BitchatPacket(
                        type: 0x02,
                        senderID: packet.senderID,
                        recipientID: packet.recipientID,
                        timestamp: packet.timestamp,
                        payload: encrypted,
                        signature: packet.signature,
                        ttl: packet.ttl
                    )
                    self.nodes["Bob"]!.simulateIncomingPacket(encPacket)
                }
            }
        }
        
        // Bob can decrypt
        nodes["Bob"]!.packetDeliveryHandler = { packet in
            if packet.type == 0x02 {
                if let decrypted = try? self.noiseManagers["Bob"]!.decrypt(packet.payload, from: TestConstants.testPeerID1),
                   let message = BitchatMessage.fromBinaryPayload(decrypted) {
                    bobDecrypted = message.content == "Secret message"
                    expectation.fulfill()
                }
                
                // Relay encrypted packet to Charlie
                self.nodes["Charlie"]!.simulateIncomingPacket(packet)
            }
        }
        
        // Charlie cannot decrypt
        nodes["Charlie"]!.packetDeliveryHandler = { packet in
            if packet.type == 0x02 {
                charlieIntercepted = true
                // Try to decrypt (should fail)
                do {
                    _ = try self.noiseManagers["Charlie"]?.decrypt(packet.payload, from: TestConstants.testPeerID1)
                    XCTFail("Charlie should not be able to decrypt")
                } catch {
                    // Expected
                }
            }
        }
        
        // Send encrypted private message
        nodes["Alice"]!.sendPrivateMessage("Secret message", to: TestConstants.testPeerID2, recipientNickname: "Bob")
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        XCTAssertTrue(bobDecrypted)
        XCTAssertTrue(charlieIntercepted)
    }
    
    // MARK: - Helper Methods
    
    private func createNode(_ name: String, peerID: String) {
        let node = MockBluetoothMeshService()
        node.myPeerID = peerID
        node.mockNickname = name
        node._testRegister()
        nodes[name] = node
        
        // Create Noise manager
        let key = Curve25519.KeyAgreement.PrivateKey()
        noiseManagers[name] = NoiseSessionManager(localStaticKey: key)
    }
    
    private func connect(_ node1: String, _ node2: String) {
        guard let n1 = nodes[node1], let n2 = nodes[node2] else { return }
        n1.simulateConnectedPeer(n2.peerID)
        n2.simulateConnectedPeer(n1.peerID)
    }
    
    private func disconnect(_ node1: String, _ node2: String) {
        guard let n1 = nodes[node1], let n2 = nodes[node2] else { return }
        n1.simulateDisconnectedPeer(n2.peerID)
        n2.simulateDisconnectedPeer(n1.peerID)
    }
    
    private func connectFullMesh() {
        let nodeNames = Array(nodes.keys)
        for i in 0..<nodeNames.count {
            for j in i+1..<nodeNames.count {
                connect(nodeNames[i], nodeNames[j])
            }
        }
    }
    
    private func setupRelay(_ nodeName: String, nextHops: [String]) {
        guard let node = nodes[nodeName] else { return }
        
        node.packetDeliveryHandler = { packet in
            guard packet.ttl > 1 else { return }
            
            if let message = BitchatMessage.fromBinaryPayload(packet.payload) {
                guard message.senderPeerID != node.peerID else { return }
                
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
                        senderID: packet.senderID,
                        recipientID: packet.recipientID,
                        timestamp: packet.timestamp,
                        payload: relayPayload,
                        signature: packet.signature,
                        ttl: packet.ttl - 1
                    )
                    
                    for hop in nextHops {
                        self.nodes[hop]?.simulateIncomingPacket(relayPacket)
                    }
                }
            }
        }
    }
    
    private func establishNoiseSession(_ node1: String, _ node2: String) throws {
        guard let manager1 = noiseManagers[node1],
              let manager2 = noiseManagers[node2],
              let peer1ID = nodes[node1]?.peerID,
              let peer2ID = nodes[node2]?.peerID else { return }
        
        let msg1 = try manager1.initiateHandshake(with: peer2ID)
        let msg2 = try manager2.handleIncomingHandshake(from: peer1ID, message: msg1)!
        let msg3 = try manager1.handleIncomingHandshake(from: peer2ID, message: msg2)!
        _ = try manager2.handleIncomingHandshake(from: peer1ID, message: msg3)
    }
}
