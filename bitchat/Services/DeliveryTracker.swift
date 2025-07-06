//
// DeliveryTracker.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine

class DeliveryTracker {
    static let shared = DeliveryTracker()
    
    // Track pending deliveries
    private var pendingDeliveries: [String: PendingDelivery] = [:]
    private let pendingLock = NSLock()
    
    // Track received ACKs to prevent duplicates
    private var receivedAckIDs = Set<String>()
    private var sentAckIDs = Set<String>()
    
    // Timeout configuration
    private let privateMessageTimeout: TimeInterval = 30  // 30 seconds
    private let roomMessageTimeout: TimeInterval = 60     // 1 minute
    private let favoriteTimeout: TimeInterval = 300       // 5 minutes for favorites
    
    // Retry configuration
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 5  // Base retry delay
    
    // Publishers for UI updates
    let deliveryStatusUpdated = PassthroughSubject<(messageID: String, status: DeliveryStatus), Never>()
    
    // Cleanup timer
    private var cleanupTimer: Timer?
    
    struct PendingDelivery {
        let messageID: String
        let sentAt: Date
        let recipientID: String
        let recipientNickname: String
        let retryCount: Int
        let isRoomMessage: Bool
        let isFavorite: Bool
        var ackedBy: Set<String> = []  // For tracking partial room delivery
        let expectedRecipients: Int  // For room messages
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
    
    func trackMessage(_ message: BitchatMessage, recipientID: String, recipientNickname: String, isFavorite: Bool = false, expectedRecipients: Int = 1) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        
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
        
        pendingDeliveries[message.id] = delivery
        
        // Update status to sent
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateDeliveryStatus(message.id, status: .sent)
        }
        
        // Schedule timeout
        scheduleTimeout(for: message.id)
    }
    
    func processDeliveryAck(_ ack: DeliveryAck) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        
        // Prevent duplicate ACK processing
        guard !receivedAckIDs.contains(ack.ackID) else { return }
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
        guard let delivery = pendingDeliveries[messageID] else { return }
        
        let timeout = delivery.isFavorite ? favoriteTimeout :
                     (delivery.isRoomMessage ? roomMessageTimeout : privateMessageTimeout)
        
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
        defer { pendingLock.unlock() }
        
        guard let delivery = pendingDeliveries[messageID] else { return }
        
        if delivery.shouldRetry {
            // Retry for favorites
            retryDelivery(messageID: messageID)
        } else {
            // Mark as failed
            let reason = delivery.isRoomMessage ? "No response from room members" : "Message not delivered"
            updateDeliveryStatus(messageID, status: .failed(reason: reason))
            pendingDeliveries.removeValue(forKey: messageID)
        }
    }
    
    private func retryDelivery(messageID: String) {
        guard let delivery = pendingDeliveries[messageID] else { return }
        
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
        
        // Exponential backoff for retry
        let delay = retryDelay * pow(2, Double(delivery.retryCount))
        
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