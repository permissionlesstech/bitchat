
//
// MessageRetryService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import CryptoKit
import Foundation

// MARK: - RetryableMessage

struct RetryableMessage: Sendable {
    let id: String
    let originalMessageID: String?
    let originalTimestamp: Date?
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

// MARK: - MessageRetryService

/// A singleton service responsible for retrying messages when connectivity is lost.
/// Supports retrying private, channel, and regular messages with exponential backoff.
final class MessageRetryService: @unchecked Sendable {
    // MARK: Lifecycle

    private init() {
        startRetryTimer()
    }

    deinit {
        retryTimer?.invalidate()
    }

    // MARK: Internal

    // MARK: - Singleton

    /// Shared instance of the retry service.
    static let shared = MessageRetryService()

    // MARK: - Dependencies

    /// Bluetooth mesh service used to resend messages.
    weak var meshService: BluetoothMeshService?

    // MARK: - Internal API

    /// Adds a message to the retry queue if capacity allows.
    func addMessageForRetry(
        content: String,
        originalMessageID: String? = nil,
        originalTimestamp: Date? = nil,
        mentions: [String]? = nil,
        channel: String? = nil,
        isPrivate: Bool = false,
        recipientPeerID: String? = nil,
        recipientNickname: String? = nil,
        channelKey: Data? = nil
    ) {
        queue.async(flags: .barrier) {
            guard self.retryQueue.count < self.maxQueueSize else {
                return
            }

            let retryMessage = RetryableMessage(
                id: UUID().uuidString,
                originalMessageID: originalMessageID,
                originalTimestamp: originalTimestamp,
                content: content,
                mentions: mentions,
                channel: channel,
                isPrivate: isPrivate,
                recipientPeerID: recipientPeerID,
                recipientNickname: recipientNickname,
                channelKey: channelKey,
                retryCount: 0,
                nextRetryTime: Date().addingTimeInterval(self.retryInterval)
            )

            self.retryQueue.append(retryMessage)
                self.retryQueue.sort { ($0.originalTimestamp ?? .distantPast) < ($1.originalTimestamp ?? .distantPast) }
        }
    }

    /// Clears all pending retry messages.
    func clearRetryQueue() {
        queue.async(flags: .barrier) {
            self.retryQueue.removeAll()
        }
    }

    /// Returns the number of messages currently in the retry queue.
    func getRetryQueueCount() -> Int {
        queue.sync {
            retryQueue.count
        }
    }

    // MARK: Private

    // MARK: - Constants & State

    /// Timer that periodically triggers retry logic.
    private var retryTimer: Timer?

    /// Queue for thread-safe mutation of the retry array.
    private let queue = DispatchQueue(
        label: "com.bitchat.MessageRetryService.queue",
        attributes: .concurrent
    )

    /// Internal queue of retryable messages.
    private var retryQueue: [RetryableMessage] = []

    /// Interval in seconds to check and retry messages.
    private let retryInterval: TimeInterval = 5.0

    /// Maximum number of messages allowed in the retry queue.
    private let maxQueueSize = 50

    /// Starts a repeating timer that periodically attempts to resend messages.
    private func startRetryTimer() {
        retryTimer = Timer.scheduledTimer(
            withTimeInterval: retryInterval,
            repeats: true
        ) { [weak self] _ in
            self?.processRetryQueue()
        }
    }

    /// Main logic that processes retry-eligible messages.
    private func processRetryQueue() {
        guard let meshService else {
            return
        }

        queue.async(flags: .barrier) {
            let now = Date()
            var updatedQueue: [RetryableMessage] = []
            var messagesToRetry: [RetryableMessage] = []

            for message in self.retryQueue {
                if message.nextRetryTime <= now {
                    messagesToRetry.append(message)
                } else {
                    updatedQueue.append(message)
                }
            }

            self.retryQueue = updatedQueue
            let connectedPeers =
                (meshService.delegate as? ChatViewModel)?.connectedPeers ?? []

                            let delay = Double(index) * 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }

                guard message.retryCount < message.maxRetries else {
                    continue
                }

                if message.isPrivate,
                    let recipientID = message.recipientPeerID,
                    connectedPeers.contains(recipientID)
                {
                    meshService.sendPrivateMessage(
                        message.content,
                        to: recipientID,
                        recipientNickname: message.recipientNickname ?? "unknown"
                    )
                } else if let channel = message.channel,
                    let channelKeyData = message.channelKey,
                    !connectedPeers.isEmpty
                {
                    let key = SymmetricKey(data: channelKeyData)
                    meshService.sendEncryptedChannelMessage(
                        message.content,
                        mentions: message.mentions ?? [],
                        channel: channel,
                        channelKey: key
                    )
                } else if !connectedPeers.isEmpty {
                    meshService.sendMessage(
                        message.content,
                        mentions: message.mentions ?? [],
                        channel: message.channel
                    )
                } else {
                    let updatedMessage = RetryableMessage(
                        id: message.id,
                        content: message.content,
                        mentions: message.mentions,
                        channel: message.channel,
                        isPrivate: message.isPrivate,
                        recipientPeerID: message.recipientPeerID,
                        recipientNickname: message.recipientNickname,
                        channelKey: message.channelKey,
                        retryCount: message.retryCount + 1,
                        nextRetryTime: Date().addingTimeInterval(
                            self.retryInterval * Double(message.retryCount + 2)
                        )
                    )
                    self.retryQueue.append(updatedMessage)
                }
            }
        }
    }
}
