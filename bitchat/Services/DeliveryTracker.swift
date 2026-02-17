//
// DeliveryTracker.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine

/// Singleton that tracks outgoing message delivery lifecycle — from send through
/// acknowledgment, timeout, and retry.
///
/// Publishes ``DeliveryStatus`` updates via ``deliveryStatusUpdated`` so the UI can
/// show real-time delivery indicators (sending → sent → delivered → read / failed).
///
/// Thread-safe: all mutable state is protected by `pendingLock`.
class DeliveryTracker {
    /// Shared singleton instance.
    static let shared = DeliveryTracker()

    private var pendingDeliveries: [String: PendingDelivery] = [:]
    private let pendingLock = NSLock()

    private var receivedAckIDs = Set<String>()
    private var sentAckIDs = Set<String>()

    private let privateMessageTimeout: TimeInterval = 30
    private let roomMessageTimeout: TimeInterval = 60
    private let favoriteTimeout: TimeInterval = 300

    private let maxRetries = 3
    private let retryDelay: TimeInterval = 5

    /// Combine publisher that emits `(messageID, status)` tuples whenever a message's
    /// delivery status changes. Subscribe from the UI layer to update indicators.
    let deliveryStatusUpdated = PassthroughSubject<(messageID: String, status: DeliveryStatus), Never>()

    private var cleanupTimer: Timer?

    /// In-flight delivery metadata for a single outgoing message.
    struct PendingDelivery {
        let messageID: String
        let sentAt: Date
        let recipientID: String
        let recipientNickname: String
        let retryCount: Int
        let isRoomMessage: Bool
        let isFavorite: Bool
        /// Set of peer IDs that have acknowledged receipt (used for room partial delivery).
        var ackedBy: Set<String> = []
        /// Total number of expected recipients (for room messages).
        let expectedRecipients: Int
        var timeoutTimer: Timer?
        
        var isTimedOut: Bool {
            let timeout: TimeInterval = isFavorite ? 300 : (isRoomMessage ? 60 : 30)
            return Date().timeIntervalSince(sentAt) > timeout
        }
        
        var shouldRetry: Bool {
            return retryCount < 3 && isFavorite && !isRoomMessage
        }
    }
    
    private init() {
        startCleanupTimer()
    }
    
    deinit {
        cleanupTimer?.invalidate()
    }
    
    // MARK: - Public Methods
    
    /// Begins tracking delivery for an outgoing message.
    ///
    /// Only private and room messages are tracked; broadcasts are ignored.
    /// The status transitions to `.sent` after a short delay and a timeout is scheduled.
    ///
    /// - Parameters:
    ///   - message: The outgoing ``BitchatMessage``.
    ///   - recipientID: Target peer ID (or representative ID for room messages).
    ///   - recipientNickname: Display name of the recipient.
    ///   - isFavorite: If `true`, uses a longer timeout (5 min) and enables retries.
    ///   - expectedRecipients: For room messages, the total number of members expected to ACK.
    func trackMessage(_ message: BitchatMessage, recipientID: String, recipientNickname: String, isFavorite: Bool = false, expectedRecipients: Int = 1) {
        // Don't track broadcasts or certain message types
        guard message.isPrivate || message.room != nil else { return }
        
        
        let delivery = PendingDelivery(
            messageID: message.id,
            sentAt: Date(),
            recipientID: recipientID,
            recipientNickname: recipientNickname,
            retryCount: 0,
            isRoomMessage: message.room != nil,
            isFavorite: isFavorite,
            expectedRecipients: expectedRecipients,
            timeoutTimer: nil
        )
        
        // Store the delivery with lock
        pendingLock.lock()
        pendingDeliveries[message.id] = delivery
        pendingLock.unlock()
        
        // Update status to sent
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateDeliveryStatus(message.id, status: .sent)
        }
        
