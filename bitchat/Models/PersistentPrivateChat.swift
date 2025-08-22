//
//  PersistentPrivateChat.swift
//  bitchat
//
//  Created by Waluya Juang Husada on 20/08/25.
//


//
// PersistentPrivateChat.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Represents a persistent private chat room tied to a peer's fingerprint
/// This ensures chat rooms persist even when peers go offline or change peerIDs
struct PersistentPrivateChat: Codable, Identifiable {
    let id: String // fingerprint of the peer
    let fingerprint: String // Same as id, for clarity
    var peerNickname: String // Last known nickname
    var messages: [BitchatMessage]
    var pendingMessages: [BitchatMessage] // Messages waiting to be sent when peer comes online
    var lastSeen: Date
    var isOnline: Bool
    var currentPeerID: String? // Current ephemeral peer ID if online
    var unreadCount: Int
    var chatCreatedDate: Date
    
    init(fingerprint: String, peerNickname: String, currentPeerID: String? = nil) {
        self.id = fingerprint
        self.fingerprint = fingerprint
        self.peerNickname = peerNickname
        self.messages = []
        self.pendingMessages = []
        self.lastSeen = Date()
        self.isOnline = false
        self.currentPeerID = currentPeerID
        self.unreadCount = 0
        self.chatCreatedDate = Date()
    }
    
    /// Update peer status when they come online
    mutating func peerCameOnline(peerID: String) {
        self.isOnline = true
        self.currentPeerID = peerID
        self.lastSeen = Date()
    }
    
    /// Update peer status when they go offline
    mutating func peerWentOffline() {
        self.isOnline = false
        self.currentPeerID = nil
        self.lastSeen = Date()
    }
    
    /// Add a new message to the chat
    mutating func addMessage(_ message: BitchatMessage) {
        // Check for duplicates
        if !messages.contains(where: { $0.id == message.id }) {
            messages.append(message)
            messages.sort { $0.timestamp < $1.timestamp }
            
            // If message is from peer, increment unread count
            if message.senderPeerID != nil && message.senderPeerID != "my_peer_id" {
                unreadCount += 1
            }
        }
    }
    
    /// Add a pending message (to be sent when peer comes online)
    mutating func addPendingMessage(_ message: BitchatMessage) {
        if !pendingMessages.contains(where: { $0.id == message.id }) {
            pendingMessages.append(message)
        }
    }
    
    /// Move pending messages to sent messages and return them for actual sending
    mutating func promotePendingMessages() -> [BitchatMessage] {
        let toSend = pendingMessages
        for message in toSend {
            addMessage(message)
        }
        pendingMessages.removeAll()
        return toSend
    }
    
    /// Mark all messages as read
    mutating func markAsRead() {
        unreadCount = 0
    }
    
    /// Update peer nickname
    mutating func updateNickname(_ nickname: String) {
        self.peerNickname = nickname
    }
    
    /// Get display name for the chat
    var displayName: String {
        return peerNickname.isEmpty ? "Unknown (\(fingerprint.prefix(8)))" : peerNickname
    }
    
    /// Get status indicator for the chat
    var statusIndicator: String {
        if isOnline {
            return "🟢" // Green circle for online
        } else if !pendingMessages.isEmpty {
            return "🟡" // Yellow circle for pending messages
        } else {
            return "⚫" // Black circle for offline
        }
    }
    
    /// Get status text
    var statusText: String {
        if isOnline {
            return "In Range"
        } else if !pendingMessages.isEmpty {
            return "Pending (\(pendingMessages.count))"
        } else {
            return "Out of Range"
        }
    }
}

/// Peer status for UI display
enum PeerStatus {
    case online(peerID: String)
    case offline
    case pendingMessages(count: Int)
    
    var displayText: String {
        switch self {
        case .online:
            return "In Range"
        case .offline:
            return "Out of Range"
        case .pendingMessages(let count):
            return "Pending (\(count))"
        }
    }
    
    var indicator: String {
        switch self {
        case .online:
            return "🟢"
        case .offline:
            return "⚫"
        case .pendingMessages:
            return "🟡"
        }
    }
}
