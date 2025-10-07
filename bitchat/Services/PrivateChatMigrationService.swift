//
// PrivateChatMigrationService.swift
// bitchat
//
// Service for migrating private chats when peers reconnect with new IDs
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation

/// Service that handles private chat migration when peers reconnect with different peer IDs
/// Uses fingerprint matching or nickname matching to identify the same person
final class PrivateChatMigrationService {

    // MARK: - Public API

    /// Migrate private chats when a peer reconnects with a new ID
    /// - Parameters:
    ///   - newPeerID: The new peer ID
    ///   - senderNickname: The nickname of the sender
    ///   - currentNickname: The current user's nickname
    ///   - currentFingerprint: The fingerprint for the new peer ID
    ///   - privateChats: Dictionary of private chats (inout)
    ///   - unreadMessages: Set of unread message peer IDs (inout)
    ///   - peerIDToFingerprintMapping: Mapping of peer IDs to fingerprints
    ///   - selectedPrivateChatPeer: Currently selected peer ID (inout)
    ///   - updatePrivateChatPeer: Closure to update selected peer if needed
    static func migrateIfNeeded(
        newPeerID: String,
        senderNickname: String,
        currentNickname: String,
        currentFingerprint: String?,
        privateChats: inout [String: [BitchatMessage]],
        unreadMessages: inout Set<String>,
        peerIDToFingerprintMapping: [String: String],
        selectedPrivateChatPeer: inout String?,
        updatePrivateChatPeer: @escaping (String) -> Void
    ) {
        // Only migrate if new peer has no existing chat or empty chat
        guard privateChats[newPeerID] == nil || privateChats[newPeerID]?.isEmpty == true else { return }

        var migratedMessages: [BitchatMessage] = []
        var oldPeerIDsToRemove: [String] = []

        // Only migrate messages from the last 24 hours to prevent old messages from flooding
        let cutoffTime = Date().addingTimeInterval(-TransportConfig.uiMigrationCutoffSeconds)

        for (oldPeerID, messages) in privateChats {
            guard oldPeerID != newPeerID else { continue }

            let oldFingerprint = peerIDToFingerprintMapping[oldPeerID]

            // Filter messages to only recent ones
            let recentMessages = messages.filter { $0.timestamp > cutoffTime }

            // Skip if no recent messages
            guard !recentMessages.isEmpty else { continue }

            // Check fingerprint match first (most reliable)
            if let currentFp = currentFingerprint,
               let oldFp = oldFingerprint,
               currentFp == oldFp {
                migratedMessages.append(contentsOf: recentMessages)

                // Only remove old peer ID if we migrated ALL its messages
                if recentMessages.count == messages.count {
                    oldPeerIDsToRemove.append(oldPeerID)
                } else {
                    SecureLogger.info("📦 Partially migrating \(recentMessages.count) of \(messages.count) messages from \(oldPeerID)", category: .session)
                }

                SecureLogger.info("📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(newPeerID) (fingerprint match)", category: .session)
            } else if currentFingerprint == nil || oldFingerprint == nil {
                // Check if this chat contains messages with this sender by nickname
                let isRelevantChat = recentMessages.contains { msg in
                    (msg.sender == senderNickname && msg.sender != currentNickname) ||
                    (msg.sender == currentNickname && msg.recipientNickname == senderNickname)
                }

                if isRelevantChat {
                    migratedMessages.append(contentsOf: recentMessages)

                    // Only remove if all messages were migrated
                    if recentMessages.count == messages.count {
                        oldPeerIDsToRemove.append(oldPeerID)
                    }

                    SecureLogger.warning("📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(newPeerID) (nickname match)", category: .session)
                }
            }
        }

        // Remove old peer ID entries
        if !oldPeerIDsToRemove.isEmpty {
            // Track if we need to update selectedPrivateChatPeer
            let needsSelectedUpdate = oldPeerIDsToRemove.contains { selectedPrivateChatPeer == $0 }

            // Directly modify privateChats
            for oldPeerID in oldPeerIDsToRemove {
                privateChats.removeValue(forKey: oldPeerID)
                unreadMessages.remove(oldPeerID)
            }

            // Update selected chat peer if needed
            if needsSelectedUpdate {
                selectedPrivateChatPeer = newPeerID
                updatePrivateChatPeer(newPeerID)
            }

            SecureLogger.info("📦 Removed \(oldPeerIDsToRemove.count) old peer ID(s) after migration", category: .session)
        }

        // Add migrated messages to new peer ID
        if !migratedMessages.isEmpty {
            if var existingMessages = privateChats[newPeerID] {
                // Merge with existing messages, replace-by-id semantics
                for msg in migratedMessages {
                    if let i = existingMessages.firstIndex(where: { $0.id == msg.id }) {
                        existingMessages[i] = msg
                    } else {
                        existingMessages.append(msg)
                    }
                }
                existingMessages.sort { $0.timestamp < $1.timestamp }
                privateChats[newPeerID] = existingMessages
            } else {
                // No existing messages, just use migrated ones sorted
                privateChats[newPeerID] = migratedMessages.sorted { $0.timestamp < $1.timestamp }
            }

            SecureLogger.info("📦 Migration complete: \(migratedMessages.count) messages now under peer ID \(newPeerID)", category: .session)
        }
    }
}
