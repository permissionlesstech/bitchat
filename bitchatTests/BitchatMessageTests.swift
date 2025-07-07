//
// BitchatMessageTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class BitchatMessageTests: XCTestCase {
    
    func testMessageEncodingDecoding() {
        let message = BitchatMessage(
            sender: "testuser",
            content: "Hello, World!",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: "peer123",
            mentions: ["alice", "bob"]
        )
        
        guard let encoded = message.toBinaryPayload() else {
            XCTFail("Failed to encode message")
            return
        }
        
        guard let decoded = BitchatMessage.fromBinaryPayload(encoded) else {
            XCTFail("Failed to decode message")
            return
        }
        
        XCTAssertEqual(decoded.sender, message.sender)
        XCTAssertEqual(decoded.content, message.content)
        XCTAssertEqual(decoded.isPrivate, message.isPrivate)
        XCTAssertEqual(decoded.mentions?.count, 2)
        XCTAssertTrue(decoded.mentions?.contains("alice") ?? false)
        XCTAssertTrue(decoded.mentions?.contains("bob") ?? false)
    }
    
    func testRoomMessage() {
        let channelMessage = BitchatMessage(
            sender: "alice",
            content: "Hello #general",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: "alice123",
            mentions: nil,
            channel: "#general"
        )
        
        guard let encoded = channelMessage.toBinaryPayload() else {
            XCTFail("Failed to encode channel message")
            return
        }
        
        guard let decoded = BitchatMessage.fromBinaryPayload(encoded) else {
            XCTFail("Failed to decode channel message")
            return
        }
        
        XCTAssertEqual(decoded.channel, "#general")
        XCTAssertEqual(decoded.content, channelMessage.content)
    }
    
    func testEncryptedRoomMessage() {
        let encryptedData = Data([1, 2, 3, 4, 5, 6, 7, 8]) // Mock encrypted content
        
        let encryptedMessage = BitchatMessage(
            sender: "bob",
            content: "", // Empty for encrypted messages
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: "bob456",
            mentions: nil,
            channel: "#secret",
            encryptedContent: encryptedData,
            isEncrypted: true
        )
        
        guard let encoded = encryptedMessage.toBinaryPayload() else {
            XCTFail("Failed to encode encrypted message")
            return
        }
        
        guard let decoded = BitchatMessage.fromBinaryPayload(encoded) else {
            XCTFail("Failed to decode encrypted message")
            return
        }
        
        XCTAssertTrue(decoded.isEncrypted)
        XCTAssertEqual(decoded.encryptedContent, encryptedData)
        XCTAssertEqual(decoded.channel, "#secret")
        XCTAssertEqual(decoded.content, "") // Content should be empty for encrypted messages
    }
    
    func testPrivateMessage() {
        let privateMessage = BitchatMessage(
            sender: "alice",
            content: "This is private",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "bob",
            senderPeerID: "alicePeer"
        )
        
        guard let encoded = privateMessage.toBinaryPayload() else {
            XCTFail("Failed to encode private message")
            return
        }
        
        guard let decoded = BitchatMessage.fromBinaryPayload(encoded) else {
            XCTFail("Failed to decode private message")
            return
        }
        
        XCTAssertTrue(decoded.isPrivate)
        XCTAssertEqual(decoded.recipientNickname, "bob")
    }
    
    func testRelayMessage() {
        let relayMessage = BitchatMessage(
            sender: "charlie",
            content: "Relayed message",
            timestamp: Date(),
            isRelay: true,
            originalSender: "alice",
            isPrivate: false
        )
        
        guard let encoded = relayMessage.toBinaryPayload() else {
            XCTFail("Failed to encode relay message")
            return
        }
        
        guard let decoded = BitchatMessage.fromBinaryPayload(encoded) else {
            XCTFail("Failed to decode relay message")
            return
        }
        
        XCTAssertTrue(decoded.isRelay)
        XCTAssertEqual(decoded.originalSender, "alice")
    }
    
    func testEmptyContent() {
        let emptyMessage = BitchatMessage(
            sender: "user",
            content: "",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil
        )
        
        guard let encoded = emptyMessage.toBinaryPayload() else {
            XCTFail("Failed to encode empty message")
            return
        }
        
        guard let decoded = BitchatMessage.fromBinaryPayload(encoded) else {
            XCTFail("Failed to decode empty message")
            return
        }
        
        XCTAssertEqual(decoded.content, "")
    }
    
    func testLongContent() {
        let longContent = String(repeating: "A", count: 1000)
        let longMessage = BitchatMessage(
            sender: "user",
            content: longContent,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil
        )
        
        guard let encoded = longMessage.toBinaryPayload() else {
            XCTFail("Failed to encode long message")
            return
        }
        
        guard let decoded = BitchatMessage.fromBinaryPayload(encoded) else {
            XCTFail("Failed to decode long message")
            return
        }
        
        XCTAssertEqual(decoded.content, longContent)
    }
}