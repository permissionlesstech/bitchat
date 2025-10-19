//
// PrivateChatE2ETests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import CryptoKit
import struct Foundation.UUID
@testable import bitchat

struct PrivateChatE2ETests {
    
    private let alice: MockBLEService
    private let bob: MockBLEService
    private let charlie: MockBLEService
    private let mockKeychain = MockKeychain()
    private let bus = MockBLEBus()
    
    init() {
        // Create services with unique peer IDs to avoid any collision
        alice = MockBLEService(peerID: PeerID(str: UUID().uuidString), nickname: TestConstants.testNickname1, bus: bus)
        bob = MockBLEService(peerID: PeerID(str: UUID().uuidString), nickname: TestConstants.testNickname2, bus: bus)
        charlie = MockBLEService(peerID: PeerID(str: UUID().uuidString), nickname: TestConstants.testNickname3, bus: bus)
    }
    
    // MARK: - Basic Private Messaging Tests

    @Test func simplePrivateMessageShouldNotBeSentWithoutConnection() async {
        // Intentionally not connecting alice and bob to test

        var bobReceivedMessage = false

        await confirmation("Bob should not receive a private message", expectedCount: 0) { bobReceivesMessage in
            bob.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 &&
                   message.isPrivate &&
                   message.sender == TestConstants.testNickname1 {
                    bobReceivedMessage = true
                    bobReceivesMessage()
                }
            }

            // Alice sends private message to Bob
            alice.sendPrivateMessage(
                TestConstants.testMessage1,
                to: bob.peerID,
                recipientNickname: TestConstants.testNickname2
            )

            // Wait a bit to ensure message would have been delivered if it was going to be
            try? await sleep(0.1)
        }

        #expect(!bobReceivedMessage, "Bob should not have received the message")
    }

    @Test func simplePrivateMessage() async {
        alice.simulateConnection(with: bob)
        
        await confirmation("Bob receives private message") { bobReceivesMessage in
            bob.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 &&
                   message.isPrivate &&
                   message.sender == TestConstants.testNickname1 {
                    bobReceivesMessage()
                }
            }
            
            // Alice sends private message to Bob
            alice.sendPrivateMessage(
                TestConstants.testMessage1,
                to: bob.peerID,
                recipientNickname: TestConstants.testNickname2
            )
        }
    }
    
    @Test func privateMessageNotReceivedByOthers() async {
        alice.simulateConnection(with: bob)
        alice.simulateConnection(with: charlie)
        
        await confirmation("Bob receives private message") { bobReceivesMessage in
            bob.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 && message.isPrivate {
                    bobReceivesMessage()
                }
            }
            
            charlie.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 {
                    Issue.record("Charlie should not receive")
                }
            }

            alice.sendPrivateMessage(
                TestConstants.testMessage1,
                to: bob.peerID,
                recipientNickname: TestConstants.testNickname2
            )
        }
    }
    
    // MARK: - End-to-End Encryption Tests
    
    @Test func privateMessageEncryption() async {
        alice.simulateConnection(with: bob)
        
        // Setup Noise sessions
        let aliceKey = Curve25519.KeyAgreement.PrivateKey()
        let bobKey = Curve25519.KeyAgreement.PrivateKey()
        
        let aliceManager = NoiseSessionManager(localStaticKey: aliceKey, keychain: mockKeychain)
        let bobManager = NoiseSessionManager(localStaticKey: bobKey, keychain: mockKeychain)
        
        // Establish encrypted session
        do {
            let handshake1 = try aliceManager.initiateHandshake(with: bob.peerID)
            let handshake2 = try bobManager.handleIncomingHandshake(from: alice.peerID, message: handshake1)!
            let handshake3 = try aliceManager.handleIncomingHandshake(from: bob.peerID, message: handshake2)!
            _ = try bobManager.handleIncomingHandshake(from: alice.peerID, message: handshake3)
        } catch {
            Issue.record("Failed to establish Noise session: \(error)")
        }
        
        await confirmation("Encrypted message received") { receiveEncryptedMessage in
            // Setup packet handlers for encryption
            alice.packetDeliveryHandler = { packet in
                // Encrypt outgoing private messages
                if packet.type == 0x01,
                   let message = BitchatMessage(packet.payload),
                   message.isPrivate {
                    do {
                        let encrypted = try aliceManager.encrypt(packet.payload, for: bob.peerID)
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
                        Issue.record("Encryption failed: \(error)")
                    }
                }
            }
            
            bob.packetDeliveryHandler = { packet in
                // Decrypt incoming encrypted messages
                if packet.type == 0x02 {
                    do {
                        let decrypted = try bobManager.decrypt(packet.payload, from: alice.peerID)
                        if let message = BitchatMessage(decrypted) {
                            #expect(message.content == TestConstants.testMessage1)
                            #expect(message.isPrivate)
                            receiveEncryptedMessage()
                        }
                    } catch {
                        Issue.record("Decryption failed: \(error)")
                    }
                }
            }
            
            // Send encrypted private message
            alice.sendPrivateMessage(
                TestConstants.testMessage1,
                to: bob.peerID,
                recipientNickname: TestConstants.testNickname2
            )
        }
    }
    
    // MARK: - Multi-hop Private Message Tests
    
    @Test func privateMessageRelay() async {
        // Setup: Alice -> Bob -> Charlie
        alice.simulateConnection(with: bob)
        bob.simulateConnection(with: charlie)
        
        await confirmation("Private message relayed to Charlie") { charlieReceivesMessage in
            // Bob relays private messages for Charlie
            bob.packetDeliveryHandler = { packet in
                if let recipientID = packet.recipientID,
                   PeerID(data: recipientID) == charlie.peerID {
                    // Relay to Charlie
                    var relayPacket = packet
                    relayPacket.ttl = packet.ttl - 1
                    charlie.simulateIncomingPacket(relayPacket)
                }
            }
            
            charlie.messageDeliveryHandler = { message in
                if message.content == TestConstants.testMessage1 &&
                    message.isPrivate &&
                    message.recipientNickname == TestConstants.testNickname3 {
                    charlieReceivesMessage()
                }
            }
            
            // Alice sends private message to Charlie (through Bob)
            alice.sendPrivateMessage(
                TestConstants.testMessage1,
                to: charlie.peerID,
                recipientNickname: TestConstants.testNickname3
            )
        }
    }
    
    // MARK: - Performance Tests
    
    @Test func privateMessageThroughput() async {
        alice.simulateConnection(with: bob)
        
        let messageCount = 100
        var receivedCount = 0
        
        await confirmation("All private messages received") { receivePrivateMessage in
            bob.messageDeliveryHandler = { message in
                if message.isPrivate && message.sender == TestConstants.testNickname1 {
                    receivedCount += 1
                    if receivedCount == messageCount {
                        receivePrivateMessage()
                    }
                }
            }
            
            // Send many private messages
            for i in 0..<messageCount {
                alice.sendPrivateMessage(
                    "Private message \(i)",
                    to: bob.peerID,
                    recipientNickname: TestConstants.testNickname2
                )
            }
        }
    }

    @Test func largePrivateMessage() async {
        alice.simulateConnection(with: bob)

        await confirmation("Large private message received") { receiveLargeMessage in
            bob.messageDeliveryHandler = { message in
                if message.content == TestConstants.testLongMessage && message.isPrivate {
                    receiveLargeMessage()
                }
            }

            alice.sendPrivateMessage(
                TestConstants.testLongMessage,
                to: bob.peerID,
                recipientNickname: TestConstants.testNickname2
            )
        }
    }
}
