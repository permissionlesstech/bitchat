//
// PersistentPrivateChatManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SwiftUI

/// Manages persistent private chats tied to fingerprints
/// Ensures chat rooms persist even when peers go offline or change peerIDs
class PersistentPrivateChatManager: ObservableObject {
    @Published var persistentChats: [String: PersistentPrivateChat] = [:] // fingerprint -> chat
    @Published var selectedChatFingerprint: String? = nil
    
    private let userDefaults = UserDefaults.standard
    private let persistentChatsKey = "bitchat.persistentPrivateChats"
    private let selectedChatKey = "bitchat.selectedPrivateChat"
    
    // Dependencies
    weak var meshService: Transport?
    weak var messageRouter: MessageRouter?
    
    // Tracking
    private var onlinePeers: [String: String] = [:] // peerID -> fingerprint
    private var peerFingerprints: [String: String] = [:] // fingerprint -> current peerID
    
    init(meshService: Transport? = nil) {
        self.meshService = meshService
        loadPersistentChats()
        loadSelectedChat()
    }
    
    // MARK: - Persistence
    
    /// Load persistent chats from storage
    private func loadPersistentChats() {
        guard let data = userDefaults.data(forKey: persistentChatsKey) else {
            print("📱 No persistent chats found in storage")
            return
        }
        
        do {
            let chats = try JSONDecoder().decode([String: PersistentPrivateChat].self, from: data)
            DispatchQueue.main.async { [weak self] in
                self?.persistentChats = chats
            }
            print("📱 Loaded \(chats.count) persistent private chats")
            
            // Debug logging
            for (_, chat) in chats {
                print("📱 Chat with \(chat.peerNickname): \(chat.messages.count) messages, \(chat.pendingMessages.count) pending")
            }
        } catch {
            print("❌ Failed to load persistent chats: \(error)")
        }
    }
    
    /// Save persistent chats to storage
    private func savePersistentChats() {
        do {
            let data = try JSONEncoder().encode(persistentChats)
            userDefaults.set(data, forKey: persistentChatsKey)
            userDefaults.synchronize()
            print("💾 Saved \(persistentChats.count) persistent private chats")
        } catch {
            print("❌ Failed to save persistent chats: \(error)")
        }
    }
    
    /// Load selected chat from storage
    private func loadSelectedChat() {
        selectedChatFingerprint = userDefaults.string(forKey: selectedChatKey)
    }
    
    /// Save selected chat to storage
    private func saveSelectedChat() {
        if let fingerprint = selectedChatFingerprint {
            userDefaults.set(fingerprint, forKey: selectedChatKey)
        } else {
            userDefaults.removeObject(forKey: selectedChatKey)
        }
        userDefaults.synchronize()
    }
    
    // MARK: - Chat Management
    
    /// Get or create a persistent chat for a peer fingerprint
    func getOrCreateChat(fingerprint: String, peerNickname: String, peerID: String? = nil) -> PersistentPrivateChat {
        if var existingChat = persistentChats[fingerprint] {
            // Update existing chat
            existingChat.updateNickname(peerNickname)
            if let peerID = peerID {
                existingChat.peerCameOnline(peerID: peerID)
                peerFingerprints[fingerprint] = peerID
                onlinePeers[peerID] = fingerprint
            }
            DispatchQueue.main.async { [weak self] in
                self?.persistentChats[fingerprint] = existingChat
            }
            savePersistentChats()
            return existingChat
        } else {
            // Create new chat
            var newChat = PersistentPrivateChat(fingerprint: fingerprint, peerNickname: peerNickname, currentPeerID: peerID)
            if let peerID = peerID {
                newChat.peerCameOnline(peerID: peerID)
                peerFingerprints[fingerprint] = peerID
                onlinePeers[peerID] = fingerprint
            }
            DispatchQueue.main.async { [weak self] in
                self?.persistentChats[fingerprint] = newChat
            }
            savePersistentChats()
            print("✅ Created new persistent chat with \(peerNickname) (\(fingerprint.prefix(8)))")
            return newChat
        }
    }
    
    /// Start a chat with a peer (by fingerprint)
    func startChat(with fingerprint: String) {
        DispatchQueue.main.async { [weak self] in
            self?.selectedChatFingerprint = fingerprint
        }
        saveSelectedChat()
        
        // Mark messages as read
        markChatAsRead(fingerprint: fingerprint)
        
        // Send pending messages if peer is online
        sendPendingMessagesIfOnline(fingerprint: fingerprint)
    }
    
    /// End current chat
    func endChat() {
        DispatchQueue.main.async { [weak self] in
            self?.selectedChatFingerprint = nil
        }
        saveSelectedChat()
    }
    
    /// Add message to a chat
    func addMessage(_ message: BitchatMessage, to fingerprint: String) {
        guard var chat = persistentChats[fingerprint] else { return }
        
        chat.addMessage(message)
        DispatchQueue.main.async { [weak self] in
            self?.persistentChats[fingerprint] = chat
        }
        savePersistentChats()
    }
    
    /// Send message to a peer
    func sendMessage(_ content: String, to fingerprint: String, senderPeerID: String, senderNickname: String) {
        guard var chat = persistentChats[fingerprint] else { return }
        
        let messageID = UUID().uuidString
        let message = BitchatMessage(
            id: messageID,
            sender: senderNickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: chat.peerNickname,
            senderPeerID: senderPeerID,
            mentions: nil,
            deliveryStatus: .sending
        )
        
        if chat.isOnline, let peerID = chat.currentPeerID {
            // Send immediately
            chat.addMessage(message)
            meshService?.sendPrivateMessage(content, to: peerID, recipientNickname: chat.peerNickname, messageID: messageID)
            print("📨 Sent message to online peer \(chat.peerNickname)")
        } else {
            // Queue as pending
            chat.addPendingMessage(message)
            print("📝 Queued message for offline peer \(chat.peerNickname)")
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.persistentChats[fingerprint] = chat
        }
        savePersistentChats()
    }
    
