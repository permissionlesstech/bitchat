//
// ChatViewModel.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SwiftUI
import Combine
import CryptoKit
import CommonCrypto
#if os(iOS)
import UIKit
#endif

class ChatViewModel: ObservableObject {
    @Published var messages: [BitchatMessage] = []
    private let maxMessages = 1337 // Maximum messages before oldest are removed
    @Published var connectedPeers: [String] = []
    
    // Message batching for performance
    private var pendingMessages: [BitchatMessage] = []
    private var pendingPrivateMessages: [String: [BitchatMessage]] = [:] // peerID -> messages
    private var messageBatchTimer: Timer?
    private let messageBatchInterval: TimeInterval = 0.1 // 100ms batching window
    @Published var nickname: String = ""
    @Published var isConnected = false
    @Published var privateChats: [String: [BitchatMessage]] = [:] // peerID -> messages
    @Published var selectedPrivateChatPeer: String? = nil
    private var selectedPrivateChatFingerprint: String? = nil  // Track by fingerprint for persistence across reconnections
    @Published var unreadPrivateMessages: Set<String> = []
    @Published var autocompleteSuggestions: [String] = []
    @Published var showAutocomplete: Bool = false
    @Published var autocompleteRange: NSRange? = nil
    @Published var selectedAutocompleteIndex: Int = 0
    
    // Autocomplete optimization
    private let mentionRegex = try? NSRegularExpression(pattern: "@([a-zA-Z0-9_]*)$", options: [])
    private var cachedNicknames: [String] = []
    private var lastNicknameUpdate: Date = .distantPast
    
    // Temporary property to fix compilation
    @Published var showPasswordPrompt = false
    
    var meshService = BluetoothMeshService()
    private let userDefaults = UserDefaults.standard
    private let nicknameKey = "bitchat.nickname"
    
    // Caches for expensive computations
    private var rssiColorCache: [String: Color] = [:] // key: "\(rssi)_\(isDark)"
    private var encryptionStatusCache: [String: EncryptionStatus] = [:] // key: peerID
    
    @Published var favoritePeers: Set<String> = []  // Now stores public key fingerprints instead of peer IDs
    private var peerIDToPublicKeyFingerprint: [String: String] = [:]  // Maps ephemeral peer IDs to persistent fingerprints
    private var blockedUsers: Set<String> = []  // Stores public key fingerprints of blocked users
    
    // Noise Protocol encryption status
    @Published var peerEncryptionStatus: [String: EncryptionStatus] = [:]  // peerID -> encryption status
    @Published var verifiedFingerprints: Set<String> = []  // Set of verified fingerprints
    @Published var showingFingerprintFor: String? = nil  // Currently showing fingerprint sheet for peer
    
    // Messages are naturally ephemeral - no persistent storage
    
    // Delivery tracking
    private var deliveryTrackerCancellable: AnyCancellable?
    
    // Track sent read receipts to avoid duplicates
    private var sentReadReceipts: Set<String> = []  // messageID set
    
