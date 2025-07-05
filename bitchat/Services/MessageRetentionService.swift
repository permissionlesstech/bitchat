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
    let roomTag: String?
    let isPrivate: Bool
    let recipientPeerID: String?
}

class MessageRetentionService {
    static let shared = MessageRetentionService()
    
    private let documentsDirectory: URL
    private let messagesDirectory: URL
    private let favoriteRoomsKey = "bitchat.favoriteRooms"
    private let retentionDays = 7 // Messages retained for 7 days
    private let encryptionKey: SymmetricKey
    
    private init() {
        // Get documents directory
        documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        messagesDirectory = documentsDirectory.appendingPathComponent("Messages", isDirectory: true)
        
        // Create messages directory if it doesn't exist
        try? FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        
        // Generate or retrieve encryption key from keychain
        if let keyData = KeychainManager.shared.getIdentityKey(forKey: "messageRetentionKey") {
            encryptionKey = SymmetricKey(data: keyData)
        } else {
            // Generate new key and store it
            encryptionKey = SymmetricKey(size: .bits256)
            _ = KeychainManager.shared.saveIdentityKey(encryptionKey.withUnsafeBytes { Data($0) }, forKey: "messageRetentionKey")
        }
        
        // Clean up old messages on init
        cleanupOldMessages()
    }
    
    // MARK: - Favorite Rooms Management
    
    func getFavoriteRooms() -> Set<String> {
        let rooms = UserDefaults.standard.stringArray(forKey: favoriteRoomsKey) ?? []
        return Set(rooms)
    }
    
    func toggleFavoriteRoom(_ room: String) -> Bool {
        var favorites = getFavoriteRooms()
        if favorites.contains(room) {
            favorites.remove(room)
            // Clean up messages for this room
            deleteMessagesForRoom(room)
        } else {
            favorites.insert(room)
        }
        UserDefaults.standard.set(Array(favorites), forKey: favoriteRoomsKey)
        return favorites.contains(room)
    }
    
    // MARK: - Message Storage
    
    func saveMessage(_ message: BitchatMessage, forRoom room: String?) {
        // Only save messages for favorite rooms
        guard let room = room ?? message.room,
              getFavoriteRooms().contains(room) else {
            return
        }
        
        // Convert to StoredMessage
        let storedMessage = StoredMessage(
            id: message.id,
            sender: message.sender,
            senderPeerID: message.senderPeerID,
            content: message.content,
            timestamp: message.timestamp,
            roomTag: message.room,
            isPrivate: message.isPrivate,
            recipientPeerID: message.senderPeerID
        )
        
        // Encode message
        guard let messageData = try? JSONEncoder().encode(storedMessage) else { return }
        
        // Encrypt message
        guard let encryptedData = encrypt(messageData) else { return }
        
        // Save to file
        let fileName = "\(room)_\(message.timestamp.timeIntervalSince1970)_\(message.id).enc"
        let fileURL = messagesDirectory.appendingPathComponent(fileName)
        
        try? encryptedData.write(to: fileURL)
    }
    
    func loadMessagesForRoom(_ room: String) -> [BitchatMessage] {
        guard getFavoriteRooms().contains(room) else { return [] }
        
        var messages: [BitchatMessage] = []
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: nil)
            let roomFiles = files.filter { $0.lastPathComponent.hasPrefix("\(room)_") }
            
            for fileURL in roomFiles {
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
                        room: storedMessage.roomTag
                    )
                    
                    messages.append(message)
                }
            }
        } catch {
            bitchatLog("Failed to load messages for room \(room): \(error)", category: "retention")
        }
        
        return messages.sorted { $0.timestamp < $1.timestamp }
    }
    
    // MARK: - Encryption
    
    private func encrypt(_ data: Data) -> Data? {
        do {
            let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
            return sealedBox.combined
        } catch {
            bitchatLog("Failed to encrypt message: \(error)", category: "retention")
            return nil
        }
    }
    
    private func decrypt(_ data: Data) -> Data? {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: encryptionKey)
        } catch {
            bitchatLog("Failed to decrypt message: \(error)", category: "retention")
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
            bitchatLog("Failed to cleanup old messages: \(error)", category: "retention")
        }
    }
    
    func deleteMessagesForRoom(_ room: String) {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: nil)
            let roomFiles = files.filter { $0.lastPathComponent.hasPrefix("\(room)_") }
            
            for fileURL in roomFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            bitchatLog("Failed to delete messages for room \(room): \(error)", category: "retention")
        }
    }
    
    func deleteAllStoredMessages() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: nil)
            for fileURL in files {
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            bitchatLog("Failed to delete all stored messages: \(error)", category: "retention")
        }
        
        // Clear favorite rooms
        UserDefaults.standard.removeObject(forKey: favoriteRoomsKey)
    }
}