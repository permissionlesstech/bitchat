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
        
        // Create a network of nodes
        createNode("Alice", peerID: TestConstants.testPeerID1)
        createNode("Bob", peerID: TestConstants.testPeerID2)
        createNode("Charlie", peerID: TestConstants.testPeerID3)
        createNode("David", peerID: TestConstants.testPeerID4)
    }
    
    override func tearDown() {
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
        
        // Each node should receive messages from all others
        for (senderName, _) in nodes {
            messageMatrix[senderName] = []
            
            for (receiverName, receiver) in nodes where receiverName != senderName {
                receiver.messageDeliveryHandler = { message in
                    if message.content.contains("from \(senderName)") {
                        messageMatrix[message.content.components(separatedBy: " ").last!]?.insert(receiverName)
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
        nodes["Alice"]!.sendMessage("Relayed message", mentions: [], to: nil)
        
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
        nodes["Alice"]!.packetDeliveryHandler = { packet in
            if packet.type == 0x01 { // Plain message
                self.nodes["Bob"]!.simulateIncomingPacket(packet)
            } else if packet.type == 0x02 { // Would be encrypted
                // Simulate encryption
                if let encrypted = try? self.noiseManagers["Alice"]!.encrypt(packet.payload, for: TestConstants.testPeerID2) {
                    let encPacket = BitchatPacket(
                        type: packet.type,
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
        
        nodes["Bob"]!.packetDeliveryHandler = { packet in
            if packet.type == 0x01 {
                plainCount += 1
            } else if packet.type == 0x02 {
                if let _ = try? self.noiseManagers["Bob"]!.decrypt(packet.payload, from: TestConstants.testPeerID1) {
                    encryptedCount += 1
                }
            }
            
            if plainCount == 1 && encryptedCount == 1 {
                expectation.fulfill()
            }
        }
        
        // Send both types
        nodes["Alice"]!.sendMessage("Plain message", mentions: [], to: nil)
        
        // Send "encrypted" message
        let encMessage = TestHelpers.createTestMessage(content: "Encrypted message")
        if let payload = encMessage.toBinaryPayload() {
            let packet = TestHelpers.createTestPacket(type: 0x02, payload: payload)
            nodes["Alice"]!.simulateIncomingPacket(packet)
        }
        
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
        // Test peer presence tracking and identity announcement on reconnection
        connect("Alice", "Bob")
        
        // Establish Noise sessions
        do {
            try establishNoiseSession("Alice", "Bob")
        } catch {
            XCTFail("Failed to establish Noise session: \(error)")
        }
        
        let expectation = XCTestExpectation(description: "Peer reconnection handled")
        var bobReceivedIdentityAnnounce = false
        var aliceReceivedIdentityAnnounce = false
        
        // Track identity announcements
        nodes["Bob"]!.packetDeliveryHandler = { packet in
            if packet.type == MessageType.noiseIdentityAnnounce.rawValue {
                bobReceivedIdentityAnnounce = true
                if aliceReceivedIdentityAnnounce {
                    expectation.fulfill()
                }
            }
        }
        
        nodes["Alice"]!.packetDeliveryHandler = { packet in
            if packet.type == MessageType.noiseIdentityAnnounce.rawValue {
                aliceReceivedIdentityAnnounce = true
                if bobReceivedIdentityAnnounce {
                    expectation.fulfill()
                }
            }
        }
        
        // Simulate disconnect (out of range)
        disconnect("Alice", "Bob")
        
        // Wait to simulate extended disconnect period
        Thread.sleep(forTimeInterval: 0.5)
        
        // Reconnect
        connect("Alice", "Bob")
        
        // Both should receive identity announcements after reconnection
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        XCTAssertTrue(bobReceivedIdentityAnnounce)
        XCTAssertTrue(aliceReceivedIdentityAnnounce)
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
        
        // Bob should initiate new handshake
        let handshakeExpectation = XCTestExpectation(description: "New handshake completed")
        
        nodes["Bob"]!.packetDeliveryHandler = { packet in
            if packet.type == MessageType.noiseHandshakeInit.rawValue {
                // Bob initiates new handshake after restart
                do {
                    let response = try self.noiseManagers["Alice"]!.handleIncomingHandshake(
                        from: TestConstants.testPeerID2,
                        message: packet.payload
                    )
                    if let resp = response {
                        // Send response back to Bob
                        let responsePacket = TestHelpers.createTestPacket(
                            type: MessageType.noiseHandshakeResp.rawValue,
                            payload: resp
                        )
                        self.nodes["Bob"]!.simulateIncomingPacket(responsePacket)
                    }
                } catch {
                    XCTFail("Handshake handling failed: \(error)")
                }
            } else if packet.type == MessageType.noiseHandshakeResp.rawValue && packet.senderID.hexEncodedString() == TestConstants.testPeerID1 {
                // Final handshake message (message 3 in XX pattern)
                handshakeExpectation.fulfill()
            }
        }
        
        // Trigger handshake by trying to send a message
        nodes["Bob"]!.sendPrivateMessage("After restart", to: TestConstants.testPeerID1, recipientNickname: "Alice")
        
        wait(for: [handshakeExpectation], timeout: TestConstants.defaultTimeout)
        
        // Now messages should work again
        let secondExpectation = XCTestExpectation(description: "Message after restart received")
        nodes["Alice"]!.messageDeliveryHandler = { message in
            if message.content == "After restart success" && message.isPrivate {
                secondExpectation.fulfill()
            }
        }
        
        nodes["Bob"]!.sendPrivateMessage("After restart success", to: TestConstants.testPeerID1, recipientNickname: "Alice")
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
                if receivedTotal == expectedTotal {
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
        XCTAssertEqual(receivedTotal, expectedTotal)
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
    
    func testHandshakeAfterNACKDecryptionFailure() throws {
        // Test the specific scenario where decryption fails, NACK is sent, and handshake is re-established
        connect("Alice", "Bob")
        
        // Establish initial Noise session
        try establishNoiseSession("Alice", "Bob")
        
        let expectation = XCTestExpectation(description: "Handshake re-established after NACK")
        var nackSent = false
        var newHandshakeCompleted = false
        
        // Exchange some messages to establish nonce state
        for i in 0..<5 {
            let msg = try noiseManagers["Alice"]!.encrypt("Message \(i)".data(using: .utf8)!, for: TestConstants.testPeerID2)
            _ = try noiseManagers["Bob"]!.decrypt(msg, from: TestConstants.testPeerID1)
        }
        
        // Simulate nonce desynchronization - Alice sends messages Bob doesn't receive
        for _ in 0..<3 {
            _ = try noiseManagers["Alice"]!.encrypt("Lost message".data(using: .utf8)!, for: TestConstants.testPeerID2)
        }
        
        // Setup Bob's handler to send NACK on decryption failure
        nodes["Bob"]!.packetDeliveryHandler = { packet in
            if packet.type == MessageType.noiseEncrypted.rawValue {
                do {
                    _ = try self.noiseManagers["Bob"]!.decrypt(packet.payload, from: TestConstants.testPeerID1)
                } catch {
                    // Decryption failed - send NACK
                    nackSent = true
                    let nack = ProtocolNack(
                        originalPacketID: UUID().uuidString,
                        senderID: TestConstants.testPeerID2,
                        receiverID: TestConstants.testPeerID1,
                        packetType: packet.type,
                        reason: "Decryption failed - session out of sync",
                        errorCode: .decryptionFailed
                    )
                    
                    let nackData = nack.toBinaryData()
                    let nackPacket = TestHelpers.createTestPacket(
                        type: MessageType.protocolNack.rawValue,
                        payload: nackData
                    )
                    self.nodes["Alice"]!.simulateIncomingPacket(nackPacket)
                    
                    // Bob clears session
                    self.noiseManagers["Bob"]!.removeSession(for: TestConstants.testPeerID1)
                }
            } else if packet.type == MessageType.noiseHandshakeInit.rawValue {
                // Bob receives handshake init from Alice after NACK
                do {
                    let response = try self.noiseManagers["Bob"]!.handleIncomingHandshake(
                        from: TestConstants.testPeerID1,
                        message: packet.payload
                    )
                    if let resp = response {
                        let responsePacket = TestHelpers.createTestPacket(
                            type: MessageType.noiseHandshakeResp.rawValue,
                            payload: resp
                        )
                        self.nodes["Alice"]!.simulateIncomingPacket(responsePacket)
                    }
                } catch {
                    XCTFail("Bob failed to handle handshake: \(error)")
                }
            }
        }
        
        // Setup Alice's handler to clear session on NACK and initiate handshake
        nodes["Alice"]!.packetDeliveryHandler = { packet in
            if packet.type == MessageType.protocolNack.rawValue {
                // Alice receives NACK - clear session
                self.noiseManagers["Alice"]!.removeSession(for: TestConstants.testPeerID2)
                
                // Initiate new handshake
                do {
                    let handshakeInit = try self.noiseManagers["Alice"]!.initiateHandshake(with: TestConstants.testPeerID2)
                    let handshakePacket = TestHelpers.createTestPacket(
                        type: MessageType.noiseHandshakeInit.rawValue,
                        payload: handshakeInit
                    )
                    self.nodes["Bob"]!.simulateIncomingPacket(handshakePacket)
                } catch {
                    XCTFail("Alice failed to initiate handshake: \(error)")
                }
            } else if packet.type == MessageType.noiseHandshakeResp.rawValue {
                // Complete handshake
                do {
                    let final = try self.noiseManagers["Alice"]!.handleIncomingHandshake(
                        from: TestConstants.testPeerID2,
                        message: packet.payload
                    )
                    if let finalMsg = final {
                        let finalPacket = TestHelpers.createTestPacket(
                            type: MessageType.noiseHandshakeResp.rawValue,
                            payload: finalMsg
                        )
                        self.nodes["Bob"]!.simulateIncomingPacket(finalPacket)
                        
                        // Try sending a message with new session
                        let testMsg = try self.noiseManagers["Alice"]!.encrypt(
                            "After re-handshake".data(using: .utf8)!,
                            for: TestConstants.testPeerID2
                        )
                        let msgPacket = TestHelpers.createTestPacket(
                            type: MessageType.noiseEncrypted.rawValue,
                            payload: testMsg
                        )
                        self.nodes["Bob"]!.simulateIncomingPacket(msgPacket)
                    }
                } catch {
                    XCTFail("Alice failed to complete handshake: \(error)")
                }
            }
        }
        
        // Add final handler to verify message works
        let originalHandler = nodes["Bob"]!.packetDeliveryHandler
        nodes["Bob"]!.packetDeliveryHandler = { packet in
            originalHandler?(packet)
            
            if packet.type == MessageType.noiseHandshakeResp.rawValue && packet.senderID.hexEncodedString() == TestConstants.testPeerID1 {
                // Final handshake message received
                do {
                    _ = try self.noiseManagers["Bob"]!.handleIncomingHandshake(
                        from: TestConstants.testPeerID1,
                        message: packet.payload
                    )
                } catch {
                    XCTFail("Bob failed to complete handshake: \(error)")
                }
            } else if packet.type == MessageType.noiseEncrypted.rawValue && nackSent {
                // Try to decrypt with new session
                do {
                    let decrypted = try self.noiseManagers["Bob"]!.decrypt(packet.payload, from: TestConstants.testPeerID1)
                    if let msg = String(data: decrypted, encoding: .utf8), msg == "After re-handshake" {
                        newHandshakeCompleted = true
                        expectation.fulfill()
                    }
                } catch {
                    XCTFail("Bob failed to decrypt after re-handshake: \(error)")
                }
            }
        }
        
        // Trigger the scenario - send desynchronized message
        let desyncMsg = try noiseManagers["Alice"]!.encrypt(
            "This will fail".data(using: .utf8)!,
            for: TestConstants.testPeerID2
        )
        let desyncPacket = TestHelpers.createTestPacket(
            type: MessageType.noiseEncrypted.rawValue,
            payload: desyncMsg
        )
        nodes["Bob"]!.simulateIncomingPacket(desyncPacket)
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        XCTAssertTrue(nackSent, "NACK should have been sent")
        XCTAssertTrue(newHandshakeCompleted, "New handshake should have completed")
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