    init() {
        loadNickname()
        loadFavorites()
        loadBlockedUsers()
        loadVerifiedFingerprints()
        meshService.delegate = self
        
        // Log startup info
        
        // Log fingerprint after a delay to ensure encryption service is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if let self = self {
                _ = self.getMyFingerprint()
            }
        }
        
        // Start mesh service immediately
        meshService.startServices()
        
        // Set up message retry service
        MessageRetryService.shared.meshService = meshService
        
        // Set up Noise encryption callbacks
        setupNoiseCallbacks()
        
        // Request notification permission
        NotificationService.shared.requestAuthorization()
        
        // Subscribe to delivery status updates
        deliveryTrackerCancellable = DeliveryTracker.shared.deliveryStatusUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (messageID, status) in
                self?.updateMessageDeliveryStatus(messageID, status: status)
            }
                
        // When app becomes active, send read receipts for visible messages
        #if os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // Add app lifecycle observers to save data
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        #else
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // Add screenshot detection for iOS
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDidTakeScreenshot),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
        
        // Add app lifecycle observers to save data
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        #endif
    }
    
    deinit {
        // Clean up timer
        messageBatchTimer?.invalidate()
        
        // Force immediate save
        userDefaults.synchronize()
    }
    
    private func loadNickname() {
        if let savedNickname = userDefaults.string(forKey: nicknameKey) {
            nickname = savedNickname
        } else {
            nickname = "anon\(Int.random(in: 1000...9999))"
            saveNickname()
        }
    }
    
    func saveNickname() {
        userDefaults.set(nickname, forKey: nicknameKey)
        userDefaults.synchronize() // Force immediate save
        
        // Send announce with new nickname to all peers
        meshService.sendBroadcastAnnounce()
    }
    
    func validateAndSaveNickname() {
        // Check if nickname is empty or just whitespace
        if nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nickname = "anon\(Int.random(in: 1000...9999))"
        }
        saveNickname()
    }
    
    private func loadFavorites() {
        // Load favorites from secure storage
        favoritePeers = SecureIdentityStateManager.shared.getFavorites()
    }
    
    private func saveFavorites() {
        // Favorites are now saved automatically in SecureIdentityStateManager
        // This method is kept for compatibility
    }
    
    private func loadBlockedUsers() {
        // Load blocked users from secure storage
        let allIdentities = SecureIdentityStateManager.shared.getAllSocialIdentities()
        blockedUsers = Set(allIdentities.filter { $0.isBlocked }.map { $0.fingerprint })
    }
    
    private func saveBlockedUsers() {
        // Blocked users are now saved automatically in SecureIdentityStateManager
        // This method is kept for compatibility
    }
    
    
    func toggleFavorite(peerID: String) {
        // First try to get fingerprint from mesh service (supports peer ID rotation)
        var fingerprint: String? = meshService.getFingerprint(for: peerID)
        
        // Fallback to local mapping if not found in mesh service
        if fingerprint == nil {
            fingerprint = peerIDToPublicKeyFingerprint[peerID]
        }
        
        guard let fp = fingerprint else {
            return
        }
        
        let isFavorite = SecureIdentityStateManager.shared.isFavorite(fingerprint: fp)
        SecureIdentityStateManager.shared.setFavorite(fp, isFavorite: !isFavorite)
        
        // Update local set for UI
        if isFavorite {
            favoritePeers.remove(fp)
        } else {
            favoritePeers.insert(fp)
        }
    }
    
    func isFavorite(peerID: String) -> Bool {
        // First try to get fingerprint from mesh service (supports peer ID rotation)
        var fingerprint: String? = meshService.getFingerprint(for: peerID)
        
        // Fallback to local mapping if not found in mesh service
        if fingerprint == nil {
            fingerprint = peerIDToPublicKeyFingerprint[peerID]
        }
        
        guard let fp = fingerprint else {
            return false
        }
        
        return SecureIdentityStateManager.shared.isFavorite(fingerprint: fp)
    }
    
    // Called when we receive a peer's public key
    func registerPeerPublicKey(peerID: String, publicKeyData: Data) {
        // Create a fingerprint from the public key (full SHA256, not truncated)
        let fingerprintStr = SHA256.hash(data: publicKeyData)
            .compactMap { String(format: "%02x", $0) }
            .joined()
        
        // Only register if not already registered
        if peerIDToPublicKeyFingerprint[peerID] != fingerprintStr {
            peerIDToPublicKeyFingerprint[peerID] = fingerprintStr
        }
        
        // Update identity state manager with handshake completion
        SecureIdentityStateManager.shared.updateHandshakeState(peerID: peerID, state: .completed(fingerprint: fingerprintStr))
        
        // Update encryption status now that we have the fingerprint
        updateEncryptionStatus(for: peerID)
        
        // Check if we have a claimed nickname for this peer
        let peerNicknames = meshService.getPeerNicknames()
        if let nickname = peerNicknames[peerID], nickname != "Unknown" && nickname != "anon\(peerID.prefix(4))" {
            // Update or create social identity with the claimed nickname
            if var identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprintStr) {
                identity.claimedNickname = nickname
                SecureIdentityStateManager.shared.updateSocialIdentity(identity)
            } else {
                let newIdentity = SocialIdentity(
                    fingerprint: fingerprintStr,
                    localPetname: nil,
                    claimedNickname: nickname,
                    trustLevel: .casual,
                    isFavorite: false,
                    isBlocked: false,
                    notes: nil
                )
                SecureIdentityStateManager.shared.updateSocialIdentity(newIdentity)
            }
        }
        
        // Check if this peer is the one we're in a private chat with
        updatePrivateChatPeerIfNeeded()
    }
    
    private func isPeerBlocked(_ peerID: String) -> Bool {
        // Check if we have the public key fingerprint for this peer
        if let fingerprint = peerIDToPublicKeyFingerprint[peerID] {
            return SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprint)
        }
        
        // Try to get fingerprint from mesh service
        if let fingerprint = meshService.getPeerFingerprint(peerID) {
            return SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprint)
        }
        
        return false
    }
    
    // Helper method to find current peer ID for a fingerprint
    private func getCurrentPeerIDForFingerprint(_ fingerprint: String) -> String? {
        // Search through all connected peers to find the one with matching fingerprint
        for peerID in connectedPeers {
            if let mappedFingerprint = peerIDToPublicKeyFingerprint[peerID],
               mappedFingerprint == fingerprint {
                return peerID
            }
        }
        return nil
    }
    
    // Helper method to update selectedPrivateChatPeer if fingerprint matches
    private func updatePrivateChatPeerIfNeeded() {
        guard let chatFingerprint = selectedPrivateChatFingerprint else { return }
        
        // Find current peer ID for the fingerprint
        if let currentPeerID = getCurrentPeerIDForFingerprint(chatFingerprint) {
            // Update the selected peer if it's different
            if let oldPeerID = selectedPrivateChatPeer, oldPeerID != currentPeerID {
                // Migrate messages from old peer ID to new peer ID
                if let oldMessages = privateChats[oldPeerID] {
                    if privateChats[currentPeerID] == nil {
                        privateChats[currentPeerID] = []
                    }
                    privateChats[currentPeerID]?.append(contentsOf: oldMessages)
                    trimPrivateChatMessagesIfNeeded(for: currentPeerID)
                    privateChats.removeValue(forKey: oldPeerID)
                }
                
                // Migrate unread status
                if unreadPrivateMessages.contains(oldPeerID) {
                    unreadPrivateMessages.remove(oldPeerID)
                    unreadPrivateMessages.insert(currentPeerID)
                }
                
                selectedPrivateChatPeer = currentPeerID
            } else if selectedPrivateChatPeer == nil {
                // Just set the peer ID if we don't have one
                selectedPrivateChatPeer = currentPeerID
            }
            
            // Clear unread messages for the current peer ID
            unreadPrivateMessages.remove(currentPeerID)
        }
    }
    
    func sendMessage(_ content: String) {
        guard !content.isEmpty else { return }
        
        // Check for commands
        if content.hasPrefix("/") {
            handleCommand(content)
            return
        }
        
        if selectedPrivateChatPeer != nil {
            // Update peer ID in case it changed due to reconnection
            updatePrivateChatPeerIfNeeded()
            
            if let selectedPeer = selectedPrivateChatPeer {
                // Send as private message
                sendPrivateMessage(content, to: selectedPeer)
            } else {
            }
        } else {
            // Parse mentions from the content
            let mentions = parseMentions(from: content)
            
            // Add message to local display
            let message = BitchatMessage(
                sender: nickname,
                content: content,
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: meshService.myPeerID,
                mentions: mentions.isEmpty ? nil : mentions,
            )
            
            // Add to main messages immediately for user feedback
            messages.append(message)
            trimMessagesIfNeeded()
            
            // Force immediate UI update for user's own messages
            objectWillChange.send()
            
            // Send via mesh with mentions
            meshService.sendMessage(content, mentions: mentions)
        }
    }
    
    func sendPrivateMessage(_ content: String, to peerID: String) {
        guard !content.isEmpty else { return }
        guard let recipientNickname = meshService.getPeerNicknames()[peerID] else { 
            return 
        }
        
        // Check if the recipient is blocked
        if isPeerBlocked(peerID) {
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "cannot send message to \(recipientNickname): user is blocked.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(systemMessage)
            return
        }
        
        // IMPORTANT: When sending a message, it means we're viewing this chat
        // Send read receipts for any delivered messages from this peer
        markPrivateMessagesAsRead(from: peerID)
        
        // Create the message locally
        let message = BitchatMessage(
            sender: nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: meshService.myPeerID,
            deliveryStatus: .sending
        )
        
        // Add to our private chat history
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        privateChats[peerID]?.append(message)
        trimPrivateChatMessagesIfNeeded(for: peerID)
        
        // Track the message for delivery confirmation
        let isFavorite = isFavorite(peerID: peerID)
        DeliveryTracker.shared.trackMessage(message, recipientID: peerID, recipientNickname: recipientNickname, isFavorite: isFavorite)
        
        // Immediate UI update for user's own messages
        objectWillChange.send()
        
        // Send via mesh with the same message ID
        meshService.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: message.id)
    }
    
    func startPrivateChat(with peerID: String) {
        let peerNickname = meshService.getPeerNicknames()[peerID] ?? "unknown"
        
        // Check if the peer is blocked
        if isPeerBlocked(peerID) {
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "cannot start chat with \(peerNickname): user is blocked.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(systemMessage)
            return
        }
        
        selectedPrivateChatPeer = peerID
        // Also track by fingerprint for persistence across reconnections
        selectedPrivateChatFingerprint = peerIDToPublicKeyFingerprint[peerID]
        unreadPrivateMessages.remove(peerID)
        
        // Check if we need to migrate messages from an old peer ID
        // This happens when peer IDs change between sessions
        if privateChats[peerID] == nil || privateChats[peerID]?.isEmpty == true {
            
            // Look for messages from this nickname under other peer IDs
            var migratedMessages: [BitchatMessage] = []
            var oldPeerIDsToRemove: [String] = []
            
            for (oldPeerID, messages) in privateChats {
                if oldPeerID != peerID {
                    // Check if any messages in this chat are from the peer's nickname
                    // Check if this chat contains messages with this peer
                    let messagesWithPeer = messages.filter { msg in
                        // Message is FROM the peer to us
                        (msg.sender == peerNickname && msg.sender != nickname) ||
                        // OR message is FROM us TO the peer
                        (msg.sender == nickname && (msg.recipientNickname == peerNickname || 
                         // Also check if this was a private message in a chat that only has us and one other person
                         (msg.isPrivate && messages.allSatisfy { m in 
                             m.sender == nickname || m.sender == peerNickname 
                         })))
                    }
                    
                    if !messagesWithPeer.isEmpty {
                        
                        // Check if ALL messages in this chat are between us and this peer
                        let allMessagesAreWithPeer = messages.allSatisfy { msg in
                            (msg.sender == peerNickname || msg.sender == nickname) &&
                            (msg.recipientNickname == nil || msg.recipientNickname == peerNickname || msg.recipientNickname == nickname)
                        }
                        
                        if allMessagesAreWithPeer {
                            // This entire chat history belongs to this peer, migrate it all
                            migratedMessages.append(contentsOf: messages)
                            oldPeerIDsToRemove.append(oldPeerID)
                        }
                    }
                }
            }
            
            // Remove old peer ID entries that were fully migrated
            for oldPeerID in oldPeerIDsToRemove {
                privateChats.removeValue(forKey: oldPeerID)
                unreadPrivateMessages.remove(oldPeerID)
            }
            
            // Initialize chat history with migrated messages if any
            if !migratedMessages.isEmpty {
                privateChats[peerID] = migratedMessages.sorted { $0.timestamp < $1.timestamp }
                trimPrivateChatMessagesIfNeeded(for: peerID)
            } else {
                privateChats[peerID] = []
            }
        }
        
        _ = privateChats[peerID] ?? []
        
        // Send read receipts for unread messages from this peer
        // Add a small delay to ensure UI has updated
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.markPrivateMessagesAsRead(from: peerID)
        }
        
        // Also try immediately in case messages are already there
        markPrivateMessagesAsRead(from: peerID)
    }
    
    func endPrivateChat() {
        selectedPrivateChatPeer = nil
        selectedPrivateChatFingerprint = nil
    }
    
    @objc private func appDidBecomeActive() {
        // When app becomes active, send read receipts for visible private chat
        if let peerID = selectedPrivateChatPeer {
            // Try immediately
            self.markPrivateMessagesAsRead(from: peerID)
            // And again with a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.markPrivateMessagesAsRead(from: peerID)
            }
        }
    }
    
    @objc private func userDidTakeScreenshot() {
        // Send screenshot notification based on current context
        let screenshotMessage = "* \(nickname) took a screenshot *"
        
        if let peerID = selectedPrivateChatPeer {
            // In private chat - send to the other person
            if let peerNickname = meshService.getPeerNicknames()[peerID] {
                // Send the message directly without going through sendPrivateMessage to avoid local echo
                meshService.sendPrivateMessage(screenshotMessage, to: peerID, recipientNickname: peerNickname)
            }
            
            // Show local notification immediately as system message
            let localNotification = BitchatMessage(
                sender: "system",
                content: "you took a screenshot",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: meshService.getPeerNicknames()[peerID],
                senderPeerID: meshService.myPeerID
            )
            if privateChats[peerID] == nil {
                privateChats[peerID] = []
            }
            privateChats[peerID]?.append(localNotification)
            trimPrivateChatMessagesIfNeeded(for: peerID)
            
        } else {
            // In public chat - send to everyone
            meshService.sendMessage(screenshotMessage, mentions: [])
            
            // Show local notification immediately as system message
            let localNotification = BitchatMessage(
                sender: "system",
                content: "you took a screenshot",
                timestamp: Date(),
                isRelay: false
            )
            // System messages can be batched
            addMessageToBatch(localNotification)
        }
    }
    
    @objc private func appWillResignActive() {
        // Flush any pending messages when app goes to background
        flushMessageBatchImmediately()
        
        userDefaults.synchronize()
    }
    
    @objc func applicationWillTerminate() {
        // Flush any pending messages immediately
        flushMessageBatchImmediately()
        
        // Verify identity key is still there
        _ = KeychainManager.shared.verifyIdentityKeyExists()
        
        userDefaults.synchronize()
        
        // Verify identity key after save
        _ = KeychainManager.shared.verifyIdentityKeyExists()
    }
    
    @objc private func appWillTerminate() {
        // Flush any pending messages immediately
        flushMessageBatchImmediately()
        
        userDefaults.synchronize()
    }
    
    func markPrivateMessagesAsRead(from peerID: String) {
        // Get the nickname for this peer
        let peerNickname = meshService.getPeerNicknames()[peerID] ?? ""
        
        // First ensure we have the latest messages (in case of migration)
        if let messages = privateChats[peerID], !messages.isEmpty {
        } else {
            
            // Look through ALL private chats to find messages from this nickname
            for (_, chatMessages) in privateChats {
                let relevantMessages = chatMessages.filter { msg in
                    msg.sender == peerNickname && msg.sender != nickname
                }
                if !relevantMessages.isEmpty {
                }
            }
        }
        
        guard let messages = privateChats[peerID], !messages.isEmpty else { 
            return 
        }
        
        
        // Find messages from the peer that haven't been read yet
        var readReceiptsSent = 0
        for (_, message) in messages.enumerated() {
            // Only send read receipts for messages from the other peer (not our own)
            // Check multiple conditions to ensure we catch all messages from the peer
            let isOurMessage = message.sender == nickname
            let isFromPeerByNickname = !peerNickname.isEmpty && message.sender == peerNickname
            let isFromPeerByID = message.senderPeerID == peerID
            let isPrivateToUs = message.isPrivate && message.recipientNickname == nickname
            
            // This is a message FROM the peer if it's not from us AND (matches nickname OR peer ID OR is private to us)
            let isFromPeer = !isOurMessage && (isFromPeerByNickname || isFromPeerByID || isPrivateToUs)
            
            if message.id == message.id { // Always true, for debugging
            }
            
            if isFromPeer {
                if let status = message.deliveryStatus {
                    switch status {
                    case .sent, .delivered:
                        // Create and send read receipt for sent or delivered messages
                        // Check if we've already sent a receipt for this message
                        if !sentReadReceipts.contains(message.id) {
                            // Send to the CURRENT peer ID, not the old senderPeerID which may have changed
                            let receipt = ReadReceipt(
                                originalMessageID: message.id,
                                readerID: meshService.myPeerID,
                                readerNickname: nickname
                            )
                            meshService.sendReadReceipt(receipt, to: peerID)
                            sentReadReceipts.insert(message.id)
                            readReceiptsSent += 1
                        } else {
                        }
                    case .read:
                        // Already read, no need to send another receipt
                        break
                    default:
                        // Message not yet delivered, can't mark as read
                        break
                    }
                } else {
                    // No delivery status - this might be an older message
                    // Send read receipt anyway for backwards compatibility
                    if !sentReadReceipts.contains(message.id) {
                        let receipt = ReadReceipt(
                            originalMessageID: message.id,
                            readerID: meshService.myPeerID,
                            readerNickname: nickname
                        )
                        meshService.sendReadReceipt(receipt, to: peerID)
                        sentReadReceipts.insert(message.id)
                        readReceiptsSent += 1
                    } else {
                    }
                }
            } else {
            }
        }
        
    }
    
    func getPrivateChatMessages(for peerID: String) -> [BitchatMessage] {
        let messages = privateChats[peerID] ?? []
        if !messages.isEmpty {
        }
        return messages
    }
    
    func getPeerIDForNickname(_ nickname: String) -> String? {
        let nicknames = meshService.getPeerNicknames()
        return nicknames.first(where: { $0.value == nickname })?.key
    }
    
    
    // PANIC: Emergency data clearing for activist safety
    func panicClearAllData() {
        // Flush any pending messages immediately before clearing
        flushMessageBatchImmediately()
        
        // Clear all messages
        messages.removeAll()
        privateChats.removeAll()
        unreadPrivateMessages.removeAll()
        
        // First run aggressive cleanup to get rid of all legacy items
        _ = KeychainManager.shared.aggressiveCleanupLegacyItems()
        
        // Then delete all current keychain data
        _ = KeychainManager.shared.deleteAllKeychainData()
        
        // Clear UserDefaults identity fallbacks
        userDefaults.removeObject(forKey: "bitchat.noiseIdentityKey")
        userDefaults.removeObject(forKey: "bitchat.messageRetentionKey")
        
        // Clear verified fingerprints
        verifiedFingerprints.removeAll()
        // Verified fingerprints are cleared when identity data is cleared below
        
        // Clear message retry queue
        MessageRetryService.shared.clearRetryQueue()
        
        
        // Reset nickname to anonymous
        nickname = "anon\(Int.random(in: 1000...9999))"
        saveNickname()
        
        // Clear favorites
        favoritePeers.removeAll()
        peerIDToPublicKeyFingerprint.removeAll()
        
        // Clear identity data from secure storage
        SecureIdentityStateManager.shared.clearAllIdentityData()
        
        // Clear autocomplete state
        autocompleteSuggestions.removeAll()
        showAutocomplete = false
        autocompleteRange = nil
        selectedAutocompleteIndex = 0
        
        // Clear selected private chat
        selectedPrivateChatPeer = nil
        selectedPrivateChatFingerprint = nil
        
        // Clear read receipt tracking
        sentReadReceipts.removeAll()
        
        // Clear all caches
        invalidateEncryptionCache()
        invalidateRSSIColorCache()
        
        // Disconnect from all peers and clear persistent identity
        // This will force creation of a new identity (new fingerprint) on next launch
        meshService.emergencyDisconnectAll()
        
        // Force immediate UserDefaults synchronization
        userDefaults.synchronize()
        
        // Force UI update
        objectWillChange.send()
        
    }
    
    
    
    func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    
    func getRSSIColor(rssi: Int, colorScheme: ColorScheme) -> Color {
        let isDark = colorScheme == .dark
        let cacheKey = "\(rssi)_\(isDark)"
        
        // Check cache first
        if let cachedColor = rssiColorCache[cacheKey] {
            return cachedColor
        }
        
        // RSSI typically ranges from -30 (excellent) to -90 (poor)
        // We'll map this to colors from green (strong) to red (weak)
        
        let color: Color
        if rssi >= -50 {
            // Excellent signal: bright green
            color = isDark ? Color(red: 0.0, green: 1.0, blue: 0.0) : Color(red: 0.0, green: 0.7, blue: 0.0)
        } else if rssi >= -60 {
            // Good signal: green-yellow
            color = isDark ? Color(red: 0.5, green: 1.0, blue: 0.0) : Color(red: 0.3, green: 0.7, blue: 0.0)
        } else if rssi >= -70 {
            // Fair signal: yellow
            color = isDark ? Color(red: 1.0, green: 1.0, blue: 0.0) : Color(red: 0.7, green: 0.7, blue: 0.0)
        } else if rssi >= -80 {
            // Weak signal: orange
            color = isDark ? Color(red: 1.0, green: 0.6, blue: 0.0) : Color(red: 0.8, green: 0.4, blue: 0.0)
        } else {
            // Poor signal: red
            color = isDark ? Color(red: 1.0, green: 0.2, blue: 0.2) : Color(red: 0.8, green: 0.0, blue: 0.0)
        }
        
        // Cache the result
        rssiColorCache[cacheKey] = color
        return color
    }
    
    func updateAutocomplete(for text: String, cursorPosition: Int) {
        // Quick early exit for empty text
        guard cursorPosition > 0 else {
            if showAutocomplete {
                showAutocomplete = false
                autocompleteSuggestions = []
                autocompleteRange = nil
            }
            return
        }
        
        // Find @ symbol before cursor
        let beforeCursor = String(text.prefix(cursorPosition))
        
        // Use cached regex
        guard let regex = mentionRegex,
              let match = regex.firstMatch(in: beforeCursor, options: [], range: NSRange(location: 0, length: beforeCursor.count)) else {
            if showAutocomplete {
                showAutocomplete = false
                autocompleteSuggestions = []
                autocompleteRange = nil
            }
            return
        }
        
        // Extract the partial nickname
        let partialRange = match.range(at: 1)
        guard let range = Range(partialRange, in: beforeCursor) else {
            if showAutocomplete {
                showAutocomplete = false
                autocompleteSuggestions = []
                autocompleteRange = nil
            }
            return
        }
        
        let partial = String(beforeCursor[range]).lowercased()
        
        // Update cached nicknames only if peer list changed (check every 1 second max)
        let now = Date()
        if now.timeIntervalSince(lastNicknameUpdate) > 1.0 || cachedNicknames.isEmpty {
            let peerNicknames = meshService.getPeerNicknames()
            cachedNicknames = Array(peerNicknames.values).sorted()
            lastNicknameUpdate = now
        }
        
        // Filter suggestions using cached nicknames
        let suggestions = cachedNicknames.filter { nick in
            nick.lowercased().hasPrefix(partial)
        }
        
        // Batch UI updates
        if !suggestions.isEmpty {
            // Only update if suggestions changed
            if autocompleteSuggestions != suggestions {
                autocompleteSuggestions = suggestions
            }
            if !showAutocomplete {
                showAutocomplete = true
            }
            if autocompleteRange != match.range(at: 0) {
                autocompleteRange = match.range(at: 0)
            }
            selectedAutocompleteIndex = 0
        } else {
            if showAutocomplete {
                showAutocomplete = false
                autocompleteSuggestions = []
                autocompleteRange = nil
                selectedAutocompleteIndex = 0
            }
        }
    }
    
    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        guard let range = autocompleteRange else { return text.count }
        
        // Replace the @partial with @nickname
        let nsText = text as NSString
        let newText = nsText.replacingCharacters(in: range, with: "@\(nickname) ")
        text = newText
        
        // Hide autocomplete
        showAutocomplete = false
        autocompleteSuggestions = []
        autocompleteRange = nil
        selectedAutocompleteIndex = 0
        
        // Return new cursor position (after the space)
        return range.location + nickname.count + 2
    }
    
    func getSenderColor(for message: BitchatMessage, colorScheme: ColorScheme) -> Color {
        let isDark = colorScheme == .dark
        let primaryColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        
        // Always use the same color for all senders - no RSSI-based coloring
        return primaryColor
    }
    
    
    func formatMessageContent(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        let isDark = colorScheme == .dark
        let contentText = message.content
        var processedContent = AttributedString()
        
        // Regular expressions for mentions and hashtags
        let mentionPattern = "@([a-zA-Z0-9_]+)"
        let hashtagPattern = "#([a-zA-Z0-9_]+)"
        
        let mentionRegex = try? NSRegularExpression(pattern: mentionPattern, options: [])
        let hashtagRegex = try? NSRegularExpression(pattern: hashtagPattern, options: [])
        
        let mentionMatches = mentionRegex?.matches(in: contentText, options: [], range: NSRange(location: 0, length: contentText.count)) ?? []
        let hashtagMatches = hashtagRegex?.matches(in: contentText, options: [], range: NSRange(location: 0, length: contentText.count)) ?? []
        
        // Combine and sort all matches
        var allMatches: [(range: NSRange, type: String)] = []
        for match in mentionMatches {
            allMatches.append((match.range(at: 0), "mention"))
        }
        for match in hashtagMatches {
            allMatches.append((match.range(at: 0), "hashtag"))
        }
        allMatches.sort { $0.range.location < $1.range.location }
        
        var lastEndIndex = contentText.startIndex
        
        for (matchRange, matchType) in allMatches {
            // Add text before the match
            if let range = Range(matchRange, in: contentText) {
                let beforeText = String(contentText[lastEndIndex..<range.lowerBound])
                if !beforeText.isEmpty {
                    var normalStyle = AttributeContainer()
                    normalStyle.font = .system(size: 14, design: .monospaced)
                    normalStyle.foregroundColor = isDark ? Color.white : Color.black
                    processedContent.append(AttributedString(beforeText).mergingAttributes(normalStyle))
                }
                
                // Add the match with appropriate styling
                let matchText = String(contentText[range])
                var matchStyle = AttributeContainer()
                matchStyle.font = .system(size: 14, weight: .semibold, design: .monospaced)
                
                if matchType == "mention" {
                    matchStyle.foregroundColor = Color.orange
                } else {
                    // Hashtag
                    matchStyle.foregroundColor = Color.blue
                    matchStyle.underlineStyle = .single
                }
                
                processedContent.append(AttributedString(matchText).mergingAttributes(matchStyle))
                
                lastEndIndex = range.upperBound
            }
        }
        
        // Add any remaining text
        if lastEndIndex < contentText.endIndex {
            let remainingText = String(contentText[lastEndIndex...])
            var normalStyle = AttributeContainer()
            normalStyle.font = .system(size: 14, design: .monospaced)
            normalStyle.foregroundColor = isDark ? Color.white : Color.black
            processedContent.append(AttributedString(remainingText).mergingAttributes(normalStyle))
        }
        
        return processedContent
    }
    
    func formatMessageAsText(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        // Check cache first
        let isDark = colorScheme == .dark
        if let cachedText = message.getCachedFormattedText(isDark: isDark) {
            return cachedText
        }
        
        // Not cached, format the message
        var result = AttributedString()
        
        let primaryColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        let secondaryColor = primaryColor.opacity(0.7)
        
        // Timestamp
        let timestamp = AttributedString("[\(formatTimestamp(message.timestamp))] ")
        var timestampStyle = AttributeContainer()
        timestampStyle.foregroundColor = message.sender == "system" ? Color.gray : secondaryColor
        timestampStyle.font = .system(size: 12, design: .monospaced)
        result.append(timestamp.mergingAttributes(timestampStyle))
        
        if message.sender != "system" {
            // Sender
            let sender = AttributedString("<@\(message.sender)> ")
            var senderStyle = AttributeContainer()
            
            // Use consistent color for all senders
            senderStyle.foregroundColor = primaryColor
            // Bold the user's own nickname
            let fontWeight: Font.Weight = message.sender == nickname ? .bold : .medium
            senderStyle.font = .system(size: 14, weight: fontWeight, design: .monospaced)
            result.append(sender.mergingAttributes(senderStyle))
            
            // Process content with hashtags and mentions
            let content = message.content
            
            let hashtagPattern = "#([a-zA-Z0-9_]+)"
            let mentionPattern = "@([a-zA-Z0-9_]+)"
            
            let hashtagRegex = try? NSRegularExpression(pattern: hashtagPattern, options: [])
            let mentionRegex = try? NSRegularExpression(pattern: mentionPattern, options: [])
            
            // Use NSDataDetector for URL detection
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            
            let hashtagMatches = hashtagRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            let mentionMatches = mentionRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            let urlMatches = detector?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            
            // Combine and sort matches
            var allMatches: [(range: NSRange, type: String)] = []
            for match in hashtagMatches {
                allMatches.append((match.range(at: 0), "hashtag"))
            }
            for match in mentionMatches {
                allMatches.append((match.range(at: 0), "mention"))
            }
            for match in urlMatches {
                allMatches.append((match.range, "url"))
            }
            allMatches.sort { $0.range.location < $1.range.location }
            
            // Build content with styling
            var lastEnd = content.startIndex
            let isMentioned = message.mentions?.contains(nickname) ?? false
            
            for (range, type) in allMatches {
                // Add text before match
                if let nsRange = Range(range, in: content) {
                    let beforeText = String(content[lastEnd..<nsRange.lowerBound])
                    if !beforeText.isEmpty {
                        var beforeStyle = AttributeContainer()
                        beforeStyle.foregroundColor = primaryColor
                        beforeStyle.font = .system(size: 14, design: .monospaced)
                        if isMentioned {
                            beforeStyle.font = beforeStyle.font?.bold()
                        }
                        result.append(AttributedString(beforeText).mergingAttributes(beforeStyle))
                    }
                    
                    // Add styled match
                    let matchText = String(content[nsRange])
                    var matchStyle = AttributeContainer()
                    matchStyle.font = .system(size: 14, weight: .semibold, design: .monospaced)
                    
                    if type == "hashtag" {
                        matchStyle.foregroundColor = Color.blue
                        matchStyle.underlineStyle = .single
                    } else if type == "mention" {
                        matchStyle.foregroundColor = Color.orange
                    } else if type == "url" {
                        matchStyle.foregroundColor = Color.blue
                        matchStyle.underlineStyle = .single
                    }
                    
                    result.append(AttributedString(matchText).mergingAttributes(matchStyle))
                    lastEnd = nsRange.upperBound
                }
            }
            
            // Add remaining text
            if lastEnd < content.endIndex {
                let remainingText = String(content[lastEnd...])
                var remainingStyle = AttributeContainer()
                remainingStyle.foregroundColor = primaryColor
                remainingStyle.font = .system(size: 14, design: .monospaced)
                if isMentioned {
                    remainingStyle.font = remainingStyle.font?.bold()
                }
                result.append(AttributedString(remainingText).mergingAttributes(remainingStyle))
            }
        } else {
            // System message
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            let content = AttributedString("* \(message.content) *")
            contentStyle.font = .system(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))
        }
        
        // Cache the formatted text
        message.setCachedFormattedText(result, isDark: isDark)
        
        return result
    }
    
    func formatMessage(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        var result = AttributedString()
        
        let isDark = colorScheme == .dark
        let primaryColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        let secondaryColor = primaryColor.opacity(0.7)
        
        let timestamp = AttributedString("[\(formatTimestamp(message.timestamp))] ")
        var timestampStyle = AttributeContainer()
        timestampStyle.foregroundColor = message.sender == "system" ? Color.gray : secondaryColor
        timestampStyle.font = .system(size: 12, design: .monospaced)
        result.append(timestamp.mergingAttributes(timestampStyle))
        
        if message.sender == "system" {
            let content = AttributedString("* \(message.content) *")
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = Color.gray
            contentStyle.font = .system(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))
        } else {
            let sender = AttributedString("<\(message.sender)> ")
            var senderStyle = AttributeContainer()
            
            // Use consistent color for all senders
            senderStyle.foregroundColor = primaryColor
            // Bold the user's own nickname
            let fontWeight: Font.Weight = message.sender == nickname ? .bold : .medium
            senderStyle.font = .system(size: 12, weight: fontWeight, design: .monospaced)
            result.append(sender.mergingAttributes(senderStyle))
            
            
            // Process content to highlight mentions
            let contentText = message.content
            var processedContent = AttributedString()
            
            // Regular expression to find @mentions
            let pattern = "@([a-zA-Z0-9_]+)"
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            let matches = regex?.matches(in: contentText, options: [], range: NSRange(location: 0, length: contentText.count)) ?? []
            
            var lastEndIndex = contentText.startIndex
            
            for match in matches {
                // Add text before the mention
                if let range = Range(match.range(at: 0), in: contentText) {
                    let beforeText = String(contentText[lastEndIndex..<range.lowerBound])
                    if !beforeText.isEmpty {
                        var normalStyle = AttributeContainer()
                        normalStyle.font = .system(size: 14, design: .monospaced)
                        normalStyle.foregroundColor = isDark ? Color.white : Color.black
                        processedContent.append(AttributedString(beforeText).mergingAttributes(normalStyle))
                    }
                    
                    // Add the mention with highlight
                    let mentionText = String(contentText[range])
                    var mentionStyle = AttributeContainer()
                    mentionStyle.font = .system(size: 14, weight: .semibold, design: .monospaced)
                    mentionStyle.foregroundColor = Color.orange
                    processedContent.append(AttributedString(mentionText).mergingAttributes(mentionStyle))
                    
                    lastEndIndex = range.upperBound
                }
            }
            
            // Add any remaining text
            if lastEndIndex < contentText.endIndex {
                let remainingText = String(contentText[lastEndIndex...])
                var normalStyle = AttributeContainer()
                normalStyle.font = .system(size: 14, design: .monospaced)
                normalStyle.foregroundColor = isDark ? Color.white : Color.black
                processedContent.append(AttributedString(remainingText).mergingAttributes(normalStyle))
            }
            
            result.append(processedContent)
            
            if message.isRelay, let originalSender = message.originalSender {
                let relay = AttributedString(" (via \(originalSender))")
                var relayStyle = AttributeContainer()
                relayStyle.foregroundColor = secondaryColor
                relayStyle.font = .system(size: 11, design: .monospaced)
                result.append(relay.mergingAttributes(relayStyle))
            }
        }
        
        return result
    }
    
    // MARK: - Noise Protocol Support
    
    func updateEncryptionStatusForPeers() {
        for peerID in connectedPeers {
            updateEncryptionStatusForPeer(peerID)
        }
    }
    
    func updateEncryptionStatusForPeer(_ peerID: String) {
        let noiseService = meshService.getNoiseService()
        
        if noiseService.hasEstablishedSession(with: peerID) {
            // Check if fingerprint is verified using our persisted data
            if let fingerprint = getFingerprint(for: peerID),
               verifiedFingerprints.contains(fingerprint) {
                peerEncryptionStatus[peerID] = .noiseVerified
            } else {
                peerEncryptionStatus[peerID] = .noiseSecured
            }
        } else if noiseService.hasSession(with: peerID) {
            // Session exists but not established - handshaking
            peerEncryptionStatus[peerID] = .noiseHandshaking
        } else {
            // No session at all
            peerEncryptionStatus[peerID] = Optional.none
        }
        
        // Invalidate cache when encryption status changes
        invalidateEncryptionCache(for: peerID)
        
        // Force UI update
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    func getEncryptionStatus(for peerID: String) -> EncryptionStatus {
        // Check cache first
        if let cachedStatus = encryptionStatusCache[peerID] {
            return cachedStatus
        }
        
        // This must be a pure function - no state mutations allowed
        // to avoid SwiftUI update loops
        
        let hasEstablished = meshService.getNoiseService().hasEstablishedSession(with: peerID)
        let hasSession = meshService.getNoiseService().hasSession(with: peerID)
        let storedStatus = peerEncryptionStatus[peerID]
        
        let status: EncryptionStatus
        
        // First check if we have an established session
        if hasEstablished {
            // We have encryption, now check if it's verified
            if let fingerprint = getFingerprint(for: peerID) {
                if verifiedFingerprints.contains(fingerprint) {
                    status = .noiseVerified
                } else {
                    status = .noiseSecured
                }
            } else {
                // We have a session but no fingerprint yet - still secured
                status = .noiseSecured
            }
        } else if hasSession {
            // Check if handshaking
            status = .noiseHandshaking
        } else {
            // Fall back to stored status
            status = storedStatus ?? .none
        }
        
        // Cache the result
        encryptionStatusCache[peerID] = status
        
        // Only log occasionally to avoid spam
        if Int.random(in: 0..<100) == 0 {
            SecureLogger.log("getEncryptionStatus for \(peerID): hasEstablished=\(hasEstablished), hasSession=\(hasSession), stored=\(String(describing: storedStatus)), final=\(status)", category: SecureLogger.security, level: .debug)
        }
        
        return status
    }
    
    // Clear caches when data changes
    private func invalidateEncryptionCache(for peerID: String? = nil) {
        if let peerID = peerID {
            encryptionStatusCache.removeValue(forKey: peerID)
        } else {
            encryptionStatusCache.removeAll()
        }
    }
    
    private func invalidateRSSIColorCache() {
        rssiColorCache.removeAll()
    }
    
    // Trim messages to keep only the most recent maxMessages
    private func trimMessagesIfNeeded() {
        if messages.count > maxMessages {
            let removeCount = messages.count - maxMessages
            messages.removeFirst(removeCount)
        }
    }
    
    // Trim private chat messages to keep only the most recent maxMessages
    private func trimPrivateChatMessagesIfNeeded(for peerID: String) {
        if let count = privateChats[peerID]?.count, count > maxMessages {
            let removeCount = count - maxMessages
            privateChats[peerID]?.removeFirst(removeCount)
        }
    }
    
    // MARK: - Message Batching
    
    private func addMessageToBatch(_ message: BitchatMessage) {
        pendingMessages.append(message)
        scheduleBatchFlush()
    }
    
    private func addPrivateMessageToBatch(_ message: BitchatMessage, for peerID: String) {
        if pendingPrivateMessages[peerID] == nil {
            pendingPrivateMessages[peerID] = []
        }
        pendingPrivateMessages[peerID]?.append(message)
        scheduleBatchFlush()
    }
    
    private func scheduleBatchFlush() {
        // Cancel existing timer
        messageBatchTimer?.invalidate()
        
        // Schedule new flush
        messageBatchTimer = Timer.scheduledTimer(withTimeInterval: messageBatchInterval, repeats: false) { [weak self] _ in
            self?.flushMessageBatch()
        }
    }
    
    private func flushMessageBatch() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Process pending public messages
            if !self.pendingMessages.isEmpty {
                let messagesToAdd = self.pendingMessages
                self.pendingMessages.removeAll()
                
                // Add all messages at once
                self.messages.append(contentsOf: messagesToAdd)
                
                // Sort once after batch addition
                self.messages.sort { $0.timestamp < $1.timestamp }
                
                // Trim once if needed
                self.trimMessagesIfNeeded()
            }
            
            // Process pending private messages
            if !self.pendingPrivateMessages.isEmpty {
                let privateMessageBatches = self.pendingPrivateMessages
                self.pendingPrivateMessages.removeAll()
                
                for (peerID, messagesToAdd) in privateMessageBatches {
                    if self.privateChats[peerID] == nil {
                        self.privateChats[peerID] = []
                    }
                    
                    // Add all messages for this peer at once
                    self.privateChats[peerID]?.append(contentsOf: messagesToAdd)
                    
                    // Sort once after batch addition
                    self.privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                    
                    // Trim once if needed
                    self.trimPrivateChatMessagesIfNeeded(for: peerID)
                }
            }
            
            // Single UI update for all changes
            self.objectWillChange.send()
        }
    }
    
    // Force immediate flush for high-priority messages
    private func flushMessageBatchImmediately() {
        messageBatchTimer?.invalidate()
        flushMessageBatch()
    }
    
    // Update encryption status in appropriate places, not during view updates
    private func updateEncryptionStatus(for peerID: String) {
        let noiseService = meshService.getNoiseService()
        
        if noiseService.hasEstablishedSession(with: peerID) {
            if let fingerprint = getFingerprint(for: peerID) {
                if verifiedFingerprints.contains(fingerprint) {
                    peerEncryptionStatus[peerID] = .noiseVerified
                } else {
                    peerEncryptionStatus[peerID] = .noiseSecured
                }
            } else {
                // Session established but no fingerprint yet
                peerEncryptionStatus[peerID] = .noiseSecured
            }
        } else if noiseService.hasSession(with: peerID) {
            peerEncryptionStatus[peerID] = .noiseHandshaking
        } else {
            peerEncryptionStatus[peerID] = Optional.none
        }
        
        // Invalidate cache when encryption status changes
        invalidateEncryptionCache(for: peerID)
        
        // Trigger UI update
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    func showFingerprint(for peerID: String) {
        showingFingerprintFor = peerID
    }
    
    func getFingerprint(for peerID: String) -> String? {
        // Remove debug logging to prevent console spam during view updates
        
        // First try to get fingerprint from mesh service's peer ID rotation mapping
        if let fingerprint = meshService.getFingerprint(for: peerID) {
            return fingerprint
        }
        
        // Fallback to noise service (direct Noise session fingerprint)
        if let fingerprint = meshService.getNoiseService().getPeerFingerprint(peerID) {
            return fingerprint
        }
        
        // Last resort: check local mapping
        if let fingerprint = peerIDToPublicKeyFingerprint[peerID] {
            return fingerprint
        }
        
        return nil
    }
    
    // Helper to resolve nickname for a peer ID through various sources
    func resolveNickname(for peerID: String) -> String {
        // Guard against empty or very short peer IDs
        guard !peerID.isEmpty else {
            return "unknown"
        }
        
        // Check if this might already be a nickname (not a hex peer ID)
        // Peer IDs are hex strings, so they only contain 0-9 and a-f
        let isHexID = peerID.allSatisfy { $0.isHexDigit }
        if !isHexID {
            // If it's already a nickname, just return it
            return peerID
        }
        
        // First try direct peer nicknames from mesh service
        let peerNicknames = meshService.getPeerNicknames()
        if let nickname = peerNicknames[peerID] {
            return nickname
        }
        
        // Try to resolve through fingerprint and social identity
        if let fingerprint = getFingerprint(for: peerID) {
            if let identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprint) {
                // Prefer local petname if set
                if let petname = identity.localPetname {
                    return petname
                }
                // Otherwise use their claimed nickname
                return identity.claimedNickname
            }
        }
        
        // Fallback to anonymous with shortened peer ID
        // Ensure we have at least 4 characters for the prefix
        let prefixLength = min(4, peerID.count)
        let prefix = String(peerID.prefix(prefixLength))
        
        // Avoid "anonanon" by checking if ID already starts with "anon"
        if prefix.starts(with: "anon") {
            return "peer\(prefix)"
        }
        return "anon\(prefix)"
    }
    
    func getMyFingerprint() -> String {
        let fingerprint = meshService.getNoiseService().getIdentityFingerprint()
        return fingerprint
    }
    
    func verifyFingerprint(for peerID: String) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }
        
        // Update secure storage with verified status
        SecureIdentityStateManager.shared.setVerified(fingerprint: fingerprint, verified: true)
        
        // Update local set for UI
        verifiedFingerprints.insert(fingerprint)
        
        // Update encryption status after verification
        updateEncryptionStatus(for: peerID)
    }
    
    func loadVerifiedFingerprints() {
        // Load verified fingerprints from secure storage
        let allIdentities = SecureIdentityStateManager.shared.getAllSocialIdentities()
        verifiedFingerprints = Set(allIdentities.filter { $0.trustLevel == .verified }.map { $0.fingerprint })
    }
    
    private func setupNoiseCallbacks() {
        let noiseService = meshService.getNoiseService()
        
        // Set up authentication callback
        noiseService.onPeerAuthenticated = { [weak self] peerID, fingerprint in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                SecureLogger.log("ChatViewModel: Peer authenticated - \(peerID), fingerprint: \(fingerprint)", category: SecureLogger.security, level: .info)
                
                // Update encryption status
                if self.verifiedFingerprints.contains(fingerprint) {
                    self.peerEncryptionStatus[peerID] = .noiseVerified
                    SecureLogger.log("ChatViewModel: Setting encryption status to noiseVerified for \(peerID)", category: SecureLogger.security, level: .info)
                } else {
                    self.peerEncryptionStatus[peerID] = .noiseSecured
                    SecureLogger.log("ChatViewModel: Setting encryption status to noiseSecured for \(peerID)", category: SecureLogger.security, level: .info)
                }
                
                // Invalidate cache when encryption status changes
                self.invalidateEncryptionCache(for: peerID)
                
                // Force UI update
                self.objectWillChange.send()
            }
        }
        
        // Set up handshake required callback
        noiseService.onHandshakeRequired = { [weak self] peerID in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.peerEncryptionStatus[peerID] = .noiseHandshaking
                
                // Invalidate cache when encryption status changes
                self.invalidateEncryptionCache(for: peerID)
                
                // Force UI update
                self.objectWillChange.send()
            }
        }
    }
}

