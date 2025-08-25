//
// PrivateChatManager.swift
// bitchat
//
// Manages private chat sessions and messages
// This is free and unencumbered software released into the public domain.
//

import Foundation
import SwiftUI

/// Manages all private chat functionality
class PrivateChatManager: ObservableObject {
    @Published var privateChats: [String: [BitchatMessage]] = [:]
    @Published var selectedPeer: String? = nil
    @Published var unreadMessages: Set<String> = []
    
    private var selectedPeerFingerprint: String? = nil
    var sentReadReceipts: Set<String> = []  // Made accessible for ChatViewModel
    
    weak var meshService: Transport?
    // Route acks/receipts via MessageRouter (chooses mesh or Nostr)
    weak var messageRouter: MessageRouter?
    
    init(meshService: Transport? = nil) {
        self.meshService = meshService
    }

    // Cap for messages stored per private chat
    private let privateChatCap = TransportConfig.privateChatCap
    
    /// Start a private chat with a peer
    func startChat(with peerID: String) {
        selectedPeer = peerID
        
        // Store fingerprint for persistence across reconnections
        if let fingerprint = meshService?.getFingerprint(for: peerID) {
            selectedPeerFingerprint = fingerprint
        }
        
        // Mark messages as read
        markAsRead(from: peerID)
        
        // Initialize chat if needed
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
    }
    
    /// End the current private chat
    func endChat() {
        selectedPeer = nil
        selectedPeerFingerprint = nil
    }
    
    /// Send a private message
    func sendMessage(_ content: String, to peerID: String) {
        guard let meshService = meshService,
              let peerNickname = meshService.peerNickname(peerID: peerID) else {
            return
        }
        
        let messageID = UUID().uuidString
        
        // Create local message
        let message = BitchatMessage(
            id: messageID,
            sender: meshService.myNickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: peerNickname,
            senderPeerID: meshService.myPeerID,
            mentions: nil,
            deliveryStatus: .sending
        )
        
        // Add to chat
        if privateChats[peerID] == nil { privateChats[peerID] = [] }
        privateChats[peerID]?.append(message)
        // Enforce per-chat cap on local append
        if var arr = privateChats[peerID], arr.count > privateChatCap {
            let remove = arr.count - privateChatCap
            arr.removeFirst(remove)
            privateChats[peerID] = arr
        }
        
        // Send via mesh service
        meshService.sendPrivateMessage(content, to: peerID, recipientNickname: peerNickname, messageID: messageID)
    }
    
    /// Handle incoming private message
    func handleIncomingMessage(_ message: BitchatMessage) {
        guard let senderPeerID = message.senderPeerID else { return }
        
        // Initialize chat if needed
        if privateChats[senderPeerID] == nil {
            privateChats[senderPeerID] = []
        }
        
        // Deduplicate by ID: replace existing message if present, else append
        if let idx = privateChats[senderPeerID]?.firstIndex(where: { $0.id == message.id }) {
            privateChats[senderPeerID]?[idx] = message
        } else {
            privateChats[senderPeerID]?.append(message)
        }

        // Sanitize chat to avoid duplicate IDs and sort by timestamp
        sanitizeChat(for: senderPeerID)
        // Enforce cap after sanitize
        if var arr = privateChats[senderPeerID], arr.count > privateChatCap {
            let remove = arr.count - privateChatCap
            arr.removeFirst(remove)
            privateChats[senderPeerID] = arr
        }
        
        // Mark as unread if not in this chat
        if selectedPeer != senderPeerID {
            unreadMessages.insert(senderPeerID)
            
            // Avoid notifying for messages already marked as read (dup/resubscribe cases)
            if !sentReadReceipts.contains(message.id) {
                NotificationService.shared.sendPrivateMessageNotification(
                    from: message.sender,
                    message: message.content,
                    peerID: senderPeerID
                )
            }
        } else {
            // Send read receipt if viewing this chat
            sendReadReceipt(for: message)
        }
    }

    /// Remove duplicate messages by ID and keep chronological order
    func sanitizeChat(for peerID: String) {
        guard let arr = privateChats[peerID] else { return }
        var seen = Set<String>()
        var deduped: [BitchatMessage] = []
        for msg in arr.sorted(by: { $0.timestamp < $1.timestamp }) {
            if !seen.contains(msg.id) {
                seen.insert(msg.id)
                deduped.append(msg)
            } else {
                // Replace previous with the latest occurrence (which is later in sort)
                if let index = deduped.firstIndex(where: { $0.id == msg.id }) {
                    deduped[index] = msg
                }
            }
        }
        privateChats[peerID] = deduped
    }
    
    /// Mark messages from a peer as read
    func markAsRead(from peerID: String) {
        unreadMessages.remove(peerID)
        
        // Send read receipts for unread messages that haven't been sent yet
        if let messages = privateChats[peerID] {
            for message in messages {
                if message.senderPeerID == peerID && !message.isRelay && !sentReadReceipts.contains(message.id) {
                    sendReadReceipt(for: message)
                }
            }
        }
    }
    
    /// Update the selected peer if fingerprint matches (for reconnections)
    func updateSelectedPeer(peers: [String: String]) {
        guard let fingerprint = selectedPeerFingerprint else { return }
        
        // Find peer with matching fingerprint
        for (peerID, _) in peers {
            if meshService?.getFingerprint(for: peerID) == fingerprint {
                selectedPeer = peerID
                break
            }
        }
    }
    
    /// Get chat messages for current context
    func getCurrentMessages() -> [BitchatMessage] {
        guard let peer = selectedPeer else { return [] }
        return privateChats[peer] ?? []
    }
    
    /// Clear a private chat
    func clearChat(with peerID: String) {
        privateChats[peerID]?.removeAll()
    }
    
    /// Handle delivery acknowledgment
    func handleDeliveryAck(messageID: String, from peerID: String) {
        guard privateChats[peerID] != nil else { return }
        
        if let index = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
            privateChats[peerID]?[index].deliveryStatus = .delivered(to: "recipient", at: Date())
        }
    }
    
    /// Handle read receipt
    func handleReadReceipt(messageID: String, from peerID: String) {
        guard privateChats[peerID] != nil else { return }
        
        if let index = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
            privateChats[peerID]?[index].deliveryStatus = .read(by: "recipient", at: Date())
        }
    }
    
    // MARK: - Private Methods
    
    private func sendReadReceipt(for message: BitchatMessage) {
        guard !sentReadReceipts.contains(message.id),
              let senderPeerID = message.senderPeerID else {
            return
        }
        
        sentReadReceipts.insert(message.id)
        
        // Create read receipt using the simplified method
        let receipt = ReadReceipt(
            originalMessageID: message.id,
            readerID: meshService?.myPeerID ?? "",
            readerNickname: meshService?.myNickname ?? ""
        )
        
        // Route via MessageRouter to avoid handshakeRequired spam when session isn't established
        if let router = messageRouter {
            SecureLogger.log("PrivateChatManager: sending READ ack for \(message.id.prefix(8))… to \(senderPeerID.prefix(8))… via router",
                            category: SecureLogger.session, level: .debug)
            Task { @MainActor in
                router.sendReadReceipt(receipt, to: senderPeerID)
            }
        } else {
            // Fallback: preserve previous behavior
            meshService?.sendReadReceipt(receipt, to: senderPeerID)
        }
    }
}
