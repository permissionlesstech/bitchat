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
    private let privateMessageTimeout: TimeInterval = 120  // 2 minutes
    private let roomMessageTimeout: TimeInterval = 180     // 3 minutes
    private let favoriteTimeout: TimeInterval = 600       // 10 minutes for favorites
    
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
        let isFavorite: Bool
        var timeoutTimer: Timer?
        
        var isTimedOut: Bool {
            let timeout: TimeInterval = isFavorite ? 300 : 30
            return Date().timeIntervalSince(sentAt) > timeout
        }
        
        var shouldRetry: Bool {
            return retryCount < 3 && isFavorite
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
        // Only track private messages
        guard message.isPrivate else { return }
        
        SecureLogger.log("Tracking message \(message.id) - private: \(message.isPrivate), recipient: \(recipientNickname)", category: SecureLogger.session, level: .info)
        
        
        let delivery = PendingDelivery(
            messageID: message.id,
            sentAt: Date(),
            recipientID: recipientID,
            recipientNickname: recipientNickname,
            retryCount: 0,
            isFavorite: isFavorite,
            timeoutTimer: nil
        )
        
        // Store the delivery with lock
        pendingLock.lock()
        pendingDeliveries[message.id] = delivery
        pendingLock.unlock()
        
        // Update status to sent (only if not already delivered)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            
            self.pendingLock.lock()
            let stillPending = self.pendingDeliveries[message.id] != nil
            self.pendingLock.unlock()
            
            // Only update to sent if still pending (not already delivered)
            if stillPending {
                SecureLogger.log("Updating message \(message.id) to sent status (still pending)", category: SecureLogger.session, level: .debug)
                self.updateDeliveryStatus(message.id, status: .sent)
            } else {
                SecureLogger.log("Skipping sent status update for \(message.id) - already delivered", category: SecureLogger.session, level: .debug)
            }
        }
        
        // Schedule timeout (outside of lock)
        scheduleTimeout(for: message.id)
    }
    
    func processDeliveryAck(_ ack: DeliveryAck) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        
        SecureLogger.log("Processing delivery ACK for message \(ack.originalMessageID) from \(ack.recipientNickname)", category: SecureLogger.session, level: .info)
        
        // Prevent duplicate ACK processing
        guard !receivedAckIDs.contains(ack.ackID) else {
            SecureLogger.log("Duplicate ACK \(ack.ackID) - ignoring", category: SecureLogger.session, level: .warning)
            return
        }
        receivedAckIDs.insert(ack.ackID)
        
        // Find the pending delivery
        guard let delivery = pendingDeliveries[ack.originalMessageID] else {
            // Message might have already been delivered or timed out
            SecureLogger.log("No pending delivery found for message \(ack.originalMessageID)", category: SecureLogger.session, level: .warning)
            return
        }
        
        // Cancel timeout timer
        delivery.timeoutTimer?.invalidate()
        
        // Direct message - mark as delivered
        SecureLogger.log("Marking private message \(ack.originalMessageID) as delivered to \(ack.recipientNickname)", category: SecureLogger.session, level: .info)
        updateDeliveryStatus(ack.originalMessageID, status: .delivered(to: ack.recipientNickname, at: Date()))
        pendingDeliveries.removeValue(forKey: ack.originalMessageID)
    }
    
    func generateAck(for message: BitchatMessage, myPeerID: String, myNickname: String, hopCount: UInt8) -> DeliveryAck? {
        // Don't ACK our own messages
        guard message.senderPeerID != myPeerID else { 
            return nil 
        }
        
        // Only ACK private messages
        guard message.isPrivate else { 
            return nil 
        }
        
        // Don't ACK if we've already sent an ACK for this message
        guard !sentAckIDs.contains(message.id) else { 
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
        SecureLogger.log("Updating delivery status for message \(messageID): \(status)", category: SecureLogger.session, level: .debug)
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
        pendingLock.unlock()
        
        let timeout = isFavorite ? favoriteTimeout : privateMessageTimeout
        
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
        
        if shouldRetry {
            pendingLock.unlock()
            // Retry for favorites (outside of lock)
            retryDelivery(messageID: messageID)
        } else {
            // Mark as failed
            let reason = "Message not delivered"
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
            isFavorite: delivery.isFavorite,
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