extension ChatViewModel: BitchatDelegate {
    
    private func handleCommand(_ command: String) {
        let parts = command.split(separator: " ")
        guard let cmd = parts.first else { return }
        
        switch cmd {
        case "/m", "/msg":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Find peer ID for this nickname
                if let peerID = getPeerIDForNickname(nickname) {
                    startPrivateChat(with: peerID)
                    
                    // If there's a message after the nickname, send it
                    if parts.count > 2 {
                        let messageContent = parts[2...].joined(separator: " ")
                        sendPrivateMessage(messageContent, to: peerID)
                    } else {
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "started private chat with \(nickname)",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "user '\(nickname)' not found. they may be offline or using a different nickname.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /m @nickname [message] or /m nickname [message]",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
        case "/w":
            let peerNicknames = meshService.getPeerNicknames()
            if connectedPeers.isEmpty {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "no one else is online right now.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            } else {
                let onlineList = connectedPeers.compactMap { peerID in
                    peerNicknames[peerID]
                }.sorted().joined(separator: ", ")
                
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "online users: \(onlineList)",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
        case "/clear":
            // Clear messages based on current context
            if let peerID = selectedPrivateChatPeer {
                // Clear private chat
                privateChats[peerID]?.removeAll()
            } else {
                // Clear main messages
                messages.removeAll()
            }
        case "/hug":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Check if target exists in connected peers
                if let targetPeerID = getPeerIDForNickname(nickname) {
                    // Create hug message
                    let hugMessage = BitchatMessage(
                        sender: "system",
                        content: "🫂 \(self.nickname) hugs \(nickname)",
                        timestamp: Date(),
                        isRelay: false,
                        isPrivate: false,
                        recipientNickname: nickname,
                        senderPeerID: meshService.myPeerID
                    )
                    
                    // Send as a regular message but it will be displayed as system message due to content
                    let hugContent = "* 🫂 \(self.nickname) hugs \(nickname) *"
                    if selectedPrivateChatPeer != nil {
                        // In private chat, send as private message
                        if let peerNickname = meshService.getPeerNicknames()[targetPeerID] {
                            meshService.sendPrivateMessage("* 🫂 \(self.nickname) hugs you *", to: targetPeerID, recipientNickname: peerNickname)
                        }
                    } else {
                        // In public chat
                        meshService.sendMessage(hugContent)
                        messages.append(hugMessage)
                    }
                } else {
                    let errorMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot hug \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(errorMessage)
                }
            } else {
                let usageMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /hug <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(usageMessage)
            }
            
        case "/slap":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Check if target exists in connected peers
                if let targetPeerID = getPeerIDForNickname(nickname) {
                    // Create slap message
                    let slapMessage = BitchatMessage(
                        sender: "system",
                        content: "🐟 \(self.nickname) slaps \(nickname) around a bit with a large trout",
                        timestamp: Date(),
                        isRelay: false,
                        isPrivate: false,
                        recipientNickname: nickname,
                        senderPeerID: meshService.myPeerID
                    )
                    
                    // Send as a regular message but it will be displayed as system message due to content
                    let slapContent = "* 🐟 \(self.nickname) slaps \(nickname) around a bit with a large trout *"
                    if selectedPrivateChatPeer != nil {
                        // In private chat, send as private message
                        if let peerNickname = meshService.getPeerNicknames()[targetPeerID] {
                            meshService.sendPrivateMessage("* 🐟 \(self.nickname) slaps you around a bit with a large trout *", to: targetPeerID, recipientNickname: peerNickname)
                        }
                    } else {
                        // In public chat
                        meshService.sendMessage(slapContent)
                        messages.append(slapMessage)
                    }
                } else {
                    let errorMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot slap \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(errorMessage)
                }
            } else {
                let usageMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /slap <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(usageMessage)
            }
            
        case "/block":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Find peer ID for this nickname
                if let peerID = getPeerIDForNickname(nickname) {
                    // Get fingerprint for persistent blocking
                    if let fingerprintStr = meshService.getPeerFingerprint(peerID) {
                        
                        if SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprintStr) {
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "\(nickname) is already blocked.",
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                        } else {
                            // Update or create social identity with blocked status
                            if var identity = SecureIdentityStateManager.shared.getSocialIdentity(for: fingerprintStr) {
                                identity.isBlocked = true
                                identity.isFavorite = false  // Remove from favorites if blocked
                                SecureIdentityStateManager.shared.updateSocialIdentity(identity)
                            } else {
                                let blockedIdentity = SocialIdentity(
                                    fingerprint: fingerprintStr,
                                    localPetname: nil,
                                    claimedNickname: nickname,
                                    trustLevel: .unknown,
                                    isFavorite: false,
                                    isBlocked: true,
                                    notes: nil
                                )
                                SecureIdentityStateManager.shared.updateSocialIdentity(blockedIdentity)
                            }
                            
                            // Update local sets for UI
                            blockedUsers.insert(fingerprintStr)
                            favoritePeers.remove(fingerprintStr)
                            
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "blocked \(nickname). you will no longer receive messages from them.",
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                        }
                    } else {
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "cannot block \(nickname): unable to verify identity.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot block \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                }
            } else {
                // List blocked users
                if blockedUsers.isEmpty {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "no blocked peers.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                } else {
                    // Find nicknames for blocked users
                    var blockedNicknames: [String] = []
                    for (peerID, _) in meshService.getPeerNicknames() {
                        if let fingerprintStr = meshService.getPeerFingerprint(peerID) {
                            if blockedUsers.contains(fingerprintStr) {
                                if let nickname = meshService.getPeerNicknames()[peerID] {
                                    blockedNicknames.append(nickname)
                                }
                            }
                        }
                    }
                    
                    let blockedList = blockedNicknames.isEmpty ? "blocked peers (not currently online)" : blockedNicknames.sorted().joined(separator: ", ")
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "blocked peers: \(blockedList)",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                }
            }
            
        case "/unblock":
            if parts.count > 1 {
                let targetName = String(parts[1])
                // Remove @ if present
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                // Find peer ID for this nickname
                if let peerID = getPeerIDForNickname(nickname) {
                    // Get fingerprint
                    if let fingerprintStr = meshService.getPeerFingerprint(peerID) {
                        
                        if SecureIdentityStateManager.shared.isBlocked(fingerprint: fingerprintStr) {
                            // Update social identity to unblock
                            SecureIdentityStateManager.shared.setBlocked(fingerprintStr, isBlocked: false)
                            
                            // Update local set for UI
                            blockedUsers.remove(fingerprintStr)
                            
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "unblocked \(nickname).",
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                        } else {
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "\(nickname) is not blocked.",
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                        }
                    } else {
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "cannot unblock \(nickname): unable to verify identity.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(systemMessage)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "cannot unblock \(nickname): user not found.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /unblock <nickname>",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
            
        default:
            // Unknown command
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "unknown command: \(cmd).",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(systemMessage)
        }
    }
    
    func didReceiveMessage(_ message: BitchatMessage) {
        
        
        // Check if sender is blocked (for both private and public messages)
        if let senderPeerID = message.senderPeerID {
            if isPeerBlocked(senderPeerID) {
                // Silently ignore messages from blocked users
                return
            }
        } else if let peerID = getPeerIDForNickname(message.sender) {
            if isPeerBlocked(peerID) {
                // Silently ignore messages from blocked users
                return
            }
        }
        
        if message.isPrivate {
            // Handle private message
            
            // Use the senderPeerID from the message if available
            let senderPeerID = message.senderPeerID ?? getPeerIDForNickname(message.sender)
            
            if let peerID = senderPeerID {
                // Message from someone else
                
                // First check if we need to migrate existing messages from this sender
                let senderNickname = message.sender
                if privateChats[peerID] == nil || privateChats[peerID]?.isEmpty == true {
                    // Check if we have messages from this nickname under a different peer ID
                    var migratedMessages: [BitchatMessage] = []
                    var oldPeerIDsToRemove: [String] = []
                    
                    for (oldPeerID, messages) in privateChats {
                        if oldPeerID != peerID {
                            // Check if this chat contains messages with this sender
                            let isRelevantChat = messages.contains { msg in
                                (msg.sender == senderNickname && msg.sender != nickname) ||
                                (msg.sender == nickname && msg.recipientNickname == senderNickname)
                            }
                            
                            if isRelevantChat {
                                migratedMessages.append(contentsOf: messages)
                                oldPeerIDsToRemove.append(oldPeerID)
                            }
                        }
                    }
                    
                    // Remove old peer ID entries
                    for oldPeerID in oldPeerIDsToRemove {
                        privateChats.removeValue(forKey: oldPeerID)
                        unreadPrivateMessages.remove(oldPeerID)
                    }
                    
                    // Initialize with migrated messages
                    privateChats[peerID] = migratedMessages
                    trimPrivateChatMessagesIfNeeded(for: peerID)
                }
                
                if privateChats[peerID] == nil {
                    privateChats[peerID] = []
                }
                
                // Fix delivery status for incoming messages
                var messageToStore = message
                if message.sender != nickname {
                    // This is an incoming message - it should NOT have "sending" status
                    if messageToStore.deliveryStatus == nil || messageToStore.deliveryStatus == .sending {
                        // Mark it as delivered since we received it
                        messageToStore.deliveryStatus = .delivered(to: nickname, at: Date())
                    }
                }
                
                // Check if this is an action that should be converted to system message
                let isActionMessage = messageToStore.content.hasPrefix("* ") && messageToStore.content.hasSuffix(" *") &&
                                      (messageToStore.content.contains("🫂") || messageToStore.content.contains("🐟") || 
                                       messageToStore.content.contains("took a screenshot"))
                
                if isActionMessage {
                    // Convert to system message
                    messageToStore = BitchatMessage(
                        id: messageToStore.id,
                        sender: "system",
                        content: String(messageToStore.content.dropFirst(2).dropLast(2)), // Remove * * wrapper
                        timestamp: messageToStore.timestamp,
                        isRelay: messageToStore.isRelay,
                        originalSender: messageToStore.originalSender,
                        isPrivate: messageToStore.isPrivate,
                        recipientNickname: messageToStore.recipientNickname,
                        senderPeerID: messageToStore.senderPeerID,
                        mentions: messageToStore.mentions,
                        deliveryStatus: messageToStore.deliveryStatus
                    )
                }
                
                // Use batching for private messages
                addPrivateMessageToBatch(messageToStore, for: peerID)
                
                // Debug logging
                
                // Check if we're in a private chat with this peer's fingerprint
                // This handles reconnections with new peer IDs
                if let chatFingerprint = selectedPrivateChatFingerprint,
                   let senderFingerprint = peerIDToPublicKeyFingerprint[peerID],
                   chatFingerprint == senderFingerprint && selectedPrivateChatPeer != peerID {
                    // Update our private chat peer to the new ID
                    selectedPrivateChatPeer = peerID
                }
                
                // Mark as unread if not currently viewing this chat
                if selectedPrivateChatPeer != peerID {
                    unreadPrivateMessages.insert(peerID)
                    
                } else {
                    // We're viewing this chat, make sure unread is cleared
                    unreadPrivateMessages.remove(peerID)
                    
                    // Send read receipt immediately since we're viewing the chat
                    // Send to the current peer ID since peer IDs change between sessions
                    if !sentReadReceipts.contains(message.id) {
                        let receipt = ReadReceipt(
                            originalMessageID: message.id,
                            readerID: meshService.myPeerID,
                            readerNickname: nickname
                        )
                        meshService.sendReadReceipt(receipt, to: peerID)
                        sentReadReceipts.insert(message.id)
                    }
                    
                    // Also check if there are other unread messages from this peer
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.markPrivateMessagesAsRead(from: peerID)
                    }
                }
            } else if message.sender == nickname {
                // Our own message that was echoed back - ignore it since we already added it locally
            }
        } else {
            // Regular public message (main chat)
            
            // Check if this is an action that should be converted to system message
            let isActionMessage = message.content.hasPrefix("* ") && message.content.hasSuffix(" *") &&
                                  (message.content.contains("🫂") || message.content.contains("🐟") || 
                                   message.content.contains("took a screenshot"))
            
            let finalMessage: BitchatMessage
            if isActionMessage {
                // Convert to system message
                finalMessage = BitchatMessage(
                    sender: "system",
                    content: String(message.content.dropFirst(2).dropLast(2)), // Remove * * wrapper
                    timestamp: message.timestamp,
                    isRelay: message.isRelay,
                    originalSender: message.originalSender,
                    isPrivate: false,
                    recipientNickname: message.recipientNickname,
                    senderPeerID: message.senderPeerID,
                    mentions: message.mentions
                )
            } else {
                finalMessage = message
            }
            
            // Check if this is our own message being echoed back
            if finalMessage.sender != nickname && finalMessage.sender != "system" {
                // Skip empty or whitespace-only messages
                if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    addMessageToBatch(finalMessage)
                }
            } else if finalMessage.sender != "system" {
                // Our own message - check if we already have it (by ID and content)
                let messageExists = messages.contains { existingMsg in
                    // Check by ID first
                    if existingMsg.id == finalMessage.id {
                        return true
                    }
                    // Check by content and sender with time window (within 1 second)
                    if existingMsg.content == finalMessage.content && 
                       existingMsg.sender == finalMessage.sender {
                        let timeDiff = abs(existingMsg.timestamp.timeIntervalSince(finalMessage.timestamp))
                        return timeDiff < 1.0
                    }
                    return false
                }
                if !messageExists {
                    // This is a message we sent from another device or it's missing locally
                    // Skip empty or whitespace-only messages
                    if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        addMessageToBatch(finalMessage)
                    }
                }
            } else {
                // System message - check for empty content before adding
                if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    addMessageToBatch(finalMessage)
                }
            }
        }
        
        // Check if we're mentioned
        let isMentioned = message.mentions?.contains(nickname) ?? false
        
        // Send notifications for mentions and private messages when app is in background
        if isMentioned && message.sender != nickname {
            NotificationService.shared.sendMentionNotification(from: message.sender, message: message.content)
        } else if message.isPrivate && message.sender != nickname {
            // Only send notification if the private chat is not currently open
            if selectedPrivateChatPeer != message.senderPeerID {
                NotificationService.shared.sendPrivateMessageNotification(from: message.sender, message: message.content, peerID: message.senderPeerID ?? "")
            }
        }
        
        #if os(iOS)
        // Haptic feedback for iOS only
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        // Check if this is a hug message directed at the user
        let isHugForMe = message.content.contains("🫂") && 
                         (message.content.contains("hugs \(nickname)") ||
                          message.content.contains("hugs you"))
        
        // Check if this is a slap message directed at the user
        let isSlapForMe = message.content.contains("🐟") && 
                          (message.content.contains("slaps \(nickname) around") ||
                           message.content.contains("slaps you around"))
        
        if isHugForMe && message.sender != nickname {
            // Long warm haptic for hugs - continuous gentle vibration
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare()
            
            // Create a warm, sustained haptic pattern
            for i in 0..<8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) {
                    impactFeedback.impactOccurred()
                }
            }
            
