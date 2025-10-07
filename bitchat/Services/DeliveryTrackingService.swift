//
// DeliveryTrackingService.swift
// bitchat
//
// Service for tracking message delivery and read status
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation

/// Service that manages delivery status updates for messages
/// Prevents status downgrades (e.g., read → delivered) and maintains consistency
final class DeliveryTrackingService {

    // MARK: - Public API

    /// Update delivery status for a message, preventing downgrades
    /// - Parameters:
    ///   - messageID: The message ID to update
    ///   - status: The new delivery status
    ///   - messages: Array of public messages (inout for mutation)
    ///   - privateChats: Dictionary of private chats (inout for mutation)
    ///   - notifyChange: Closure to trigger UI update
    func updateStatus(
        messageID: String,
        status: DeliveryStatus,
        messages: inout [BitchatMessage],
        privateChats: inout [String: [BitchatMessage]],
        notifyChange: @escaping () -> Void
    ) {
        // Update in main messages
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            let currentStatus = messages[index].deliveryStatus
            if !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) {
                messages[index].deliveryStatus = status
            }
        }

        // Update in private chats
        for (peerID, chatMessages) in privateChats {
            guard let index = chatMessages.firstIndex(where: { $0.id == messageID }) else { continue }

            let currentStatus = chatMessages[index].deliveryStatus
            guard !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) else { continue }

            // Update delivery status
            privateChats[peerID]?[index].deliveryStatus = status
        }

        // Trigger UI update
        DispatchQueue.main.async {
            notifyChange()
        }
    }

    // MARK: - Private Helpers

    /// Check if we should skip a status update to prevent downgrades
    private func shouldSkipUpdate(currentStatus: DeliveryStatus?, newStatus: DeliveryStatus) -> Bool {
        guard let current = currentStatus else { return false }

        // Don't downgrade from read to delivered or sent
        switch (current, newStatus) {
        case (.read, .delivered):
            return true
        case (.read, .sent):
            return true
        default:
            return false
        }
    }
}
