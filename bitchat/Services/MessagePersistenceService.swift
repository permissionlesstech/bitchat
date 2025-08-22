//
//  MessagePersistenceService.swift
//  bitchat
//
//  Created by Waluya Juang Husada on 20/08/25.
//

import Foundation

/// Service responsible for persisting and loading chat messages
/// This allows messages to survive app restarts while maintaining privacy
class MessagePersistenceService {
    static let shared = MessagePersistenceService()
    
    private let userDefaults = UserDefaults.standard
    private let publicMessagesKey = "bitchat.publicMessages"
    private let privateMessagesKey = "bitchat.privateMessages"
    private let maxStoredMessages = 1000 // Limit stored messages to prevent excessive storage use
    
    private init() {}
    
    // MARK: - Public Messages
    
    /// Save public messages to UserDefaults
    func savePublicMessages(_ messages: [BitchatMessage]) {
        // Only save the most recent messages to prevent excessive storage
        let messagesToSave = Array(messages.suffix(maxStoredMessages))
        
        do {
            let data = try JSONEncoder().encode(messagesToSave)
            userDefaults.set(data, forKey: publicMessagesKey)
            userDefaults.synchronize()
        } catch {
            print("Failed to save public messages: \(error)")
        }
    }
    
    /// Load public messages from UserDefaults
    func loadPublicMessages() -> [BitchatMessage] {
        guard let data = userDefaults.data(forKey: publicMessagesKey) else {
            return []
        }
        
        do {
            let messages = try JSONDecoder().decode([BitchatMessage].self, from: data)
            return messages
        } catch {
            print("Failed to load public messages: \(error)")
            return []
        }
    }
    
    // MARK: - Private Messages
    
    /// Save private messages to UserDefaults
    func savePrivateMessages(_ privateChats: [String: [BitchatMessage]]) {
        // Only save the most recent messages for each private chat
        var limitedPrivateChats: [String: [BitchatMessage]] = [:]
        
        for (peerID, messages) in privateChats {
            limitedPrivateChats[peerID] = Array(messages.suffix(maxStoredMessages))
        }
        
        do {
            let data = try JSONEncoder().encode(limitedPrivateChats)
            userDefaults.set(data, forKey: privateMessagesKey)
            userDefaults.synchronize()
        } catch {
            print("Failed to save private messages: \(error)")
        }
    }
    
    /// Load private messages from UserDefaults
    func loadPrivateMessages() -> [String: [BitchatMessage]] {
        guard let data = userDefaults.data(forKey: privateMessagesKey) else {
            return [:]
        }
        
        do {
            let privateChats = try JSONDecoder().decode([String: [BitchatMessage]].self, from: data)
            return privateChats
        } catch {
            print("Failed to load private messages: \(error)")
            return [:]
        }
    }
    
    // MARK: - Utility Methods
    
    /// Clear all persisted messages
    func clearAllMessages() {
        userDefaults.removeObject(forKey: publicMessagesKey)
        userDefaults.removeObject(forKey: privateMessagesKey)
        userDefaults.synchronize()
    }
    
    /// Get the size of stored message data (for debugging)
    func getStoredMessageSize() -> Int {
        let publicData = userDefaults.data(forKey: publicMessagesKey)?.count ?? 0
        let privateData = userDefaults.data(forKey: privateMessagesKey)?.count ?? 0
        return publicData + privateData
    }
}
