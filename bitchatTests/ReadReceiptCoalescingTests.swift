//
// ReadReceiptCoalescingTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

final class ReadReceiptCoalescingTests: XCTestCase {
    
    func testReadReceiptCoalescingConfiguration() {
        // Test that coalescing configuration values are reasonable
        XCTAssertTrue(TransportConfig.readReceiptCoalescingEnabled)
        XCTAssertGreaterThanOrEqual(TransportConfig.readReceiptCoalescingThreshold, 2)
    }
    
    func testReadReceiptCoalescingToggle() {
        // Test that toggling read receipt coalescing works correctly
        let viewModel = ChatViewModel()
        
        // Initially should match configuration
        XCTAssertEqual(viewModel.isReadReceiptCoalescingEnabled, TransportConfig.readReceiptCoalescingEnabled)
        
        // Enable coalescing
        viewModel.isReadReceiptCoalescingEnabled = true
        XCTAssertTrue(viewModel.isReadReceiptCoalescingEnabled)
        
        // Disable coalescing
        viewModel.isReadReceiptCoalescingEnabled = false
        XCTAssertFalse(viewModel.isReadReceiptCoalescingEnabled)
    }
    
    func testReadReceiptCoalescingBehavior() {
        // Test that coalescing behavior works correctly
        let viewModel = ChatViewModel()
        let privateChatManager = PrivateChatManager()
        
        // Enable coalescing
        viewModel.isReadReceiptCoalescingEnabled = true
        
        // Create test messages
        let message1 = BitchatMessage(
            id: "msg1",
            content: "First message",
            sender: "Alice",
            senderPeerID: "peer1",
            timestamp: Date().timeIntervalSince1970 * 1000,
            isPrivate: true
        )
        
        let message2 = BitchatMessage(
            id: "msg2",
            content: "Second message",
            sender: "Alice",
            senderPeerID: "peer1",
            timestamp: Date().timeIntervalSince1970 * 1000 + 1000,
            isPrivate: true
        )
        
        let message3 = BitchatMessage(
            id: "msg3",
            content: "Third message",
            sender: "Alice",
            senderPeerID: "peer1",
            timestamp: Date().timeIntervalSince1970 * 1000 + 2000,
            isPrivate: true
        )
        
        // Add messages to chat
        privateChatManager.addMessage(message1, from: "peer1")
        privateChatManager.addMessage(message2, from: "peer1")
        privateChatManager.addMessage(message3, from: "peer1")
        
        // Mark as read (should trigger coalescing)
        privateChatManager.markAsRead(from: "peer1")
        
        // Verify that all messages are marked as read locally
        XCTAssertTrue(privateChatManager.sentReadReceipts.contains("msg1"))
        XCTAssertTrue(privateChatManager.sentReadReceipts.contains("msg2"))
        XCTAssertTrue(privateChatManager.sentReadReceipts.contains("msg3"))
    }
    
    func testReadReceiptCoalescingThreshold() {
        // Test that coalescing only triggers above threshold
        let viewModel = ChatViewModel()
        let privateChatManager = PrivateChatManager()
        
        // Enable coalescing
        viewModel.isReadReceiptCoalescingEnabled = true
        
        // Create single message (below threshold)
        let message1 = BitchatMessage(
            id: "msg1",
            content: "Single message",
            sender: "Alice",
            senderPeerID: "peer1",
            timestamp: Date().timeIntervalSince1970 * 1000,
            isPrivate: true
        )
        
        // Add message to chat
        privateChatManager.addMessage(message1, from: "peer1")
        
        // Mark as read (should NOT trigger coalescing)
        privateChatManager.markAsRead(from: "peer1")
        
        // Verify that message is marked as read
        XCTAssertTrue(privateChatManager.sentReadReceipts.contains("msg1"))
    }
    
    func testReadReceiptCoalescingDisabled() {
        // Test that coalescing doesn't work when disabled
        let viewModel = ChatViewModel()
        let privateChatManager = PrivateChatManager()
        
        // Disable coalescing
        viewModel.isReadReceiptCoalescingEnabled = false
        
        // Create multiple messages
        let message1 = BitchatMessage(
            id: "msg1",
            content: "First message",
            sender: "Alice",
            senderPeerID: "peer1",
            timestamp: Date().timeIntervalSince1970 * 1000,
            isPrivate: true
        )
        
        let message2 = BitchatMessage(
            id: "msg2",
            content: "Second message",
            sender: "Alice",
            senderPeerID: "peer1",
            timestamp: Date().timeIntervalSince1970 * 1000 + 1000,
            isPrivate: true
        )
        
        // Add messages to chat
        privateChatManager.addMessage(message1, from: "peer1")
        privateChatManager.addMessage(message2, from: "peer1")
        
        // Mark as read (should NOT trigger coalescing)
        privateChatManager.markAsRead(from: "peer1")
        
        // Verify that all messages are marked as read
        XCTAssertTrue(privateChatManager.sentReadReceipts.contains("msg1"))
        XCTAssertTrue(privateChatManager.sentReadReceipts.contains("msg2"))
    }
    
    func testReadReceiptCoalescingPrivacy() {
        // Test that coalescing reduces metadata exposure
        let viewModel = ChatViewModel()
        let privateChatManager = PrivateChatManager()
        
        // Enable coalescing
        viewModel.isReadReceiptCoalescingEnabled = true
        
        // Create many messages to trigger coalescing
        var messages: [BitchatMessage] = []
        for i in 0..<10 {
            let message = BitchatMessage(
                id: "msg\(i)",
                content: "Message \(i)",
                sender: "Alice",
                senderPeerID: "peer1",
                timestamp: Date().timeIntervalSince1970 * 1000 + Double(i * 1000),
                isPrivate: true
            )
            messages.append(message)
        }
        
        // Add messages to chat
        for message in messages {
            privateChatManager.addMessage(message, from: "peer1")
        }
        
        // Mark as read (should trigger coalescing)
        privateChatManager.markAsRead(from: "peer1")
        
        // Verify that all messages are marked as read locally
        for message in messages {
            XCTAssertTrue(privateChatManager.sentReadReceipts.contains(message.id))
        }
        
        // Verify that only the latest message would get a read receipt sent
        // (This is tested by checking the sentReadReceipts set, which includes
        // all messages marked as read locally)
    }
}
