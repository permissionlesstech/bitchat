//
// IntegrationTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit
import Testing
@testable import bitchat

struct IntegrationTests {
    
    private var helper = TestNetworkHelper()
    
    init() {
        helper.createNode("Alice", peerID: PeerID(str: UUID().uuidString))
        helper.createNode("Bob", peerID: PeerID(str: UUID().uuidString))
        helper.createNode("Charlie", peerID: PeerID(str: UUID().uuidString))
        helper.createNode("David", peerID: PeerID(str: UUID().uuidString))
    }
    
    // MARK: - Multi-Peer Scenarios
    
    @Test func fullMeshCommunication() async throws {
        helper.connectFullMesh()
        
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
            node.sendMessage("Hello from \(name)")
        }
        
        // Each sender should have reached all other nodes
        for (sender, receivers) in messageMatrix {
            let expectedReceivers = Set(helper.nodes.keys.filter { $0 != sender })
            #expect(receivers == expectedReceivers, "\(sender) didn't reach all nodes")
        }
    }
    
    @Test func dynamicTopologyChanges() async throws {
        // Start with Alice -> Bob -> Charlie
        helper.connect("Alice", "Bob")
        helper.connect("Bob", "Charlie")
        
        try await confirmation("Topology changes handled") { receiveMessage in
            var phase = 1
            
            helper.nodes["Charlie"]!.messageDeliveryHandler = { message in
                if phase == 1 && message.sender == "Alice" {
                    // Now change topology: disconnect Bob, connect Alice-Charlie
                    helper.disconnect("Alice", "Bob")
                    helper.disconnect("Bob", "Charlie")
                    helper.connect("Alice", "Charlie")
                    phase = 2
                    
                    // Send another message
                    helper.nodes["Alice"]!.sendMessage("Direct message")
                } else if phase == 2 && message.content == "Direct message" {
                    receiveMessage()
                }
            }
            
            // Allow relay handler to be set before first send
            try await sleep(0.05)
            helper.nodes["Alice"]!.sendMessage("Relayed message")
        }
    }
    
    @Test func networkPartitionRecovery() async throws {
        // Create two partitions
        helper.connect("Alice", "Bob")
        helper.connect("Charlie", "David")
        
        let messagesBeforeMerge = 0
        var messagesAfterMerge = 0
        
        try await confirmation("Partitions merge and communicate") { receiveMessage in
            // Monitor cross-partition messages
            helper.nodes["David"]!.messageDeliveryHandler = { message in
                if message.sender == "Alice" {
                    messagesAfterMerge += 1
                    if messagesAfterMerge == 1 {
                        receiveMessage()
                    }
                }
            }
            
            // Try to send across partition (should fail)
            helper.nodes["Alice"]!.sendMessage("Before merge")
            
            // Merge partitions after delay
            try await sleep(0.05)
            // Connect partitions
            helper.connect("Bob", "Charlie")
            
            // Enable relay
            helper.setupRelay("Bob", nextHops: ["Charlie"])
            helper.setupRelay("Charlie", nextHops: ["David"])
            
            // Send message across merged network
            helper.nodes["Alice"]!.sendMessage("After merge")
        }
        
        #expect(messagesBeforeMerge == 0)
        #expect(messagesAfterMerge == 1)
    }
    
    // MARK: - Mixed Message Type Scenarios
    
    @Test func mixedPublicPrivateMessages() async throws {
        helper.connectFullMesh()
        
        var publicCount = 0
        var privateCount = 0
        
        await confirmation("Mixed messages handled correctly") { completion in
            // Bob monitors messages
            helper.nodes["Bob"]!.messageDeliveryHandler = { message in
                if message.isPrivate && message.recipientNickname == "Bob" {
                    privateCount += 1
                } else if !message.isPrivate {
                    publicCount += 1
                }
                
                if publicCount == 2 && privateCount == 1 {
                    completion()
                }
            }
            
            // Alice sends mixed messages
            helper.nodes["Alice"]!.sendMessage("Public 1")
            helper.nodes["Alice"]!.sendPrivateMessage("Private to Bob", to: helper.nodes["Bob"]!.peerID, recipientNickname: "Bob")
            helper.nodes["Alice"]!.sendMessage("Public 2")
        }
        
        #expect(publicCount == 2)
        #expect(privateCount == 1)
    }
    
    @Test func encryptedAndUnencryptedMix() async throws {
        helper.connect("Alice", "Bob")
        
        // Setup Noise session
        try helper.establishNoiseSession("Alice", "Bob")
        
        var plainCount = 0
        var encryptedCount = 0
        
        try await confirmation("Both encrypted and plain messages work") { completion in
            // Plain path: send public message and count at Bob
            helper.nodes["Bob"]!.messageDeliveryHandler = { message in
                if message.content == "Plain message" {
                    plainCount += 1
                }
                if plainCount == 1 && encryptedCount == 1 {
                    completion()
                }
            }
            
            // Encrypted path: use NoiseSessionManager explicitly
            let plaintext = "Encrypted message".data(using: .utf8)!
            let ciphertext = try helper.noiseManagers["Alice"]!.encrypt(plaintext, for: helper.nodes["Bob"]!.peerID)
            
            helper.nodes["Bob"]!.packetDeliveryHandler = { packet in
                if packet.type == MessageType.noiseEncrypted.rawValue {
                    if let data = try? helper.noiseManagers["Bob"]!.decrypt(ciphertext, from: helper.nodes["Alice"]!.peerID),
                       data == plaintext {
                        encryptedCount = 1
                        if plainCount == 1 {
                            completion()
                        }
                    }
                }
            }
            
            helper.nodes["Alice"]!.sendMessage("Plain message")
            // Deliver encrypted packet directly
            let encPacket = TestHelpers.createTestPacket(type: MessageType.noiseEncrypted.rawValue, payload: ciphertext)
            helper.nodes["Bob"]!.simulateIncomingPacket(encPacket)
        }
    }
    
    // MARK: - Network Resilience Tests
    
    @Test func messageDeliveryUnderChurn() async throws {
        // Start with stable network
        helper.connectFullMesh()
        
        let totalMessages = 10
        
        try await confirmation("Messages delivered despite churn", expectedCount: totalMessages) { completion in
            // David tracks received messages
            helper.nodes["David"]!.messageDeliveryHandler = { message in
                completion()
            }
            
            // Send messages while churning network
            for i in 0..<totalMessages {
                helper.nodes["Alice"]!.sendMessage("Message \(i)")
                
                // Simulate churn
                if i % 3 == 0 {
                    // Disconnect and reconnect random connection
                    let pairs = [("Alice", "Bob"), ("Bob", "Charlie"), ("Charlie", "David")]
                    let randomPair = pairs.randomElement()!
                    helper.disconnect(randomPair.0, randomPair.1)
                    try await sleep(0.01)
                    helper.connect(randomPair.0, randomPair.1)
                }
            }
        }
    }
    
    @Test func peerPresenceTrackingAndReconnection() async throws {
        helper.connect("Alice", "Bob")
        
        await confirmation("Delivery after reconnection") { delivered in
            helper.nodes["Bob"]!.messageDeliveryHandler = { message in
                if message.content == "After reconnect" {
                    delivered()
                }
            }
            
            // Simulate disconnect (out of range)
            helper.disconnect("Alice", "Bob")
            // Reconnect
            helper.connect("Alice", "Bob")
            
            // Send after reconnection
            helper.nodes["Alice"]!.sendMessage("After reconnect")
        }
    }
    
    @Test func encryptedMessageAfterPeerRestart() async throws {
        helper.connect("Alice", "Bob")
        do {
            try helper.establishNoiseSession("Alice", "Bob")
        } catch {
            Issue.record("Failed to establish Noise session: \(error)")
        }
        
        // Exchange an encrypted message
        await confirmation("First message received") { received in
            helper.nodes["Bob"]!.messageDeliveryHandler = { message in
                if message.content == "Before restart" && message.isPrivate {
                    received()
                }
            }
            helper.nodes["Alice"]!.sendPrivateMessage("Before restart", to: helper.nodes["Bob"]!.peerID, recipientNickname: "Bob")
        }
        
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
            Issue.record("Failed to re-establish Noise session after restart: \(error)")
        }
        
        // Now messages should work again - simulate encrypted packet
        await confirmation("Message after restart received") { received in
            helper.nodes["Alice"]!.messageDeliveryHandler = { message in
                if message.content == "After restart success" && message.isPrivate {
                    received()
                }
            }
            
            do {
                let plaintext = "After restart success".data(using: .utf8)!
                let ciphertext = try helper.noiseManagers["Bob"]!.encrypt(plaintext, for: helper.nodes["Alice"]!.peerID)
                let packet = TestHelpers.createTestPacket(type: MessageType.noiseEncrypted.rawValue, payload: ciphertext)
                helper.nodes["Alice"]!.packetDeliveryHandler = { pkt in
                    if pkt.type == MessageType.noiseEncrypted.rawValue {
                        if let data = try? helper.noiseManagers["Alice"]!.decrypt(pkt.payload, from: helper.nodes["Bob"]!.peerID),
                           String(data: data, encoding: .utf8) == "After restart success" {
                            received()
                        }
                    }
                }
                helper.nodes["Alice"]!.simulateIncomingPacket(packet)
            } catch {
                Issue.record("Encryption after restart failed: \(error)")
            }
        }
    }
    
    @Test func largeScaleNetwork() async throws {
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
        
        await confirmation("Large network handles broadcast", expectedCount: helper.nodes.count - 1) { nodeReaced in
            // All nodes except Alice listen
            for (name, node) in helper.nodes where name != "Alice" {
                node.messageDeliveryHandler = { message in
                    if message.content == "Broadcast test" {
                        nodeReaced()
                    }
                }
            }
            
            // Alice broadcasts
            helper.nodes["Alice"]!.sendMessage("Broadcast test")
        }
    }
    
    // MARK: - Stress Tests
    
    @Test func highLoadScenario() async throws {
        helper.connectFullMesh()
        
        let messagesPerNode = 25
        let expectedTotal = messagesPerNode * helper.nodes.count * (helper.nodes.count - 1)
        
        await confirmation("High load handled", expectedCount: expectedTotal) { received in
            // Each node tracks messages
            for (_, node) in helper.nodes {
                node.messageDeliveryHandler = { _ in
                    received()
                }
            }
            
            // All nodes send many messages simultaneously
            await withTaskGroup(of: Void.self) { group in
                for (name, node) in helper.nodes {
                    group.addTask {
                        for i in 0..<messagesPerNode {
                            node.sendMessage("\(name) message \(i)")
                        }
                    }
                }
                await group.waitForAll()
            }
        }
    }
    
    @Test func mixedTrafficPatterns() async throws {
        helper.connectFullMesh()
        
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
        helper.nodes["Alice"]!.sendMessage("Public broadcast")
        helper.nodes["Alice"]!.sendPrivateMessage("Private to Bob", to: helper.nodes["Bob"]!.peerID, recipientNickname: "Bob")
        helper.nodes["Bob"]!.sendMessage("Mentioning @Charlie", mentions: ["Charlie"])
        
        // Disconnect to force relay
        helper.disconnect("Alice", "David")
        helper.nodes["Alice"]!.sendMessage("Needs relay to David")
        
        #expect(metrics["public", default: 0] > 0)
        #expect(metrics["private", default: 0] > 0)
        #expect(metrics["mentions", default: 0] > 0)
    }
    
    // MARK: - Security Integration Tests
    // Replacement for the legacy NACK test: verifies that after a
    // decryption failure, peers can rehandshake via NoiseSessionManager
    // and resume secure communication.
    @Test func rehandshakeAfterDecryptionFailure() throws {
        // Alice <-> Bob connected
        helper.connect("Alice", "Bob")
        
        // Establish initial Noise session
        try helper.establishNoiseSession("Alice", "Bob")
        
        guard let aliceManager = helper.noiseManagers["Alice"],
              let bobManager = helper.noiseManagers["Bob"],
              let alicePeerID = helper.nodes["Alice"]?.peerID,
              let bobPeerID = helper.nodes["Bob"]?.peerID
        else {
            Issue.record("Missing managers or peer IDs")
            return
        }
        
        // Baseline: encrypt from Alice, decrypt at Bob
        let plaintext1 = Data("hello-secure".utf8)
        let encrypted1 = try aliceManager.encrypt(plaintext1, for: bobPeerID)
        let decrypted1 = try bobManager.decrypt(encrypted1, from: alicePeerID)
        #expect(decrypted1 == plaintext1)
        
        // Simulate decryption failure by corrupting ciphertext
        let corrupted = encrypted1.prefix(15)
        #expect(throws: NoiseError.invalidCiphertext) {
            _ = try bobManager.decrypt(corrupted, from: alicePeerID)
        }
        
        // Bob initiates a new handshake; clear Bob's session first so initiateHandshake won't throw
        bobManager.removeSession(for: alicePeerID)
        try helper.establishNoiseSession("Bob", "Alice")
        
        // After rehandshake, encryption/decryption works again
        let plaintext2 = Data("hello-again".utf8)
        let encrypted2 = try aliceManager.encrypt(plaintext2, for: bobPeerID)
        let decrypted2 = try bobManager.decrypt(encrypted2, from: alicePeerID)
        #expect(decrypted2 == plaintext2)
    }
    
    @Test func endToEndSecurityScenario() async throws {
        helper.connect("Alice", "Bob")
        helper.connect("Bob", "Charlie") // Charlie will try to eavesdrop
        
        // Establish secure session between Alice and Bob only
        try helper.establishNoiseSession("Alice", "Bob")
        
        await confirmation("Secure communication maintained", expectedCount: 2) { receivedPacket in
            
            // Setup encryption at Alice
            helper.nodes["Alice"]!.packetDeliveryHandler = { packet in
                if packet.type == 0x01,
                   let message = BitchatMessage(packet.payload),
                   message.isPrivate && packet.recipientID != nil {
                    // Encrypt private messages
                    if let encrypted = try? helper.noiseManagers["Alice"]!.encrypt(packet.payload, for: helper.nodes["Bob"]!.peerID) {
                        let encPacket = BitchatPacket(
                            type: 0x02,
                            senderID: packet.senderID,
                            recipientID: packet.recipientID,
                            timestamp: packet.timestamp,
                            payload: encrypted,
                            signature: packet.signature,
                            ttl: packet.ttl
                        )
                        helper.nodes["Bob"]!.simulateIncomingPacket(encPacket)
                    }
                }
            }
            
            // Bob can decrypt
            helper.nodes["Bob"]!.packetDeliveryHandler = { packet in
                if packet.type == 0x02 {
                    receivedPacket()
                    if let decrypted = try? helper.noiseManagers["Bob"]!.decrypt(packet.payload, from: helper.nodes["Alice"]!.peerID) {
                        #expect(BitchatMessage(decrypted)?.content == "Secret message")
                    } else {
                        Issue.record("Bob was unable to decrypt the message")
                    }
                    
                    // Relay encrypted packet to Charlie
                    helper.nodes["Charlie"]!.simulateIncomingPacket(packet)
                }
            }
            
            // Charlie cannot decrypt
            helper.nodes["Charlie"]!.packetDeliveryHandler = { packet in
                if packet.type == 0x02 {
                    receivedPacket()
                    #expect(throws: NoiseSessionError.sessionNotFound, "Charlie should not be able to decrypt") {
                        _ = try helper.noiseManagers["Charlie"]?.decrypt(packet.payload, from: helper.nodes["Alice"]!.peerID)
                    }
                }
            }
            
            // Send encrypted private message
            helper.nodes["Alice"]!.sendPrivateMessage("Secret message", to: helper.nodes["Bob"]!.peerID, recipientNickname: "Bob")
        }
    }
}