    /// Handle incoming message
    func handleIncomingMessage(_ message: BitchatMessage, from fingerprint: String, peerNickname: String) {
        _ = getOrCreateChat(fingerprint: fingerprint, peerNickname: peerNickname, peerID: message.senderPeerID)
        addMessage(message, to: fingerprint)
        
        // Send read receipt if this chat is selected
        if selectedChatFingerprint == fingerprint {
            sendReadReceipt(for: message, to: fingerprint)
        }
        
        print("📥 Received message from \(peerNickname) in persistent chat")
    }
    
    // MARK: - Peer Status Management
    
    /// Update peer status when they come online
    func peerCameOnline(peerID: String, fingerprint: String, nickname: String) {
        onlinePeers[peerID] = fingerprint
        peerFingerprints[fingerprint] = peerID
        
        if var chat = persistentChats[fingerprint] {
            chat.peerCameOnline(peerID: peerID)
            chat.updateNickname(nickname)
            DispatchQueue.main.async { [weak self] in
                self?.persistentChats[fingerprint] = chat
            }
            savePersistentChats()
            
            // Send pending messages
            sendPendingMessagesIfOnline(fingerprint: fingerprint)
            
            print("🟢 Peer \(nickname) came online (\(fingerprint.prefix(8)))")
        }
    }
    
    /// Update peer status when they go offline
    func peerWentOffline(peerID: String) {
        guard let fingerprint = onlinePeers[peerID] else { return }
        
        onlinePeers.removeValue(forKey: peerID)
        peerFingerprints.removeValue(forKey: fingerprint)
        
        if var chat = persistentChats[fingerprint] {
            chat.peerWentOffline()
            DispatchQueue.main.async { [weak self] in
                self?.persistentChats[fingerprint] = chat
            }
            savePersistentChats()
            
            print("⚫ Peer \(chat.peerNickname) went offline (\(fingerprint.prefix(8)))")
        }
    }
    
    /// Send pending messages if peer is online
    private func sendPendingMessagesIfOnline(fingerprint: String) {
        guard var chat = persistentChats[fingerprint],
              chat.isOnline,
              let peerID = chat.currentPeerID,
              !chat.pendingMessages.isEmpty else { return }
        
        let messagesToSend = chat.promotePendingMessages()
        DispatchQueue.main.async { [weak self] in
            self?.persistentChats[fingerprint] = chat
        }
        savePersistentChats()
        
        // Send each pending message
        for message in messagesToSend {
            meshService?.sendPrivateMessage(
                message.content,
                to: peerID,
                recipientNickname: chat.peerNickname,
                messageID: message.id
            )
        }
        
        print("📤 Sent \(messagesToSend.count) pending messages to \(chat.peerNickname)")
    }
    
    // MARK: - Utility Methods
    
    /// Mark chat as read
    func markChatAsRead(fingerprint: String) {
        guard var chat = persistentChats[fingerprint] else { return }
        chat.markAsRead()
        DispatchQueue.main.async { [weak self] in
            self?.persistentChats[fingerprint] = chat
        }
        savePersistentChats()
    }
    
    /// Get chat for fingerprint
    func getChat(fingerprint: String) -> PersistentPrivateChat? {
        return persistentChats[fingerprint]
    }
    
    /// Get all chats sorted by last activity
    func getAllChats() -> [PersistentPrivateChat] {
        return persistentChats.values.sorted { $0.lastSeen > $1.lastSeen }
    }
    
    /// Get fingerprint for current peerID
    func getFingerprint(for peerID: String) -> String? {
        return onlinePeers[peerID]
    }
    
    /// Get current peerID for fingerprint
    func getCurrentPeerID(for fingerprint: String) -> String? {
        return peerFingerprints[fingerprint]
    }
    
    /// Delete a chat permanently
    func deleteChat(fingerprint: String) {
        DispatchQueue.main.async { [weak self] in
            self?.persistentChats.removeValue(forKey: fingerprint)
            
            // Clear selection if this chat was selected
            if self?.selectedChatFingerprint == fingerprint {
                self?.selectedChatFingerprint = nil
                self?.saveSelectedChat()
            }
        }
        
        savePersistentChats()
        print("🗑️ Deleted persistent chat (\(fingerprint.prefix(8)))")
    }
    
    /// Clear all chats (for panic mode)
    func clearAllChats() {
        DispatchQueue.main.async { [weak self] in
            self?.persistentChats.removeAll()
            self?.selectedChatFingerprint = nil
            self?.onlinePeers.removeAll()
            self?.peerFingerprints.removeAll()
        }
        
        userDefaults.removeObject(forKey: persistentChatsKey)
        userDefaults.removeObject(forKey: selectedChatKey)
        userDefaults.synchronize()
        
        print("🧹 Cleared all persistent chats")
    }
    
    // MARK: - Read Receipts
    
    private func sendReadReceipt(for message: BitchatMessage, to fingerprint: String) {
        guard let chat = persistentChats[fingerprint],
              chat.isOnline,
              let _ = chat.currentPeerID,
              let senderPeerID = message.senderPeerID else { return }
        
        let receipt = ReadReceipt(
            originalMessageID: message.id,
            readerID: meshService?.myPeerID ?? "",
            readerNickname: meshService?.myNickname ?? ""
        )
        
        if let router = messageRouter {
            Task { @MainActor in
                router.sendReadReceipt(receipt, to: senderPeerID)
            }
        } else {
            meshService?.sendReadReceipt(receipt, to: senderPeerID)
        }
    }
}
