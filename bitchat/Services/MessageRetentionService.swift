//
// MessageRetentionService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

struct StoredMessage: Codable {
    let id: String
    let sender: String
    let senderPeerID: String?
    let content: String
    let timestamp: Date
    let channelTag: String?
    let isPrivate: Bool
    let recipientPeerID: String?
}

class MessageRetentionService {
    static let shared = MessageRetentionService()
    
    private let documentsDirectory: URL
    private let messagesDirectory: URL
    private let favoriteChannelsKey = "bitchat.favoriteChannels"
    private let retentionDays = 7 // Messages retained for 7 days
    private let encryptionKey: SymmetricKey
    
    private init() {
        // Get documents directory with fallback to temp directory
        if let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            documentsDirectory = docsDir
        } else {
            // Fallback to temporary directory if documents directory is not accessible
            documentsDirectory = FileManager.default.temporaryDirectory
            SecurityLogger.log("Using temporary directory for message retention", 
                             category: SecurityLogger.security, level: .warning)
        }
        messagesDirectory = documentsDirectory.appendingPathComponent("Messages", isDirectory: true)
        
        // Create messages directory if it doesn't exist
        try? FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        
        // Generate or retrieve encryption key from keychain
        let loadedKey: SymmetricKey
        
        // Try to load from keychain
        if let keyData = KeychainManager.shared.getIdentityKey(forKey: "messageRetentionKey") {
            loadedKey = SymmetricKey(data: keyData)
        }
        // Generate new key if needed
        else {
            loadedKey = SymmetricKey(size: .bits256)
            let keyData = loadedKey.withUnsafeBytes { Data($0) }
            // Save to keychain
            _ = KeychainManager.shared.saveIdentityKey(keyData, forKey: "messageRetentionKey")
        }
        
        // Now assign the final value
        self.encryptionKey = loadedKey
        
        // Clean up old messages on init
        cleanupOldMessages()
    }
    
    // MARK: - Favorite Channels Management
    
    func getFavoriteChannels() -> Set<String> {
        let channels = UserDefaults.standard.stringArray(forKey: favoriteChannelsKey) ?? []
        return Set(channels)
    }
    
    func toggleFavoriteChannel(_ channel: String) -> Bool {
        var favorites = getFavoriteChannels()
        if favorites.contains(channel) {
            favorites.remove(channel)
            // Clean up messages for this channel
            deleteMessagesForChannel(channel)
        } else {
            favorites.insert(channel)
        }
        UserDefaults.standard.set(Array(favorites), forKey: favoriteChannelsKey)
        return favorites.contains(channel)
    }
    
    // MARK: - Message Storage
    
    func saveMessage(_ message: BitchatMessage, forChannel channel: String?) {
        // Only save messages for favorite channels
        guard let channel = channel ?? message.channel,
              getFavoriteChannels().contains(channel) else {
            return
        }
        
        // Convert to StoredMessage
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
        
        // Encode message
        guard let messageData = try? JSONEncoder().encode(storedMessage) else { return }
        
        // Encrypt message
        guard let encryptedData = encrypt(messageData) else { return }
        
        // Save to file
        let fileName = "\(channel)_\(message.timestamp.timeIntervalSince1970)_\(message.id).enc"
        let fileURL = messagesDirectory.appendingPathComponent(fileName)
        
        try? encryptedData.write(to: fileURL)
    }
    
    func loadMessagesForChannel(_ channel: String) -> [BitchatMessage] {
        guard getFavoriteChannels().contains(channel) else { return [] }
        
        var messages: [BitchatMessage] = []
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: nil)
            let channelFiles = files.filter { $0.lastPathComponent.hasPrefix("\(channel)_") }
            
            for fileURL in channelFiles {
                if let encryptedData = try? Data(contentsOf: fileURL),
                   let decryptedData = decrypt(encryptedData),
                   let storedMessage = try? JSONDecoder().decode(StoredMessage.self, from: decryptedData) {
                    
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
        } catch {
        }
        
        return messages.sorted { $0.timestamp < $1.timestamp }
    }
    
    // MARK: - Encryption
    
    private func encrypt(_ data: Data) -> Data? {
        do {
            let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
            return sealedBox.combined
        } catch {
            return nil
        }
    }
    
    private func decrypt(_ data: Data) -> Data? {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: encryptionKey)
        } catch {
            return nil
        }
    }
    
    // MARK: - Cleanup
    
    private func cleanupOldMessages() {
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60))
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: [.creationDateKey])
            
            for fileURL in files {
                if let attributes = try? fileURL.resourceValues(forKeys: [.creationDateKey]),
                   let creationDate = attributes.creationDate,
                   creationDate < cutoffDate {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        } catch {
        }
    }
    
    func deleteMessagesForChannel(_ channel: String) {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: nil)
            let channelFiles = files.filter { $0.lastPathComponent.hasPrefix("\(channel)_") }
            
            for fileURL in channelFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
        }
    }
    
    func deleteAllStoredMessages() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: nil)
            for fileURL in files {
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
        }
        
        // Clear favorite channels
        UserDefaults.standard.removeObject(forKey: favoriteChannelsKey)
    }
}
