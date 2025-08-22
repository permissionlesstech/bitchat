//
//  HistoryRequest.swift
//  bitchat
//
//  Created by Waluya Juang Husada on 20/08/25.
//


//
// HistoryRequest.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

// MARK: - Chat History Synchronization Structures

/// Request for chat history from a peer
struct HistoryRequest: Codable {
    let requestID: String
    let timestamp: Date
    let lastMessageID: String? // Last message ID we have, for incremental sync
    
    init(requestID: String = UUID().uuidString, lastMessageID: String? = nil) {
        self.requestID = requestID
        self.timestamp = Date()
        self.lastMessageID = lastMessageID
    }
}

/// Response containing chat history
struct HistoryResponse: Codable {
    let requestID: String
    let messages: [BitchatMessage]
    let hasMore: Bool // Indicates if there are more messages to sync
    
    init(requestID: String, messages: [BitchatMessage], hasMore: Bool = false) {
        self.requestID = requestID
        self.messages = messages
        self.hasMore = hasMore
    }
}

/// Individual message sync for missing messages
struct HistorySync: Codable {
    let messageID: String
    let message: BitchatMessage
    
    init(messageID: String, message: BitchatMessage) {
        self.messageID = messageID
        self.message = message
    }
}
