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
    let content: String
    let mentions: [String]?
    let channel: String?
    let isPrivate: Bool
    let recipientPeerID: String?
    let recipientNickname: String?
    let channelKey: Data?
    let retryCount: Int
    let maxRetries: Int = 3
    let nextRetryTime: Date
}

class MessageRetryService {
    static let shared = MessageRetryService()
    
    private var retryQueue: [RetryableMessage] = []
    private var retryTimer: Timer?
    private let retryInterval: TimeInterval = 5.0 // Retry every 5 seconds
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
        channel: String? = nil,
        isPrivate: Bool = false,
        recipientPeerID: String? = nil,
        recipientNickname: String? = nil,
        channelKey: Data? = nil
    ) {
        // Don't queue if we're at capacity
        guard retryQueue.count < maxQueueSize else {
            return
        }
        
        let retryMessage = RetryableMessage(
            id: UUID().uuidString,
            content: content,
            mentions: mentions,
            channel: channel,
            isPrivate: isPrivate,
            recipientPeerID: recipientPeerID,
            recipientNickname: recipientNickname,
            channelKey: channelKey,
            retryCount: 0,
            nextRetryTime: Date().addingTimeInterval(retryInterval)
        )
        
        retryQueue.append(retryMessage)
    }
    
    private func processRetryQueue() {
        guard let meshService = meshService else { return }
        
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
        
        for message in messagesToRetry {
            // Check if we should still retry
            if message.retryCount >= message.maxRetries {
                continue
            }
            
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
                        recipientNickname: message.recipientNickname ?? "unknown"
                    )
                } else {
                    // Recipient not connected, keep in queue with updated retry time
                    var updatedMessage = message
                    updatedMessage = RetryableMessage(
                        id: message.id,
                        content: message.content,
                        mentions: message.mentions,
                        channel: message.channel,
                        isPrivate: message.isPrivate,
                        recipientPeerID: message.recipientPeerID,
                        recipientNickname: message.recipientNickname,
                        channelKey: message.channelKey,
                        retryCount: message.retryCount + 1,
                        nextRetryTime: Date().addingTimeInterval(retryInterval * Double(message.retryCount + 2))
                    )
                    retryQueue.append(updatedMessage)
                }
            } else if let channel = message.channel, let channelKeyData = message.channelKey {
                // For channel messages, check if we have peers in the channel
                if !connectedPeers.isEmpty {
                    // Recreate SymmetricKey from data
                    let channelKey = SymmetricKey(data: channelKeyData)
                    meshService.sendEncryptedChannelMessage(
                        message.content,
                        mentions: message.mentions ?? [],
                        channel: channel,
                        channelKey: channelKey
                    )
                } else {
                    // No peers connected, keep in queue
                    var updatedMessage = message
                    updatedMessage = RetryableMessage(
                        id: message.id,
                        content: message.content,
                        mentions: message.mentions,
                        channel: message.channel,
                        isPrivate: message.isPrivate,
                        recipientPeerID: message.recipientPeerID,
                        recipientNickname: message.recipientNickname,
                        channelKey: message.channelKey,
                        retryCount: message.retryCount + 1,
                        nextRetryTime: Date().addingTimeInterval(retryInterval * Double(message.retryCount + 2))
                    )
                    retryQueue.append(updatedMessage)
                }
            } else {
                // Regular message
                if !connectedPeers.isEmpty {
                    meshService.sendMessage(
                        message.content,
                        mentions: message.mentions ?? [],
                        channel: message.channel
                    )
                } else {
                    // No peers connected, keep in queue
                    var updatedMessage = message
                    updatedMessage = RetryableMessage(
                        id: message.id,
                        content: message.content,
                        mentions: message.mentions,
                        channel: message.channel,
                        isPrivate: message.isPrivate,
                        recipientPeerID: message.recipientPeerID,
                        recipientNickname: message.recipientNickname,
                        channelKey: message.channelKey,
                        retryCount: message.retryCount + 1,
                        nextRetryTime: Date().addingTimeInterval(retryInterval * Double(message.retryCount + 2))
                    )
                    retryQueue.append(updatedMessage)
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
