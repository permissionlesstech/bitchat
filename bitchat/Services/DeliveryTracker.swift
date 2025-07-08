//
// DeliveryTracker.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation

/// Tracks message delivery, retries, timeouts, and acknowledgement (ACK) status.
final class DeliveryTracker: @unchecked Sendable {
    // MARK: Lifecycle

    // MARK: - Init

    private init() {
        startCleanupTimer()
    }

    deinit {
        cleanupTimer?.invalidate()
    }

    // MARK: Internal

    // MARK: - Model

    /// Represents a message currently being tracked for delivery.
    struct PendingDelivery {
        let messageID: String
        let sentAt: Date
        let recipientID: String
        let recipientNickname: String
        let retryCount: Int
        let isChannelMessage: Bool
        let isFavorite: Bool
        var ackedBy: Set<String> = []
        let expectedRecipients: Int
        var timeoutTimer: Timer?

        var isTimedOut: Bool {
            let timeout: TimeInterval =
                isFavorite ? 300 : (isChannelMessage ? 60 : 30)
            return Date().timeIntervalSince(sentAt) > timeout
        }

        var shouldRetry: Bool {
            retryCount < 3 && isFavorite && !isChannelMessage
        }
    }

    // MARK: - Singleton

    /// Shared singleton instance.
    static let shared = DeliveryTracker()

    /// Publishes delivery status updates.
    let deliveryStatusUpdated = PassthroughSubject<
        (messageID: String, status: DeliveryStatus), Never
    >()

    // MARK: - Public Methods

    /// Begins tracking a message’s delivery.
    func trackMessage(
        _ message: BitchatMessage,
        recipientID: String,
        recipientNickname: String,
        isFavorite: Bool = false,
        expectedRecipients: Int = 1
    ) {
        guard message.isPrivate || message.channel != nil else {
            return
        }

        let delivery = PendingDelivery(
            messageID: message.id,
            sentAt: Date(),
            recipientID: recipientID,
            recipientNickname: recipientNickname,
            retryCount: 0,
            isChannelMessage: message.channel != nil,
            isFavorite: isFavorite,
            expectedRecipients: expectedRecipients,
            timeoutTimer: nil
        )

        pendingLock.lock()
        pendingDeliveries[message.id] = delivery
        pendingLock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateDeliveryStatus(message.id, status: .sent)
        }

