//
// SystemMessagingService.swift
// bitchat
//
// Service for creating and managing system messages
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation

/// Service that creates and routes system messages to appropriate channels
final class SystemMessagingService {

    // MARK: - Message Creation

    /// Create a basic system message
    func createSystemMessage(content: String, timestamp: Date = Date()) -> BitchatMessage {
        return BitchatMessage(
            sender: "system",
            content: content,
            timestamp: timestamp,
            isRelay: false
        )
    }

    /// Create a system message with custom properties
    func createSystemMessage(
        content: String,
        timestamp: Date = Date(),
        isRelay: Bool = false,
        originalSender: String? = nil
    ) -> BitchatMessage {
        return BitchatMessage(
            sender: "system",
            content: content,
            timestamp: timestamp,
            isRelay: isRelay,
            originalSender: originalSender
        )
    }
}