        // Schedule timeout (outside of lock)
        scheduleTimeout(for: message.id)
    }
    
    /// Processes an incoming ``DeliveryAck``, updating the message's delivery status.
    ///
    /// For direct messages the status moves to `.delivered`. For room messages,
    /// partial delivery is tracked until at least half the expected recipients ACK.
    /// Duplicate ACK IDs are silently ignored.
    func processDeliveryAck(_ ack: DeliveryAck) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        
        
        // Prevent duplicate ACK processing
        guard !receivedAckIDs.contains(ack.ackID) else {
            return
        }
        receivedAckIDs.insert(ack.ackID)
        
        // Find the pending delivery
        guard var delivery = pendingDeliveries[ack.originalMessageID] else {
            // Message might have already been delivered or timed out
            return
        }
        
        // Cancel timeout timer
        delivery.timeoutTimer?.invalidate()
        
        if delivery.isRoomMessage {
            // Track partial delivery for room messages
            delivery.ackedBy.insert(ack.recipientID)
            pendingDeliveries[ack.originalMessageID] = delivery
            
            let deliveredCount = delivery.ackedBy.count
            let totalExpected = delivery.expectedRecipients
            
            if deliveredCount >= totalExpected || deliveredCount >= max(1, totalExpected / 2) {
                // Consider delivered if we got ACKs from at least half the expected recipients
                updateDeliveryStatus(ack.originalMessageID, status: .delivered(to: "\(deliveredCount) members", at: Date()))
                pendingDeliveries.removeValue(forKey: ack.originalMessageID)
            } else {
                // Update partial delivery status
                updateDeliveryStatus(ack.originalMessageID, status: .partiallyDelivered(reached: deliveredCount, total: totalExpected))
            }
        } else {
            // Direct message - mark as delivered
            updateDeliveryStatus(ack.originalMessageID, status: .delivered(to: ack.recipientNickname, at: Date()))
            pendingDeliveries.removeValue(forKey: ack.originalMessageID)
        }
    }
    
    /// Creates a ``DeliveryAck`` for an incoming message if appropriate.
    ///
    /// Returns `nil` if the message is from ourselves, is a broadcast, or has already been ACKed.
    func generateAck(for message: BitchatMessage, myPeerID: String, myNickname: String, hopCount: UInt8) -> DeliveryAck? {
        // Don't ACK our own messages
        guard message.senderPeerID != myPeerID else { return nil }
        
        // Don't ACK broadcasts or system messages
        guard message.isPrivate || message.room != nil else { return nil }
        
        // Don't ACK if we've already sent an ACK for this message
        guard !sentAckIDs.contains(message.id) else { return nil }
        sentAckIDs.insert(message.id)
        
        
        return DeliveryAck(
            originalMessageID: message.id,
            recipientID: myPeerID,
            recipientNickname: myNickname,
            hopCount: hopCount
        )
    }
    
    /// Cancels tracking for a message, invalidating its timeout timer and removing it from the pending map.
    func clearDeliveryStatus(for messageID: String) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        
        if let delivery = pendingDeliveries[messageID] {
            delivery.timeoutTimer?.invalidate()
        }
        pendingDeliveries.removeValue(forKey: messageID)
    }
    
    // MARK: - Private Methods
    
    private func updateDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.deliveryStatusUpdated.send((messageID: messageID, status: status))
        }
    }
    
    private func scheduleTimeout(for messageID: String) {
        // Get delivery info with lock
        pendingLock.lock()
        guard let delivery = pendingDeliveries[messageID] else {
            pendingLock.unlock()
            return
        }
        let isFavorite = delivery.isFavorite
        let isRoomMessage = delivery.isRoomMessage
        pendingLock.unlock()
        
        let timeout = isFavorite ? favoriteTimeout :
                     (isRoomMessage ? roomMessageTimeout : privateMessageTimeout)
        
        let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
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
        
        let shouldRetry = delivery.shouldRetry
        let isRoomMessage = delivery.isRoomMessage
        
        if shouldRetry {
            pendingLock.unlock()
            // Retry for favorites (outside of lock)
            retryDelivery(messageID: messageID)
        } else {
            // Mark as failed
            let reason = isRoomMessage ? "No response from room members" : "Message not delivered"
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
        
        // Increment retry count
        let newDelivery = PendingDelivery(
            messageID: delivery.messageID,
            sentAt: delivery.sentAt,
            recipientID: delivery.recipientID,
            recipientNickname: delivery.recipientNickname,
            retryCount: delivery.retryCount + 1,
            isRoomMessage: delivery.isRoomMessage,
            isFavorite: delivery.isFavorite,
            ackedBy: delivery.ackedBy,
            expectedRecipients: delivery.expectedRecipients,
            timeoutTimer: nil
        )
        
        pendingDeliveries[messageID] = newDelivery
        let retryCount = delivery.retryCount
        pendingLock.unlock()
        
        // Exponential backoff for retry
        let delay = retryDelay * pow(2, Double(retryCount))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Trigger resend through delegate or notification
            NotificationCenter.default.post(
                name: Notification.Name("bitchat.retryMessage"),
                object: nil,
                userInfo: ["messageID": messageID]
            )
            
            // Schedule new timeout
            self?.scheduleTimeout(for: messageID)
        }
    }
    
    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupOldDeliveries()
        }
    }
    
    private func cleanupOldDeliveries() {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        
        let now = Date()
        let maxAge: TimeInterval = 3600  // 1 hour
        
        // Clean up old pending deliveries
        pendingDeliveries = pendingDeliveries.filter { (_, delivery) in
            now.timeIntervalSince(delivery.sentAt) < maxAge
        }
        
        // Clean up old ACK IDs (keep last 1000)
        if receivedAckIDs.count > 1000 {
            receivedAckIDs.removeAll()
        }
        if sentAckIDs.count > 1000 {
            sentAckIDs.removeAll()
        }
    }
}