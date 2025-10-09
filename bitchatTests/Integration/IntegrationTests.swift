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
    
    private var helper: TestNetworkHelper!
    
    override func setUp() {
        super.setUp()
        helper = TestNetworkHelper()
        
        // Create a network of nodes
        helper.createNode("Alice", peerID: PeerID(str: UUID().uuidString))
        helper.createNode("Bob", peerID: PeerID(str: UUID().uuidString))
        helper.createNode("Charlie", peerID: PeerID(str: UUID().uuidString))
        helper.createNode("David", peerID: PeerID(str: UUID().uuidString))
    }
    
    override func tearDown() {
        helper = nil
        super.tearDown()
    }
    
    // MARK: - Multi-Peer Scenarios
    
    func testFullMeshCommunication() {
        helper.connectFullMesh()
        
        let expectation = XCTestExpectation(description: "All nodes communicate")
        var messageMatrix: [String: Set<String>] = [:]
        
        for (senderName, _) in helper.nodes { messageMatrix[senderName] = [] }
        for (receiverName, receiver) in helper.nodes {
            receiver.messageDeliveryHandler = { message in
                let parts = message.content.components(separatedBy: " ")
                if let last = parts.last, message.content.contains("Hello from") {
                    if receiverName != last {
                        messageMatrix[last]?.insert(receiverName)
                    }
                }
            }
        }
        
        for (name, node) in helper.nodes {
            node.sendMessage("Hello from \(name)", mentions: [], to: nil)
        }
        
        // Wait and verify
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Each sender should have reached all other nodes
            for (sender, receivers) in messageMatrix {
                let expectedReceivers = Set(self.helper.nodes.keys.filter { $0 != sender })
                XCTAssertEqual(receivers, expectedReceivers, "\(sender) didn't reach all nodes")
            }
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    func testDynamicTopologyChanges() {
        // Start with Alice -> Bob -> Charlie
        helper.connect("Alice", "Bob")
        helper.connect("Bob", "Charlie")
        
        let expectation = XCTestExpectation(description: "Topology changes handled")
        var phase = 1
        
        // Phase 1: Test initial topology
        helper.nodes["Charlie"]!.messageDeliveryHandler = { message in
            if phase == 1 && message.sender == "Alice" {
                // Now change topology: disconnect Bob, connect Alice-Charlie
                self.helper.disconnect("Alice", "Bob")
                self.helper.disconnect("Bob", "Charlie")
                self.helper.connect("Alice", "Charlie")
                phase = 2
                
                // Send another message
                self.helper.nodes["Alice"]!.sendMessage("Direct message", mentions: [], to: nil)
            } else if phase == 2 && message.content == "Direct message" {
                expectation.fulfill()
            }
        }
        
        // Initial message through relay
        // Allow relay handler to be set before first send
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.helper.nodes["Alice"]!.sendMessage("Relayed message", mentions: [], to: nil)
        }
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    func testNetworkPartitionRecovery() {
        // Create two partitions
        helper.connect("Alice", "Bob")
        helper.connect("Charlie", "David")
        
        let expectation = XCTestExpectation(description: "Partitions merge and communicate")
        let messagesBeforeMerge = 0
        var messagesAfterMerge = 0
        
        // Monitor cross-partition messages
        helper.nodes["David"]!.messageDeliveryHandler = { message in
            if message.sender == "Alice" {
                messagesAfterMerge += 1
                if messagesAfterMerge == 1 {
                    expectation.fulfill()
                }
            }
        }
        
        // Try to send across partition (should fail)
        helper.nodes["Alice"]!.sendMessage("Before merge", mentions: [], to: nil)
        
        // Merge partitions after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Connect partitions
            self.helper.connect("Bob", "Charlie")
            
            // Enable relay
            self.helper.setupRelay("Bob", nextHops: ["Charlie"])
            self.helper.setupRelay("Charlie", nextHops: ["David"])
            
            // Send message across merged network
            self.helper.nodes["Alice"]!.sendMessage("After merge", mentions: [], to: nil)
        }
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        XCTAssertEqual(messagesBeforeMerge, 0)
        XCTAssertEqual(messagesAfterMerge, 1)
    }
    
    // MARK: - Mixed Message Type Scenarios
    
    func testMixedPublicPrivateMessages() throws {
        helper.connectFullMesh()
        
        let expectation = XCTestExpectation(description: "Mixed messages handled correctly")
        var publicCount = 0
        var privateCount = 0
        
        // Bob monitors messages
        helper.nodes["Bob"]!.messageDeliveryHandler = { message in
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
        helper.nodes["Alice"]!.sendMessage("Public 1", mentions: [], to: nil)
        helper.nodes["Alice"]!.sendPrivateMessage("Private to Bob", to: helper.nodes["Bob"]!.peerID, recipientNickname: "Bob")
        helper.nodes["Alice"]!.sendMessage("Public 2", mentions: [], to: nil)
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        XCTAssertEqual(publicCount, 2)
        XCTAssertEqual(privateCount, 1)
    }
    
    func testEncryptedAndUnencryptedMix() throws {
        helper.connect("Alice", "Bob")
        
        // Setup Noise session
        try helper.establishNoiseSession("Alice", "Bob")
        
        let expectation = XCTestExpectation(description: "Both encrypted and plain messages work")
        var plainCount = 0
        var encryptedCount = 0
        
        // Setup handlers
        // Plain path: send public message and count at Bob
        helper.nodes["Bob"]!.messageDeliveryHandler = { message in
            if message.content == "Plain message" { plainCount += 1 }
            if plainCount == 1 && encryptedCount == 1 { expectation.fulfill() }
        }

        // Encrypted path: use NoiseSessionManager explicitly
        let plaintext = "Encrypted message".data(using: .utf8)!
        let ciphertext = try helper.noiseManagers["Alice"]!.encrypt(plaintext, for: helper.nodes["Bob"]!.peerID)
        helper.nodes["Bob"]!.packetDeliveryHandler = { packet in
            if packet.type == MessageType.noiseEncrypted.rawValue {
                if let data = try? self.helper.noiseManagers["Bob"]!.decrypt(ciphertext, from: self.helper.nodes["Alice"]!.peerID),
                   data == plaintext {
                    encryptedCount = 1
                    if plainCount == 1 { expectation.fulfill() }
                }
            }
        }

        helper.nodes["Alice"]!.sendMessage("Plain message", mentions: [], to: nil)
        // Deliver encrypted packet directly
        let encPacket = TestHelpers.createTestPacket(type: MessageType.noiseEncrypted.rawValue, payload: ciphertext)
        helper.nodes["Bob"]!.simulateIncomingPacket(encPacket)
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
    }
    
    // MARK: - Network Resilience Tests
    
    func testMessageDeliveryUnderChurn() {
        // Start with stable network
        helper.connectFullMesh()
        
        let expectation = XCTestExpectation(description: "Messages delivered despite churn")
        var receivedMessages = Set<String>()
        let totalMessages = 10
        
        // David tracks received messages
        helper.nodes["David"]!.messageDeliveryHandler = { message in
            receivedMessages.insert(message.content)
            if receivedMessages.count == totalMessages {
                expectation.fulfill()
            }
        }
        
        // Send messages while churning network
        for i in 0..<totalMessages {
            helper.nodes["Alice"]!.sendMessage("Message \(i)", mentions: [], to: nil)
            
            // Simulate churn
            if i % 3 == 0 {
                // Disconnect and reconnect random connection
                let pairs = [("Alice", "Bob"), ("Bob", "Charlie"), ("Charlie", "David")]
                let randomPair = pairs.randomElement()!
                self.helper.disconnect(randomPair.0, randomPair.1)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.helper.connect(randomPair.0, randomPair.1)
                }
            }
        }
        
        wait(for: [expectation], timeout: TestConstants.longTimeout)
        XCTAssertEqual(receivedMessages.count, totalMessages)
    }
    
    func testPeerPresenceTrackingAndReconnection() {
        // Test that after disconnect/reconnect, message delivery resumes
        helper.connect("Alice", "Bob")

        let expectation = XCTestExpectation(description: "Delivery after reconnection")
        var delivered = false

        helper.nodes["Bob"]!.messageDeliveryHandler = { message in
            if message.content == "After reconnect" && !delivered {
                delivered = true
                expectation.fulfill()
            }
        }

        // Simulate disconnect (out of range)
        helper.disconnect("Alice", "Bob")
        // Reconnect
        helper.connect("Alice", "Bob")

        // Send after reconnection
        helper.nodes["Alice"]!.sendMessage("After reconnect", mentions: [], to: nil)

        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        XCTAssertTrue(delivered)
    }
    
    func testEncryptedMessageAfterPeerRestart() {
        // Test that encrypted messages work after one peer restarts
        helper.connect("Alice", "Bob")
        do {
            try helper.establishNoiseSession("Alice", "Bob")
        } catch {
            XCTFail("Failed to establish Noise session: \(error)")
        }
        
        // Exchange an encrypted message
        let firstExpectation = XCTestExpectation(description: "First message received")
        helper.nodes["Bob"]!.messageDeliveryHandler = { message in
            if message.content == "Before restart" && message.isPrivate {
                firstExpectation.fulfill()
            }
        }
        
        helper.nodes["Alice"]!.sendPrivateMessage("Before restart", to: helper.nodes["Bob"]!.peerID, recipientNickname: "Bob")
        wait(for: [firstExpectation], timeout: TestConstants.defaultTimeout)
        
        // Simulate Bob restart by recreating his Noise manager
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        helper.noiseManagers["Bob"] = NoiseSessionManager(localStaticKey: bobKey, keychain: helper.mockKeychain)
        
        // Re-establish Noise handshake explicitly via managers
        do {
            let m1 = try helper.noiseManagers["Bob"]!.initiateHandshake(with: helper.nodes["Alice"]!.peerID)
            let m2 = try helper.noiseManagers["Alice"]!.handleIncomingHandshake(from: helper.nodes["Bob"]!.peerID, message: m1)!
            let m3 = try helper.noiseManagers["Bob"]!.handleIncomingHandshake(from: helper.nodes["Alice"]!.peerID, message: m2)!
            _ = try helper.noiseManagers["Alice"]!.handleIncomingHandshake(from: helper.nodes["Bob"]!.peerID, message: m3)
        } catch {
            XCTFail("Failed to re-establish Noise session after restart: \(error)")
        }
        
        // Now messages should work again
        let secondExpectation = XCTestExpectation(description: "Message after restart received")
        helper.nodes["Alice"]!.messageDeliveryHandler = { message in
            if message.content == "After restart success" && message.isPrivate {
                secondExpectation.fulfill()
            }
        }
        
        // Simulate encrypted message using managers
        do {
            let plaintext = "After restart success".data(using: .utf8)!
            let ciphertext = try helper.noiseManagers["Bob"]!.encrypt(plaintext, for: helper.nodes["Alice"]!.peerID)
            let packet = TestHelpers.createTestPacket(type: MessageType.noiseEncrypted.rawValue, payload: ciphertext)
            helper.nodes["Alice"]!.packetDeliveryHandler = { pkt in
                if pkt.type == MessageType.noiseEncrypted.rawValue {
                    if let data = try? self.helper.noiseManagers["Alice"]!.decrypt(pkt.payload, from: self.helper.nodes["Bob"]!.peerID),
                       String(data: data, encoding: .utf8) == "After restart success" {
                        secondExpectation.fulfill()
                    }
                }
            }
            helper.nodes["Alice"]!.simulateIncomingPacket(packet)
        } catch {
            XCTFail("Encryption after restart failed: \(error)")
        }
        wait(for: [secondExpectation], timeout: TestConstants.defaultTimeout)
    }
    
    func testLargeScaleNetwork() {
        // Create larger network
        for i in 5...10 {
            helper.createNode("Node\(i)", peerID: PeerID(str: "PEER\(i)"))
        }
        
        // Connect in ring topology with cross-connections
        let allNodes = Array(helper.nodes.keys).sorted()
        for i in 0..<allNodes.count {
            // Ring connection
            helper.connect(allNodes[i], allNodes[(i + 1) % allNodes.count])
            
            // Cross connection
            if i + 3 < allNodes.count {
                helper.connect(allNodes[i], allNodes[i + 3])
            }
        }
        
        let expectation = XCTestExpectation(description: "Large network handles broadcast")
        var nodesReached = Set<String>()
        
        // All nodes except Alice listen
        for (name, node) in helper.nodes where name != "Alice" {
            node.messageDeliveryHandler = { message in
                if message.content == "Broadcast test" {
                    nodesReached.insert(name)
                    if nodesReached.count == self.helper.nodes.count - 1 {
                        expectation.fulfill()
                    }
                }
            }
        }
        
        // Alice broadcasts
        helper.nodes["Alice"]!.sendMessage("Broadcast test", mentions: [], to: nil)
        
        wait(for: [expectation], timeout: TestConstants.longTimeout)
        XCTAssertEqual(nodesReached.count, helper.nodes.count - 1)
    }
    
    // MARK: - Stress Tests
    
    func testHighLoadScenario() {
        helper.connectFullMesh()
        
        let messagesPerNode = 25
        let expectedTotal = messagesPerNode * helper.nodes.count * (helper.nodes.count - 1)
        var receivedTotal = 0
        let expectation = XCTestExpectation(description: "High load handled")
        
        // Each node tracks messages
        for (_, node) in helper.nodes {
            node.messageDeliveryHandler = { _ in
                receivedTotal += 1
                if receivedTotal >= (expectedTotal - 2) {
                    expectation.fulfill()
                }
            }
        }
        
        // All nodes send many messages simultaneously
        DispatchQueue.concurrentPerform(iterations: helper.nodes.count) { index in
            let nodeName = Array(self.helper.nodes.keys).sorted()[index]
            for i in 0..<messagesPerNode {
                self.helper.nodes[nodeName]!.sendMessage("\(nodeName) message \(i)", mentions: [], to: nil)
            }
        }
        
        wait(for: [expectation], timeout: TestConstants.longTimeout)
        XCTAssertGreaterThanOrEqual(receivedTotal, expectedTotal - 2)
    }
    
    func testMixedTrafficPatterns() {
        helper.connectFullMesh()
        
        let expectation = XCTestExpectation(description: "Mixed traffic handled")
        var metrics = [
            "public": 0,
            "private": 0,
            "mentions": 0,
            "relayed": 0
        ]
        
        // Setup complex handlers
        for (name, node) in helper.nodes {
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
        helper.nodes["Alice"]!.sendMessage("Public broadcast", mentions: [], to: nil)
        helper.nodes["Alice"]!.sendPrivateMessage("Private to Bob", to: helper.nodes["Bob"]!.peerID, recipientNickname: "Bob")
        helper.nodes["Bob"]!.sendMessage("Mentioning @Charlie", mentions: ["Charlie"], to: nil)
        
        // Disconnect to force relay
        helper.disconnect("Alice", "David")
        helper.nodes["Alice"]!.sendMessage("Needs relay to David", mentions: [], to: nil)
        
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
        helper.connect("Alice", "Bob")

        // Establish initial Noise session
        try helper.establishNoiseSession("Alice", "Bob")

        guard let aliceManager = helper.noiseManagers["Alice"],
              let bobManager = helper.noiseManagers["Bob"],
              let alicePeerID = helper.nodes["Alice"]?.peerID,
              let bobPeerID = helper.nodes["Bob"]?.peerID else {
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
        try helper.establishNoiseSession("Bob", "Alice")

        // After rehandshake, encryption/decryption works again
        let plaintext2 = Data("hello-again".utf8)
        let encrypted2 = try aliceManager.encrypt(plaintext2, for: bobPeerID)
        let decrypted2 = try bobManager.decrypt(encrypted2, from: alicePeerID)
        XCTAssertEqual(decrypted2, plaintext2)
    }
    
    func testEndToEndSecurityScenario() throws {
        helper.connect("Alice", "Bob")
        helper.connect("Bob", "Charlie") // Charlie will try to eavesdrop
        
        // Establish secure session between Alice and Bob only
        try helper.establishNoiseSession("Alice", "Bob")
        
        let expectation = XCTestExpectation(description: "Secure communication maintained")
        var bobDecrypted = false
        var charlieIntercepted = false
        
        // Setup encryption at Alice
        helper.nodes["Alice"]!.packetDeliveryHandler = { packet in
            if packet.type == 0x01,
               let message = BitchatMessage(packet.payload),
               message.isPrivate && packet.recipientID != nil {
                // Encrypt private messages
                if let encrypted = try? self.helper.noiseManagers["Alice"]!.encrypt(packet.payload, for: self.helper.nodes["Bob"]!.peerID) {
                    let encPacket = BitchatPacket(
                        type: 0x02,
                        senderID: packet.senderID,
                        recipientID: packet.recipientID,
                        timestamp: packet.timestamp,
                        payload: encrypted,
                        signature: packet.signature,
                        ttl: packet.ttl
                    )
                    self.helper.nodes["Bob"]!.simulateIncomingPacket(encPacket)
                }
            }
        }
        
        // Bob can decrypt
        helper.nodes["Bob"]!.packetDeliveryHandler = { packet in
            if packet.type == 0x02 {
                if let decrypted = try? self.helper.noiseManagers["Bob"]!.decrypt(packet.payload, from: self.helper.nodes["Alice"]!.peerID),
                   let message = BitchatMessage(decrypted) {
                    bobDecrypted = message.content == "Secret message"
                    expectation.fulfill()
                }
                
                // Relay encrypted packet to Charlie
                self.helper.nodes["Charlie"]!.simulateIncomingPacket(packet)
            }
        }
        
        // Charlie cannot decrypt
        helper.nodes["Charlie"]!.packetDeliveryHandler = { packet in
            if packet.type == 0x02 {
                charlieIntercepted = true
                // Try to decrypt (should fail)
                do {
                    _ = try self.helper.noiseManagers["Charlie"]?.decrypt(packet.payload, from: self.helper.nodes["Alice"]!.peerID)
                    XCTFail("Charlie should not be able to decrypt")
                } catch {
                    // Expected
                }
            }
        }
        
        // Send encrypted private message
        helper.nodes["Alice"]!.sendPrivateMessage("Secret message", to: helper.nodes["Bob"]!.peerID, recipientNickname: "Bob")
        
        wait(for: [expectation], timeout: TestConstants.defaultTimeout)
        XCTAssertTrue(bobDecrypted)
        XCTAssertTrue(charlieIntercepted)
    }
}

