//
// PrivateChatManager.swift
// bitchat
//
// Manages private chat sessions and messages
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation
import SwiftUI

/// Manages all private chat functionality
final class PrivateChatManager: ObservableObject {
    @Published var privateChats: [Peer: [BitchatMessage]] = [:]
    @Published var selectedPeer: Peer? = nil
    @Published var unreadMessages: Set<Peer> = []
    
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
    func startChat(with peer: Peer) {
        selectedPeer = peer
        
        // Store fingerprint for persistence across reconnections
        if let fingerprint = meshService?.getFingerprint(for: peer) {
            selectedPeerFingerprint = fingerprint
        }
        
        // Mark messages as read
        markAsRead(from: peer)
        
        // Initialize chat if needed
        if privateChats[peer] == nil {
            privateChats[peer] = []
        }
    }
    
    /// End the current private chat
    func endChat() {
        selectedPeer = nil
        selectedPeerFingerprint = nil
    }
    
    /// Remove duplicate messages by ID and keep chronological order
    func sanitizeChat(for peer: Peer) {
        guard let arr = privateChats[peer] else { return }
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
        privateChats[peer] = deduped
    }
    
    /// Mark messages from a peer as read
    func markAsRead(from peer: Peer) {
        unreadMessages.remove(peer)
        
        // Send read receipts for unread messages that haven't been sent yet
        if let messages = privateChats[peer] {
            for message in messages {
                if message.senderPeer == peer && !message.isRelay && !sentReadReceipts.contains(message.id) {
                    sendReadReceipt(for: message)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func sendReadReceipt(for message: BitchatMessage) {
        guard !sentReadReceipts.contains(message.id),
              let senderPeer = message.senderPeer else {
            return
        }
        
        sentReadReceipts.insert(message.id)
        
        // Create read receipt using the simplified method
        let receipt = ReadReceipt(
            originalMessageID: message.id,
            reader: meshService?.myPeer ?? .empty,
            readerNickname: meshService?.myNickname ?? ""
        )
        
        // Route via MessageRouter to avoid handshakeRequired spam when session isn't established
        if let router = messageRouter {
            SecureLogger.debug("PrivateChatManager: sending READ ack for \(message.id.prefix(8))… to \(senderPeer.id.prefix(8))… via router", category: .session)
            Task { @MainActor in
                router.sendReadReceipt(receipt, to: senderPeer)
            }
        } else {
            // Fallback: preserve previous behavior
            meshService?.sendReadReceipt(receipt, to: senderPeer)
        }
    }
}
