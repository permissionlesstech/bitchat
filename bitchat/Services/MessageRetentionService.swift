//
// MessageRetentionService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CryptoKit
import Foundation

// MARK: - StoredMessage

struct StoredMessage: Codable, Sendable {
    let id: String
    let sender: String
    let senderPeerID: String?
    let content: String
    let timestamp: Date
    let channelTag: String?
    let isPrivate: Bool
    let recipientPeerID: String?
}

// MARK: - MessageRetentionService

/// A singleton service responsible for securely storing, loading, and cleaning up retained messages
/// for a limited number of days. Only favorite channels are retained.
final class MessageRetentionService: @unchecked Sendable {
    // MARK: Lifecycle

    // MARK: - Initialization

    private init() {
        guard
            let docsDir = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        else {
            fatalError("Unable to access documents directory")
        }

        documentsDirectory = docsDir
        messagesDirectory = docsDir.appendingPathComponent(
            "Messages",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: messagesDirectory,
            withIntermediateDirectories: true
        )

        if let keyData = KeychainManager.shared.getIdentityKey(
            forKey: "messageRetentionKey"
        ) {
            encryptionKey = SymmetricKey(data: keyData)
        } else {
            encryptionKey = SymmetricKey(size: .bits256)
            _ = KeychainManager.shared.saveIdentityKey(
                encryptionKey.withUnsafeBytes { Data($0) },
                forKey: "messageRetentionKey"
            )
        }

        cleanupOldMessages()
    }

    // MARK: Internal

    // MARK: - Singleton

    /// Shared instance of the service
    static let shared = MessageRetentionService()

    // MARK: - Public API

    /// Retrieves the set of favorited channel identifiers.
    func getFavoriteChannels() -> Set<String> {
        favoritesQueue.sync {
            let channels =
                UserDefaults.standard.stringArray(forKey: favoriteChannelsKey)
                ?? []
            return Set(channels)
        }
    }

    /// Toggles a channel's favorite status.
    /// If removing from favorites, messages are deleted for that channel.
    /// - Returns: Whether the channel is now favorited (`true`) or removed (`false`).
    func toggleFavoriteChannel(_ channel: String) -> Bool {
        var result = false
        favoritesQueue.sync(flags: .barrier) {
            var favorites = getFavoriteChannels()
            if favorites.contains(channel) {
                favorites.remove(channel)
                deleteMessagesForChannel(channel)
            } else {
                favorites.insert(channel)
            }
            UserDefaults.standard.set(
                Array(favorites),
                forKey: favoriteChannelsKey
            )
            result = favorites.contains(channel)
        }
        return result
    }

    /// Saves a message to disk if the channel is favorited.
    func saveMessage(_ message: BitchatMessage, forChannel channel: String?) {
        guard let channel = channel ?? message.channel,
            getFavoriteChannels().contains(channel)
        else {
            return
        }

        let storedMessage = StoredMessage(
            id: message.id,
            sender: message.sender,
            senderPeerID: message.senderPeerID,
            content: message.content,
            timestamp: message.timestamp,
            channelTag: message.channel,
            isPrivate: message.isPrivate,
            recipientPeerID: message.senderPeerID
        )

        guard let messageData = try? JSONEncoder().encode(storedMessage),
            let encryptedData = encrypt(messageData)
        else {
            return
        }

        let fileName =
            "\(channel)_\(message.timestamp.timeIntervalSince1970)_\(message.id).enc"
        let fileURL = messagesDirectory.appendingPathComponent(fileName)

        try? encryptedData.write(to: fileURL)
    }

    /// Loads all retained messages for a given channel, sorted by timestamp.
    func loadMessagesForChannel(_ channel: String) -> [BitchatMessage] {
        guard getFavoriteChannels().contains(channel) else {
            return []
        }

        var messages: [BitchatMessage] = []

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: messagesDirectory,
                includingPropertiesForKeys: nil
            )
            let channelFiles = files.filter {
                $0.lastPathComponent.hasPrefix("\(channel)_")
            }

            for fileURL in channelFiles {
                if let encryptedData = try? Data(contentsOf: fileURL),
                    let decryptedData = decrypt(encryptedData),
                    let storedMessage = try? JSONDecoder().decode(
                        StoredMessage.self,
                        from: decryptedData
                    )
                {
                    let message = BitchatMessage(
                        sender: storedMessage.sender,
                        content: storedMessage.content,
                        timestamp: storedMessage.timestamp,
                        isRelay: false,
                        originalSender: nil,
                        isPrivate: storedMessage.isPrivate,
                        recipientNickname: nil,
                        senderPeerID: storedMessage.senderPeerID,
                        mentions: nil,
                        channel: storedMessage.channelTag
                    )
                    messages.append(message)
                }
            }
        } catch {}

        return messages.sorted { $0.timestamp < $1.timestamp }
    }

    /// Deletes all stored messages for a given channel.
    func deleteMessagesForChannel(_ channel: String) {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: messagesDirectory,
                includingPropertiesForKeys: nil
            )
            let channelFiles = files.filter {
                $0.lastPathComponent.hasPrefix("\(channel)_")
            }
            for fileURL in channelFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {}
    }

    /// Deletes all stored messages and clears favorite channel list.
    func deleteAllStoredMessages() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: messagesDirectory,
                includingPropertiesForKeys: nil
            )
            for fileURL in files {
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {}
        UserDefaults.standard.removeObject(forKey: favoriteChannelsKey)
    }

    // MARK: Private

    // MARK: - Private Properties

    private let documentsDirectory: URL
    private let messagesDirectory: URL
    private let favoriteChannelsKey = "bitchat.favoriteChannels"
    private let retentionDays = 7
    private let encryptionKey: SymmetricKey
    private let favoritesQueue = DispatchQueue(
        label: "com.bitchat.MessageRetentionService.favoritesQueue",
        attributes: .concurrent
    )

    // MARK: - Internal Helpers

    /// Encrypts data using AES-GCM and the stored encryption key.
    private func encrypt(_ data: Data) -> Data? {
        try? AES.GCM.seal(data, using: encryptionKey).combined
    }

    /// Decrypts data previously encrypted with AES-GCM.
    private func decrypt(_ data: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data) else {
            return nil
        }
        return try? AES.GCM.open(box, using: encryptionKey)
    }

    /// Removes messages older than the retention period.
    private func cleanupOldMessages() {
        let cutoffDate = Date().addingTimeInterval(
            -TimeInterval(retentionDays * 24 * 60 * 60)
        )
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: messagesDirectory,
                includingPropertiesForKeys: [.creationDateKey]
            )
            for fileURL in files {
                if let date = try? fileURL.resourceValues(forKeys: [
                    .creationDateKey
                ]).creationDate,
                    date < cutoffDate
                {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        } catch {}
    }
}