            // Add a final stronger pulse
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let strongFeedback = UIImpactFeedbackGenerator(style: .heavy)
                strongFeedback.prepare()
                strongFeedback.impactOccurred()
            }
        } else if isSlapForMe && message.sender != nickname {
            // Very harsh, fast, strong haptic for slaps - multiple sharp impacts
            let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
            impactFeedback.prepare()
            
            // Rapid-fire heavy impacts to simulate a hard slap
            impactFeedback.impactOccurred()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                impactFeedback.impactOccurred()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                impactFeedback.impactOccurred()
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                impactFeedback.impactOccurred()
            }
            
            // Final extra heavy impact
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let finalImpact = UIImpactFeedbackGenerator(style: .heavy)
                finalImpact.prepare()
                finalImpact.impactOccurred()
            }
        } else if isMentioned && message.sender != nickname {
            // Very prominent haptic for @mentions - triple tap with heavy impact
            let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                impactFeedback.impactOccurred()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                impactFeedback.impactOccurred()
            }
        } else if message.isPrivate && message.sender != nickname {
            // Heavy haptic for private messages - more pronounced
            let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
            
            // Double tap for extra emphasis
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                impactFeedback.impactOccurred()
            }
        } else if message.sender != nickname {
            // Light haptic for public messages from others
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
        }
        #endif
    }
    
    func didConnectToPeer(_ peerID: String) {
        isConnected = true
        
        // Register ephemeral session with identity manager
        SecureIdentityStateManager.shared.registerEphemeralSession(peerID: peerID)
        
        // Resolve nickname using helper
        let displayName = resolveNickname(for: peerID)
        
        // Ensure we have a valid display name
        let finalDisplayName = displayName.isEmpty ? "peer" : displayName
        
        let systemMessage = BitchatMessage(
            sender: "system",
            content: "\(finalDisplayName) connected",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil
        )
        // Batch system messages
        addMessageToBatch(systemMessage)
    }
    
    func didDisconnectFromPeer(_ peerID: String) {
        // Remove ephemeral session from identity manager
        SecureIdentityStateManager.shared.removeEphemeralSession(peerID: peerID)
        
        // Clear sent read receipts for this peer since they'll need to be resent after reconnection
        // Only clear receipts for messages from this specific peer
        if let messages = privateChats[peerID] {
            for message in messages {
                // Remove read receipts for messages FROM this peer (not TO this peer)
                if message.senderPeerID == peerID {
                    sentReadReceipts.remove(message.id)
                }
            }
        }
        
        // Resolve nickname using helper
        let displayName = resolveNickname(for: peerID)
        
        // Ensure we have a valid display name
        let finalDisplayName = displayName.isEmpty ? "peer" : displayName
        
        let systemMessage = BitchatMessage(
            sender: "system",
            content: "\(finalDisplayName) disconnected",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil
        )
        // Batch system messages
        addMessageToBatch(systemMessage)
    }
    
    func didUpdatePeerList(_ peers: [String]) {
        // UI updates must run on the main thread.
        // The delegate callback is not guaranteed to be on the main thread.
        DispatchQueue.main.async {
            self.connectedPeers = peers
            self.isConnected = !peers.isEmpty
            
            // Register ephemeral sessions for all connected peers
            for peerID in peers {
                SecureIdentityStateManager.shared.registerEphemeralSession(peerID: peerID)
            }
            
            // Update encryption status for all peers
            self.updateEncryptionStatusForPeers()
            
            // Invalidate RSSI cache since peer data may have changed
            self.invalidateRSSIColorCache()

            // Explicitly notify SwiftUI that the object has changed.
            self.objectWillChange.send()
            
            // Check if we need to update private chat peer after reconnection
            if self.selectedPrivateChatFingerprint != nil {
                self.updatePrivateChatPeerIfNeeded()
            }
            
            // Only end private chat if we can't find the peer by fingerprint
            if let currentChatPeer = self.selectedPrivateChatPeer,
               !peers.contains(currentChatPeer),
               self.selectedPrivateChatFingerprint != nil {
                // Try one more time to find by fingerprint
                if self.getCurrentPeerIDForFingerprint(self.selectedPrivateChatFingerprint!) == nil {
                    self.endPrivateChat()
                }
            }
        }
    }
    
    private func parseMentions(from content: String) -> [String] {
        let pattern = "@([a-zA-Z0-9_]+)"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let matches = regex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        
        var mentions: [String] = []
        let peerNicknames = meshService.getPeerNicknames()
        let allNicknames = Set(peerNicknames.values).union([nickname]) // Include self
        
        for match in matches {
            if let range = Range(match.range(at: 1), in: content) {
                let mentionedName = String(content[range])
                // Only include if it's a valid nickname
                if allNicknames.contains(mentionedName) {
                    mentions.append(mentionedName)
                }
            }
        }
        
        return Array(Set(mentions)) // Remove duplicates
    }
    
    func isFavorite(fingerprint: String) -> Bool {
        return SecureIdentityStateManager.shared.isFavorite(fingerprint: fingerprint)
    }
    
    func didReceiveDeliveryAck(_ ack: DeliveryAck) {
        // Find the message and update its delivery status
        updateMessageDeliveryStatus(ack.originalMessageID, status: .delivered(to: ack.recipientNickname, at: ack.timestamp))
    }
    
    func didReceiveReadReceipt(_ receipt: ReadReceipt) {
        // Find the message and update its read status
        updateMessageDeliveryStatus(receipt.originalMessageID, status: .read(by: receipt.readerNickname, at: receipt.timestamp))
        
        // Clear delivery tracking since the message has been read
        // This prevents the timeout from marking it as failed
        DeliveryTracker.shared.clearDeliveryStatus(for: receipt.originalMessageID)
    }
    
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        updateMessageDeliveryStatus(messageID, status: status)
    }
    
    private func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        SecureLogger.log("Updating UI delivery status for message \(messageID): \(status)", category: SecureLogger.session, level: .debug)
        
        // Helper function to check if we should skip this update
        func shouldSkipUpdate(currentStatus: DeliveryStatus?, newStatus: DeliveryStatus) -> Bool {
            guard let current = currentStatus else { return false }
            
            // Don't downgrade from read to delivered
            switch (current, newStatus) {
            case (.read, .delivered):
                return true
            case (.read, .sent):
                return true
            default:
                return false
            }
        }
        
        // Update in main messages
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            let currentStatus = messages[index].deliveryStatus
            if !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) {
                messages[index].deliveryStatus = status
            }
        }
        
        // Update in private chats
        var updatedPrivateChats = privateChats
        for (peerID, chatMessages) in updatedPrivateChats {
            if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                let currentStatus = chatMessages[index].deliveryStatus
                if !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) {
                    chatMessages[index].deliveryStatus = status
                    updatedPrivateChats[peerID] = chatMessages
                }
            }
        }
        
        // Force complete reassignment to trigger SwiftUI update
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.privateChats = updatedPrivateChats
            self.objectWillChange.send()
        }
        
    }
    
    
}
