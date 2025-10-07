//
// ActionMessageProcessor.swift
// bitchat
//
// Processes action messages (hugs, slaps) into system messages
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Service that processes action messages into system messages
/// Converts formatted action messages (* hug/slap *) into system format
final class ActionMessageProcessor {

    // MARK: - Public API

    /// Process an action message, converting it to system format if applicable
    /// - Parameter message: The message to process
    /// - Returns: Processed message (system format if action, unchanged otherwise)
    static func process(_ message: BitchatMessage) -> BitchatMessage {
        let isActionMessage = message.content.hasPrefix("* ") && message.content.hasSuffix(" *") &&
                              (message.content.contains("🫂") || message.content.contains("🐟") ||
                               message.content.contains("took a screenshot"))

        if isActionMessage {
            return BitchatMessage(
                id: message.id,
                sender: "system",
                content: String(message.content.dropFirst(2).dropLast(2)), // Remove * * wrapper
                timestamp: message.timestamp,
                isRelay: message.isRelay,
                originalSender: message.originalSender,
                isPrivate: message.isPrivate,
                recipientNickname: message.recipientNickname,
                senderPeerID: message.senderPeerID,
                mentions: message.mentions,
                deliveryStatus: message.deliveryStatus
            )
        }
        return message
    }

    /// Check if a message is an action message
    static func isActionMessage(_ message: BitchatMessage) -> Bool {
        return message.content.hasPrefix("* ") && message.content.hasSuffix(" *") &&
               (message.content.contains("🫂") || message.content.contains("🐟") ||
                message.content.contains("took a screenshot"))
    }
}