        scheduleTimeout(for: message.id)
    }

    /// Processes a received ACK for a message.
    func processDeliveryAck(_ ack: DeliveryAck) {
        pendingLock.lock()
        defer { pendingLock.unlock() }

        guard !receivedAckIDs.contains(ack.ackID) else {
            return
        }
        receivedAckIDs.insert(ack.ackID)

        guard var delivery = pendingDeliveries[ack.originalMessageID] else {
            return
        }
        delivery.timeoutTimer?.invalidate()

        if delivery.isChannelMessage {
            delivery.ackedBy.insert(ack.recipientID)
            pendingDeliveries[ack.originalMessageID] = delivery

            let deliveredCount = delivery.ackedBy.count
            let totalExpected = delivery.expectedRecipients

            if deliveredCount >= totalExpected
                || deliveredCount >= max(1, totalExpected / 2)
            {
                updateDeliveryStatus(
                    ack.originalMessageID,
                    status: .delivered(
                        to: "\(deliveredCount) members",
                        at: Date()
                    )
                )
                pendingDeliveries.removeValue(forKey: ack.originalMessageID)
            } else {
                updateDeliveryStatus(
                    ack.originalMessageID,
                    status: .partiallyDelivered(
                        reached: deliveredCount,
                        total: totalExpected
                    )
                )
            }
        } else {
            updateDeliveryStatus(
                ack.originalMessageID,
                status: .delivered(to: ack.recipientNickname, at: Date())
            )
            pendingDeliveries.removeValue(forKey: ack.originalMessageID)
        }
    }

    /// Generates an ACK for an incoming message, if valid.
    func generateAck(
        for message: BitchatMessage,
        myPeerID: String,
        myNickname: String,
        hopCount: UInt8
    ) -> DeliveryAck? {
        guard message.senderPeerID != myPeerID,
            message.isPrivate || message.channel != nil,
            !sentAckIDs.contains(message.id)
        else {
            return nil
        }

        sentAckIDs.insert(message.id)

        return DeliveryAck(
            originalMessageID: message.id,
            recipientID: myPeerID,
            recipientNickname: myNickname,
            hopCount: hopCount
        )
    }

    /// Clears delivery tracking for a message.
    func clearDeliveryStatus(for messageID: String) {
        pendingLock.lock()
        defer { pendingLock.unlock() }

        if let delivery = pendingDeliveries[messageID] {
            delivery.timeoutTimer?.invalidate()
        }
        pendingDeliveries.removeValue(forKey: messageID)
    }

    // MARK: Private

    // MARK: - State

    /// Pending messages being tracked for delivery.
    private var pendingDeliveries: [String: PendingDelivery] = [:]

    /// Lock for safe concurrent access to `pendingDeliveries`.
    private let pendingLock = NSLock()

    /// Tracks received ACK IDs to prevent duplicate processing.
    private var receivedAckIDs = Set<String>()

    /// Tracks sent ACK IDs to avoid duplicate responses.
    private var sentAckIDs = Set<String>()

    // MARK: - Configuration

    private let privateMessageTimeout: TimeInterval = 30
    private let roomMessageTimeout: TimeInterval = 60
    private let favoriteTimeout: TimeInterval = 300
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 5

    private var cleanupTimer: Timer?

    // MARK: - Private Methods

    private func updateDeliveryStatus(
        _ messageID: String,
        status: DeliveryStatus
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.deliveryStatusUpdated.send(
                (messageID: messageID, status: status)
            )
        }
    }

    private func scheduleTimeout(for messageID: String) {
        pendingLock.lock()
        guard let delivery = pendingDeliveries[messageID] else {
            pendingLock.unlock()
            return
        }
        let timeout: TimeInterval =
            delivery.isFavorite
            ? favoriteTimeout
            : (delivery.isChannelMessage
                ? roomMessageTimeout : privateMessageTimeout)
        pendingLock.unlock()

        let timer = Timer.scheduledTimer(
            withTimeInterval: timeout,
            repeats: false
        ) { [weak self] _ in
            self?.handleTimeout(messageID: messageID)
        }

        pendingLock.lock()
        if var updatedDelivery = pendingDeliveries[messageID] {
            updatedDelivery.timeoutTimer = timer
            pendingDeliveries[messageID] = updatedDelivery
        }
        pendingLock.unlock()
    }

    private func handleTimeout(messageID: String) {
        pendingLock.lock()
        guard let delivery = pendingDeliveries[messageID] else {
            pendingLock.unlock()
            return
        }

        if delivery.shouldRetry {
            pendingLock.unlock()
            retryDelivery(messageID: messageID)
        } else {
            let reason =
                delivery.isChannelMessage
                ? "No response from channel members" : "Message not delivered"
            pendingDeliveries.removeValue(forKey: messageID)
            pendingLock.unlock()
            updateDeliveryStatus(messageID, status: .failed(reason: reason))
        }
    }

    private func retryDelivery(messageID: String) {
        pendingLock.lock()
        guard let delivery = pendingDeliveries[messageID] else {
            pendingLock.unlock()
            return
        }

        let newDelivery = PendingDelivery(
            messageID: delivery.messageID,
            sentAt: delivery.sentAt,
            recipientID: delivery.recipientID,
            recipientNickname: delivery.recipientNickname,
            retryCount: delivery.retryCount + 1,
            isChannelMessage: delivery.isChannelMessage,
            isFavorite: delivery.isFavorite,
            ackedBy: delivery.ackedBy,
            expectedRecipients: delivery.expectedRecipients,
            timeoutTimer: nil
        )

        pendingDeliveries[messageID] = newDelivery
        let retryCount = delivery.retryCount
        pendingLock.unlock()

        let delay = retryDelay * pow(2, Double(retryCount))

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            NotificationCenter.default.post(
                name: Notification.Name("bitchat.retryMessage"),
                object: nil,
                userInfo: ["messageID": messageID]
            )
            self?.scheduleTimeout(for: messageID)
        }
    }

    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true)
        { [weak self] _ in
            self?.cleanupOldDeliveries()
        }
    }

    private func cleanupOldDeliveries() {
        pendingLock.lock()
        defer { pendingLock.unlock() }

        let now = Date()
        let maxAge: TimeInterval = 3600

        pendingDeliveries = pendingDeliveries.filter {
            now.timeIntervalSince($0.value.sentAt) < maxAge
        }

        if receivedAckIDs.count > 1000 {
            receivedAckIDs.removeAll()
        }
        if sentAckIDs.count > 1000 {
            sentAckIDs.removeAll()
        }
    }
}
