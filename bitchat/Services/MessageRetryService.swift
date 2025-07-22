//
// MessageRetryService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine
import CryptoKit

struct RetryableMessage {
    let id: String
    let originalMessageID: String? 
    let originalTimestamp: Date?
    let content: String
    let mentions: [String]?
    let isPrivate: Bool
    let recipientPeerID: String?
    let recipientNickname: String?
    let retryCount: Int
    let maxRetries: Int = 3
    let nextRetryTime: Date
}

class MessageRetryService {
    static let shared = MessageRetryService()
    
    private var retryQueue: [RetryableMessage] = []
    private var retryTimer: Timer?
    private let retryInterval: TimeInterval = 2.0 // Retry every 2 seconds for faster sync
    private let maxQueueSize = 50
    
    weak var meshService: BluetoothMeshService?
    
    private init() {
        startRetryTimer()
    }
    
    deinit {
        retryTimer?.invalidate()
    }
    
    private func startRetryTimer() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            self?.processRetryQueue()
        }
    }
    
    func addMessageForRetry(
        content: String,
        mentions: [String]? = nil,
        isPrivate: Bool = false,
        recipientPeerID: String? = nil,
        recipientNickname: String? = nil,
        originalMessageID: String? = nil,
        originalTimestamp: Date? = nil
    ) {
        // Don't queue empty or whitespace-only messages
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        // Don't queue if we're at capacity
        guard retryQueue.count < maxQueueSize else {
            return
        }
        
        // Check if this message is already in the queue
        if let messageID = originalMessageID {
            let alreadyQueued = retryQueue.contains { msg in
                msg.originalMessageID == messageID
            }
            if alreadyQueued {
                return // Don't add duplicate
            }
        }
        
        let retryMessage = RetryableMessage(
            id: UUID().uuidString,
            originalMessageID: originalMessageID,
            originalTimestamp: originalTimestamp,
            content: content,
            mentions: mentions,
            isPrivate: isPrivate,
            recipientPeerID: recipientPeerID,
            recipientNickname: recipientNickname,
            retryCount: 0,
            nextRetryTime: Date().addingTimeInterval(retryInterval)
        )
        
        retryQueue.append(retryMessage)
        
        // Sort the queue by original timestamp to maintain message order
        retryQueue.sort { (msg1, msg2) in
            let time1 = msg1.originalTimestamp ?? Date.distantPast
            let time2 = msg2.originalTimestamp ?? Date.distantPast
            return time1 < time2
        }
    }
    
    private func processRetryQueue() {
        guard meshService != nil else { return }
        
        let now = Date()
        var messagesToRetry: [RetryableMessage] = []
        var updatedQueue: [RetryableMessage] = []
        
        for message in retryQueue {
            if message.nextRetryTime <= now {
                messagesToRetry.append(message)
            } else {
                updatedQueue.append(message)
            }
        }
        
        retryQueue = updatedQueue
        
        // Sort messages by original timestamp to maintain order
        messagesToRetry.sort { (msg1, msg2) in
            let time1 = msg1.originalTimestamp ?? Date.distantPast
            let time2 = msg2.originalTimestamp ?? Date.distantPast
            return time1 < time2
        }
        
        // Send messages with delay to maintain order
        for (index, message) in messagesToRetry.enumerated() {
            // Check if we should still retry
            if message.retryCount >= message.maxRetries {
                continue
            }
            
            // Add delay between messages to ensure proper ordering
            let delay = Double(index) * 0.05 // 50ms between messages
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self,
                      let meshService = self.meshService else { return }
                
                // Check connectivity before retrying
                let viewModel = meshService.delegate as? ChatViewModel
                let connectedPeers = viewModel?.connectedPeers ?? []
                
                if message.isPrivate {
                    // For private messages, check if recipient is connected
                    if let recipientID = message.recipientPeerID,
                       connectedPeers.contains(recipientID) {
                        // Retry private message
                        meshService.sendPrivateMessage(
                            message.content,
                            to: recipientID,
                            recipientNickname: message.recipientNickname ?? "unknown",
                            messageID: message.originalMessageID
                        )
                    } else {
                        // Recipient not connected, keep in queue with updated retry time
                        var updatedMessage = message
                        updatedMessage = RetryableMessage(
                            id: message.id,
                            originalMessageID: message.originalMessageID,
                            originalTimestamp: message.originalTimestamp,
                            content: message.content,
                            mentions: message.mentions,
                            isPrivate: message.isPrivate,
                            recipientPeerID: message.recipientPeerID,
                            recipientNickname: message.recipientNickname,
                            retryCount: message.retryCount + 1,
                            nextRetryTime: Date().addingTimeInterval(self.retryInterval * Double(message.retryCount + 2))
                        )
                        self.retryQueue.append(updatedMessage)
                    }
                } else {
                    // Regular message
                    if !connectedPeers.isEmpty {
                        meshService.sendMessage(
                            message.content,
                            mentions: message.mentions ?? [],
                            to: nil,
                            messageID: message.originalMessageID,
                            timestamp: message.originalTimestamp
                        )
                    } else {
                        // No peers connected, keep in queue
                        var updatedMessage = message
                        updatedMessage = RetryableMessage(
                            id: message.id,
                            originalMessageID: message.originalMessageID,
                            originalTimestamp: message.originalTimestamp,
                            content: message.content,
                            mentions: message.mentions,
                            isPrivate: message.isPrivate,
                            recipientPeerID: message.recipientPeerID,
                            recipientNickname: message.recipientNickname,
                            retryCount: message.retryCount + 1,
                            nextRetryTime: Date().addingTimeInterval(self.retryInterval * Double(message.retryCount + 2))
                        )
                        self.retryQueue.append(updatedMessage)
                    }
                }
            }
        }
    }
    
    func clearRetryQueue() {
        retryQueue.removeAll()
    }
    
    func getRetryQueueCount() -> Int {
        return retryQueue.count
    }
}
