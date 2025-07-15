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

enum ChannelVerificationStatus {
    case unverified
    case verifying
    case verified
    case failed
}

class ChatViewModel: ObservableObject {
    @Published var messages: [BitchatMessage] = []
    @Published var connectedPeers: [String] = []
    @Published var nickname: String = "" {
        didSet {
            nicknameSaveTimer?.invalidate()
            nicknameSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                self.saveNickname()
            }
        }
    }
    @Published var isConnected = false
    @Published var privateChats: [String: [BitchatMessage]] = [:] // peerID -> messages
    @Published var selectedPrivateChatPeer: String? = nil
    private var selectedPrivateChatFingerprint: String? = nil  // Track by fingerprint for persistence across reconnections
    @Published var unreadPrivateMessages: Set<String> = []
    @Published var autocompleteSuggestions: [String] = []
    @Published var showAutocomplete: Bool = false
    @Published var autocompleteRange: NSRange? = nil
    @Published var selectedAutocompleteIndex: Int = 0
    
    // Channel support
    @Published var joinedChannels: Set<String> = []  // Set of channel hashtags
    @Published var currentChannel: String? = nil  // Currently selected channel
    @Published var channelMessages: [String: [BitchatMessage]] = [:]  // channel -> messages
    @Published var unreadChannelMessages: [String: Int] = [:]  // channel -> unread count
    @Published var channelMembers: [String: Set<String>] = [:]  // channel -> set of peer IDs who have sent messages
    @Published var channelPasswords: [String: String] = [:]  // channel -> password (stored locally only)
    @Published var channelKeys: [String: SymmetricKey] = [:]  // channel -> derived encryption key
    @Published var passwordProtectedChannels: Set<String> = []  // Set of channels that require passwords
    @Published var channelCreators: [String: String] = [:]  // channel -> creator peerID
    @Published var channelKeyCommitments: [String: String] = [:]  // channel -> SHA256(derivedKey) for verification
    @Published var channelMetadata: [String: ChannelMetadata] = [:]  // channel -> metadata from creator
    @Published var showPasswordPrompt: Bool = false
    @Published var passwordPromptChannel: String? = nil
    @Published var savedChannels: Set<String> = []  // Channels saved for message retention
    @Published var retentionEnabledChannels: Set<String> = []  // Channels where owner enabled retention for all members
    @Published var channelVerificationStatus: [String: ChannelVerificationStatus] = [:]  // Track verification status
    
    var meshService = BluetoothMeshService()
    private let userDefaults = UserDefaults.standard
    private let nicknameKey = "bitchat.nickname"
    private let joinedChannelsKey = "bitchat.joinedChannels"
    private let passwordProtectedChannelsKey = "bitchat.passwordProtectedChannels"
    private let channelCreatorsKey = "bitchat.channelCreators"
    // private let channelPasswordsKey = "bitchat.channelPasswords" // Now using Keychain
    private let channelKeyCommitmentsKey = "bitchat.channelKeyCommitments"
    private let retentionEnabledChannelsKey = "bitchat.retentionEnabledChannels"
    private var nicknameSaveTimer: Timer?
    
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
        loadJoinedChannels()
        loadChannelData()
        loadBlockedUsers()
        loadVerifiedFingerprints()
        // Load saved channels state
        savedChannels = MessageRetentionService.shared.getFavoriteChannels()
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
        
        // Show welcome message after delay if still no peers
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.connectedPeers.isEmpty && self.messages.isEmpty {
                let welcomeMessage = BitchatMessage(
                    sender: "system",
                    content: "get people around you to download bitchat…and chat with them here!",
                    timestamp: Date(),
                    isRelay: false
                )
                self.messages.append(welcomeMessage)
            }
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
        // Ensure channel ownership data is saved
        saveChannelData()
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
    
    private func loadJoinedChannels() {
        if let savedChannelsList = userDefaults.stringArray(forKey: joinedChannelsKey) {
            joinedChannels = Set(savedChannelsList)
            // Initialize empty data structures for joined channels
            for channel in joinedChannels {
                if channelMessages[channel] == nil {
                    channelMessages[channel] = []
                }
                if channelMembers[channel] == nil {
                    channelMembers[channel] = Set()
                }
                
                // Load saved messages if this channel has retention enabled
                if retentionEnabledChannels.contains(channel) {
                    let savedMessages = MessageRetentionService.shared.loadMessagesForChannel(channel)
                    if !savedMessages.isEmpty {
                        channelMessages[channel] = savedMessages
                    }
                }
            }
        }
    }
    
    private func saveJoinedChannels() {
        userDefaults.set(Array(joinedChannels), forKey: joinedChannelsKey)
        userDefaults.synchronize()
    }
    
    private func loadChannelData() {
        // Load password protected channels
        if let savedProtectedChannels = userDefaults.stringArray(forKey: passwordProtectedChannelsKey) {
            passwordProtectedChannels = Set(savedProtectedChannels)
        }
        
        // Load channel creators
        if let savedCreators = userDefaults.dictionary(forKey: channelCreatorsKey) as? [String: String] {
            channelCreators = savedCreators
            
            // Clean up any legacy ownership records
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.cleanupLegacyChannelOwnership()
            }
        } else {
        }
        
        // Load channel key commitments
        if let savedCommitments = userDefaults.dictionary(forKey: channelKeyCommitmentsKey) as? [String: String] {
            channelKeyCommitments = savedCommitments
        }
        
        // Load retention-enabled channels
        if let savedRetentionChannels = userDefaults.stringArray(forKey: retentionEnabledChannelsKey) {
            retentionEnabledChannels = Set(savedRetentionChannels)
        }
        
        // Load channel passwords from Keychain
        let savedPasswords = KeychainManager.shared.getAllChannelPasswords()
        channelPasswords = savedPasswords
        // Derive keys for all saved passwords
        for (channel, password) in savedPasswords {
            channelKeys[channel] = deriveChannelKey(from: password, channelName: channel)
            // Also load password into NoiseEncryptionService
            _ = meshService.getNoiseService().loadChannelPassword(for: channel)
        }
        
        // Also check if passwords were saved but not loaded for password-protected channels
        for channel in passwordProtectedChannels {
            if !channelPasswords.keys.contains(channel) {
            }
        }
    }
    
    private func saveChannelData() {
        
        userDefaults.set(Array(passwordProtectedChannels), forKey: passwordProtectedChannelsKey)
        userDefaults.set(channelCreators, forKey: channelCreatorsKey)
        // Save passwords to Keychain instead of UserDefaults
        for (channel, password) in channelPasswords {
            _ = KeychainManager.shared.saveChannelPassword(password, for: channel)
        }
        userDefaults.set(channelKeyCommitments, forKey: channelKeyCommitmentsKey)
        userDefaults.set(Array(retentionEnabledChannels), forKey: retentionEnabledChannelsKey)
        
        // Force synchronize and add a small delay to ensure writes complete
        _ = userDefaults.synchronize()
        
        // Verify save worked
        _ = userDefaults.dictionary(forKey: channelCreatorsKey) as? [String: String] != nil
    }
    
    func joinChannel(_ channel: String, password: String? = nil) -> Bool {
        // Ensure channel starts with #
        let channelTag = channel.hasPrefix("#") ? channel : "#\(channel)"
        
        
        // Check if channel is already joined and we can access it
        if joinedChannels.contains(channelTag) {
            // Already joined, check if we need password verification
            if passwordProtectedChannels.contains(channelTag) && channelKeys[channelTag] == nil {
                if let password = password {
                    // User provided password for already-joined channel - verify it
                    
                    // Derive key and try to verify
                    let key = deriveChannelKey(from: password, channelName: channelTag)
                    
                    // First, check if we have a key commitment to verify against
                    if let expectedCommitment = channelKeyCommitments[channelTag] {
                        let actualCommitment = computeKeyCommitment(for: key)
                        if actualCommitment != expectedCommitment {
                            return false
                        }
                    }
                    
                    // Check if we have messages to verify against
                    if let channelMsgs = channelMessages[channelTag], !channelMsgs.isEmpty {
                        let encryptedMessages = channelMsgs.filter { $0.isEncrypted && $0.encryptedContent != nil }
                        if let encryptedMsg = encryptedMessages.first,
                           let encryptedData = encryptedMsg.encryptedContent {
                            let testDecrypted = decryptChannelMessage(encryptedData, channel: channelTag, testKey: key)
                            if testDecrypted == nil {
                                return false
                            }
                        }
                    }
                    
                    // Store the verified key
                    channelKeys[channelTag] = key
                    channelPasswords[channelTag] = password
                    
                    // Now switch to the channel
                    switchToChannel(channelTag)
                    return true
                } else {
                    // Need password to access
                    passwordPromptChannel = channelTag
                    showPasswordPrompt = true
                    return false
                }
            }
            // Switch to the channel (no password needed)
            switchToChannel(channelTag)
            return true
        }
        
        // If channel is password protected and we don't have the key yet
        if passwordProtectedChannels.contains(channelTag) && channelKeys[channelTag] == nil {
            // Allow channel creator to bypass password check
            let myFingerprint = getMyFingerprint()
            if channelCreators[channelTag] == meshService.myPeerID || channelCreators[channelTag] == myFingerprint {
                // Channel creator should already have the key set when they created the password
                // This is a failsafe - just proceed without password
            } else if let password = password {
                // Derive key from password
                let key = deriveChannelKey(from: password, channelName: channelTag)
                
                // First, check if we have a key commitment to verify against
                if let expectedCommitment = channelKeyCommitments[channelTag] {
                    let actualCommitment = computeKeyCommitment(for: key)
                    if actualCommitment != expectedCommitment {
                        return false
                    }
                }
                
                // Try to verify password if there are existing encrypted messages
                var passwordVerified = false
                var shouldProceed = true
                
                if let channelMsgs = channelMessages[channelTag], !channelMsgs.isEmpty {
                    // Look for encrypted messages to verify against
                    let encryptedMessages = channelMsgs.filter { $0.isEncrypted && $0.encryptedContent != nil }
                    
                    if let encryptedMsg = encryptedMessages.first,
                       let encryptedData = encryptedMsg.encryptedContent {
                        // Test decryption with the derived key
                        let testDecrypted = decryptChannelMessage(encryptedData, channel: channelTag, testKey: key)
                        if testDecrypted == nil {
                            // Password is wrong, can't decrypt
                            shouldProceed = false
                        } else {
                            passwordVerified = true
                        }
                    } else {
                        // No encrypted messages yet - accept tentatively
                        
                        // Add warning message
                        let warningMsg = BitchatMessage(
                            sender: "system",
                            content: "joined channel \(channelTag). password will be verified when encrypted messages arrive.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(warningMsg)
                    }
                } else {
                    // Empty channel - accept tentatively
                    
                    // Add info message
                    let infoMsg = BitchatMessage(
                        sender: "system",
                        content: "joined empty channel \(channelTag). waiting for encrypted messages to verify password.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(infoMsg)
                }
                
                // Only proceed if password verification didn't fail
                if !shouldProceed {
                    return false
                }
                
                // Store the key (tentatively if not verified)
                channelKeys[channelTag] = key
                channelPasswords[channelTag] = password
                // Save password to Keychain
                _ = KeychainManager.shared.saveChannelPassword(password, for: channelTag)
                
                if passwordVerified {
                    // Password verified locally
                    // Password verified locally
                } else {
                    // Send key verification request to channel members after a short delay
                    // to allow channel member list to populate
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.sendChannelKeyVerificationRequest(for: channelTag)
                    }
                }
            } else {
                // Show password prompt and return early - don't join the channel yet
                passwordPromptChannel = channelTag
                showPasswordPrompt = true
                return false
            }
        }
        
        // At this point, channel is either not password protected or we don't know yet
        
        joinedChannels.insert(channelTag)
        saveJoinedChannels()
        
        // Only claim creator role if this is a brand new channel (no one has announced it as protected)
        // If it's password protected, someone else already created it
        // Also check if we have metadata from another creator
        let hasExistingMetadata = channelMetadata[channelTag] != nil
        let isNewChannel = channelCreators[channelTag] == nil && !passwordProtectedChannels.contains(channelTag) && !hasExistingMetadata
        if isNewChannel {
            // Use persistent fingerprint for ownership instead of ephemeral peer ID
            let myFingerprint = getMyFingerprint()
            // Creating new channel
            
            if myFingerprint != "Unknown" {
                channelCreators[channelTag] = myFingerprint
                // Set creator to fingerprint
                saveChannelData()
            } else {
                // Fallback to peer ID if encryption service not ready yet
                channelCreators[channelTag] = meshService.myPeerID
                // Fingerprint not ready, using peer ID temporarily
                saveChannelData()
                // Try to update to fingerprint after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    if let self = self {
                        let updatedFingerprint = self.getMyFingerprint()
                        if updatedFingerprint != "Unknown" && self.channelCreators[channelTag] == self.meshService.myPeerID {
                            self.channelCreators[channelTag] = updatedFingerprint
                            // Updated creator to fingerprint
                            self.saveChannelData()
                        }
                    }
                }
            }
            
            // Broadcasting channel creation to public chat
            
            // Broadcast channel metadata to all peers
            let metadata = ChannelMetadata(
                channel: channelTag,
                creatorID: meshService.myPeerID,
                creatorFingerprint: myFingerprint,
                isPasswordProtected: password != nil,
                keyCommitment: password != nil ? computeKeyCommitment(for: deriveChannelKey(from: password!, channelName: channelTag)) : nil
            )
            meshService.sendChannelMetadata(metadata)
            
            // Add system message to show channel creation
            let sysMsg = BitchatMessage(
                sender: "system",
                content: "you created channel \(channelTag). announcing to public chat...",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(sysMsg)
            
            // Announce channel creation in public chat (delay to ensure proper context)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                // Store current channel temporarily
                let previousChannel = self.currentChannel
                self.currentChannel = nil  // Ensure we're in public chat
                
                // Send announcement
                let announcement = "created channel \(channelTag)"
                self.sendMessage(announcement)
                
                // Restore channel context
                self.currentChannel = previousChannel
            }
        }
        
        // Add ourselves as a member
        if channelMembers[channelTag] == nil {
            channelMembers[channelTag] = Set()
        }
        channelMembers[channelTag]?.insert(meshService.myPeerID)
        
        // If password protected, also add any connected peers who might be in the channel
        // They'll be properly verified when they send messages
        if passwordProtectedChannels.contains(channelTag) {
            for peerID in connectedPeers {
                channelMembers[channelTag]?.insert(peerID)
            }
        }
        
        // Switch to the channel
        currentChannel = channelTag
        selectedPrivateChatPeer = nil  // Exit private chat if in one
        
        // Clear unread count for this channel
        unreadChannelMessages[channelTag] = 0
        
        // Initialize channel messages if needed
        if channelMessages[channelTag] == nil {
            channelMessages[channelTag] = []
        }
        
        // Load saved messages if this is a favorite channel
        if MessageRetentionService.shared.getFavoriteChannels().contains(channelTag) {
            let savedMessages = MessageRetentionService.shared.loadMessagesForChannel(channelTag)
            if !savedMessages.isEmpty {
                // Merge saved messages with current messages, avoiding duplicates
                var existingMessageIDs = Set(channelMessages[channelTag]?.map { $0.id } ?? [])
                for savedMessage in savedMessages {
                    if !existingMessageIDs.contains(savedMessage.id) {
                        channelMessages[channelTag]?.append(savedMessage)
                        existingMessageIDs.insert(savedMessage.id)
                    }
                }
                // Sort by timestamp
                channelMessages[channelTag]?.sort { $0.timestamp < $1.timestamp }
            }
        }
        
        // Hide password prompt if it was showing
        showPasswordPrompt = false
        passwordPromptChannel = nil
        
        // If this is a password protected channel, trigger verification
        if passwordProtectedChannels.contains(channelTag) && channelKeys[channelTag] != nil {
            // Send verification request after a short delay to allow peers to see us join
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.sendChannelKeyVerificationRequest(for: channelTag)
            }
        }
        
        return true
    }
    
    func leaveChannel(_ channel: String) {
        joinedChannels.remove(channel)
        saveJoinedChannels()
        
        // Send leave notification to other peers
        meshService.sendChannelLeaveNotification(channel)
        
        // If we're currently in this channel, exit to main chat
        if currentChannel == channel {
            currentChannel = nil
        }
        
        // Clean up channel data
        unreadChannelMessages.removeValue(forKey: channel)
        channelMessages.removeValue(forKey: channel)
        channelMembers.removeValue(forKey: channel)
        channelKeys.removeValue(forKey: channel)
        channelPasswords.removeValue(forKey: channel)
        // Delete password from Keychain
        _ = KeychainManager.shared.deleteChannelPassword(for: channel)
    }
    
    // Password management
    func setChannelPassword(_ password: String, for channel: String) {
        guard joinedChannels.contains(channel) else { return }
        
        // Check if channel already has a creator
        let myFingerprint = getMyFingerprint()
        if let existingCreator = channelCreators[channel], 
           existingCreator != meshService.myPeerID && existingCreator != myFingerprint {
            return
        }
        
        // If channel is already password protected by someone else, we can't claim it
        if passwordProtectedChannels.contains(channel) && 
           channelCreators[channel] != meshService.myPeerID && channelCreators[channel] != myFingerprint {
            return
        }
        
        // Claim creator role if not set and channel is not already protected
        if channelCreators[channel] == nil && !passwordProtectedChannels.contains(channel) {
            if myFingerprint != "Unknown" {
                channelCreators[channel] = myFingerprint
                // Set creator to fingerprint
            } else {
                channelCreators[channel] = meshService.myPeerID
                
                // Try to update to fingerprint after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    if let self = self {
                        let updatedFingerprint = self.getMyFingerprint()
                        if updatedFingerprint != "Unknown" && self.channelCreators[channel] == self.meshService.myPeerID {
                            self.channelCreators[channel] = updatedFingerprint
                            // Updated creator to fingerprint
                            self.saveChannelData()
                        }
                    }
                }
            }
            saveChannelData()
        }
        
        // Derive encryption key from password
        let key = deriveChannelKey(from: password, channelName: channel)
        channelKeys[channel] = key
        channelPasswords[channel] = password
        passwordProtectedChannels.insert(channel)
        // Save password to Keychain
        _ = KeychainManager.shared.saveChannelPassword(password, for: channel)
        
        // Compute and store key commitment for verification
        let commitment = computeKeyCommitment(for: key)
        channelKeyCommitments[channel] = commitment
        
        // Save channel data
        saveChannelData()
        
        // Announce that this channel is now password protected with commitment
        // Use fingerprint if available, otherwise peer ID
        let creatorID = myFingerprint != "Unknown" ? myFingerprint : meshService.myPeerID
        meshService.announcePasswordProtectedChannel(channel, creatorID: creatorID, keyCommitment: commitment)
        
        // Send an encrypted initialization message with metadata
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let metadata = [
            "type": "channel_init",
            "channel": channel,
            "creator": nickname,
            "creatorID": meshService.myPeerID,
            "timestamp": timestamp,
            "version": "1.0"
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: metadata)
        let metadataStr = jsonData?.base64EncodedString() ?? ""
        
        let initMessage = "🔐 Channel \(channel) initialized | Protected channel created by \(nickname) | Metadata: \(metadataStr)"
        meshService.sendEncryptedChannelMessage(initMessage, mentions: [], channel: channel, channelKey: key)
        
    }
    
    func removeChannelPassword(for channel: String) {
        // Only channel creator can remove password
        guard channelCreators[channel] == meshService.myPeerID else {
            return
        }
        
        channelKeys.removeValue(forKey: channel)
        channelPasswords.removeValue(forKey: channel)
        channelKeyCommitments.removeValue(forKey: channel)
        passwordProtectedChannels.remove(channel)
        // Delete password from Keychain
        _ = KeychainManager.shared.deleteChannelPassword(for: channel)
        
        // Save channel data
        saveChannelData()
        
        // Announce that this channel is no longer password protected
        meshService.announcePasswordProtectedChannel(channel, isProtected: false, creatorID: meshService.myPeerID)
        
    }
    
    // Transfer channel ownership to another user
    func transferChannelOwnership(to nickname: String) {
        guard let currentChannel = currentChannel else {
            let msg = BitchatMessage(
                sender: "system",
                content: "you must be in a channel to transfer ownership.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Check if current user is the owner using fingerprint
        guard isChannelOwner(currentChannel) else {
            let msg = BitchatMessage(
                sender: "system",
                content: "only the channel owner can transfer ownership.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Remove @ prefix if present
        let targetNick = nickname.hasPrefix("@") ? String(nickname.dropFirst()) : nickname
        
        // Find peer ID for the nickname
        guard let targetPeerID = getPeerIDForNickname(targetNick) else {
            let msg = BitchatMessage(
                sender: "system",
                content: "user \(targetNick) not found. they must be online to receive ownership.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Get the fingerprint of the target peer
        guard let targetFingerprint = getFingerprint(for: targetPeerID), targetFingerprint != "Unknown" else {
            let msg = BitchatMessage(
                sender: "system",
                content: "cannot transfer ownership: \(targetNick) does not have a verified identity.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Update ownership to target's fingerprint
        channelCreators[currentChannel] = targetFingerprint
        saveChannelData()
        
        // Broadcast updated channel metadata with new owner
        let metadata = ChannelMetadata(
            channel: currentChannel,
            creatorID: targetPeerID,
            creatorFingerprint: targetFingerprint,
            isPasswordProtected: passwordProtectedChannels.contains(currentChannel),
            keyCommitment: channelKeyCommitments[currentChannel]
        )
        meshService.sendChannelMetadata(metadata)
        
        // Also announce if password protected
        if passwordProtectedChannels.contains(currentChannel) {
            let commitment = channelKeyCommitments[currentChannel]
            meshService.announcePasswordProtectedChannel(currentChannel, creatorID: targetFingerprint, keyCommitment: commitment)
        }
        
        // Send notification message
        let transferMsg = BitchatMessage(
            sender: "system",
            content: "channel ownership transferred from \(self.nickname) to \(targetNick).",
            timestamp: Date(),
            isRelay: false,
            channel: currentChannel
        )
        messages.append(transferMsg)
        
        // Send encrypted notification if channel is protected
        if let channelKey = channelKeys[currentChannel] {
            let notifyMsg = "🔑 Channel ownership transferred to \(targetNick) by \(self.nickname)"
            meshService.sendEncryptedChannelMessage(notifyMsg, mentions: [targetNick], channel: currentChannel, channelKey: channelKey)
        } else {
            meshService.sendMessage(transferMsg.content, mentions: [targetNick])
        }
        
    }
    
    // Change password for current channel
    func changeChannelPassword(to newPassword: String) {
        guard let currentChannel = currentChannel else {
            let msg = BitchatMessage(
                sender: "system",
                content: "you must be in a channel to change its password.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Check if current user is the owner using fingerprint
        guard isChannelOwner(currentChannel) else {
            let msg = BitchatMessage(
                sender: "system",
                content: "only the channel owner can change the password.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Check if channel is currently password protected
        guard passwordProtectedChannels.contains(currentChannel) else {
            let msg = BitchatMessage(
                sender: "system",
                content: "channel is not password protected. use the lock button to set a password.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Store old key for re-encryption
        let oldKey = channelKeys[currentChannel]
        
        // Derive new encryption key from new password
        let newKey = deriveChannelKey(from: newPassword, channelName: currentChannel)
        channelKeys[currentChannel] = newKey
        channelPasswords[currentChannel] = newPassword
        // Update password in Keychain
        _ = KeychainManager.shared.saveChannelPassword(newPassword, for: currentChannel)
        
        // Compute new key commitment
        let newCommitment = computeKeyCommitment(for: newKey)
        channelKeyCommitments[currentChannel] = newCommitment
        
        // Save channel data
        saveChannelData()
        
        // Send password change notification with old key
        if let oldKey = oldKey {
            let changeNotice = "🔐 Password changed by channel owner. Please update your password."
            meshService.sendEncryptedChannelMessage(changeNotice, mentions: [], channel: currentChannel, channelKey: oldKey)
        }
        
        // Send new initialization message with new key
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let changeMetadata = [
            "type": "password_change",
            "channel": currentChannel,
            "changer": nickname,
            "changerID": meshService.myPeerID,
            "timestamp": timestamp,
            "version": "1.0"
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: changeMetadata)
        let metadataStr = jsonData?.base64EncodedString() ?? ""
        
        let initMessage = "🔑 Password changed | Channel \(currentChannel) password updated by \(nickname) | Metadata: \(metadataStr)"
        meshService.sendEncryptedChannelMessage(initMessage, mentions: [], channel: currentChannel, channelKey: newKey)
        
        // Announce the new commitment with fingerprint
        let myFingerprint = getMyFingerprint()
        meshService.announcePasswordProtectedChannel(currentChannel, creatorID: myFingerprint, keyCommitment: newCommitment)
        
        // Broadcast updated channel metadata
        let metadata = ChannelMetadata(
            channel: currentChannel,
            creatorID: meshService.myPeerID,
            creatorFingerprint: myFingerprint,
            isPasswordProtected: true,
            keyCommitment: newCommitment
        )
        meshService.sendChannelMetadata(metadata)
        
        // Send new password to connected channel members via Noise
        distributeChannelPasswordUpdate(channel: currentChannel, newPassword: newPassword, newCommitment: newCommitment)
        
        // Add local success message
        let successMsg = BitchatMessage(
            sender: "system",
            content: "password changed successfully. other users will need to re-enter the new password.",
            timestamp: Date(),
            isRelay: false
        )
        messages.append(successMsg)
        
    }
    
    private func distributeChannelPasswordUpdate(channel: String, newPassword: String, newCommitment: String) {
        // Get channel members
        let members = getChannelMembers(channel)
        
        // Filter to only connected members with Noise sessions
        let noiseService = meshService.getNoiseService()
        let connectedMembersWithNoise = members.filter { peerID in
            peerID != meshService.myPeerID &&
            connectedPeers.contains(peerID) &&
            noiseService.hasEstablishedSession(with: peerID)
        }
        
        // Send password update to each connected member
        for peerID in connectedMembersWithNoise {
            meshService.sendChannelPasswordUpdate(newPassword, channel: channel, newCommitment: newCommitment, to: peerID)
        }
        
        if !connectedMembersWithNoise.isEmpty {
            // Sent password update to connected members with Noise sessions
            
            // Update the success message to indicate distribution
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                let distributeMsg = BitchatMessage(
                    sender: "system",
                    content: "password update sent to \(connectedMembersWithNoise.count) online members via secure channel.",
                    timestamp: Date(),
                    isRelay: false
                )
                self?.messages.append(distributeMsg)
            }
        }
    }
    
    // Compute SHA256 hash of the derived key for public verification
    internal func computeKeyCommitment(for key: SymmetricKey) -> String {
        let keyData = key.withUnsafeBytes { Data($0) }
        let hash = SHA256.hash(data: keyData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    internal func deriveChannelKey(from password: String, channelName: String) -> SymmetricKey {
        // Get creator fingerprint for this channel
        let creatorFingerprint = channelCreators[channelName]
        
        // Use PBKDF2 with channel name + creator fingerprint as salt
        var saltComponents = "bitchat-channel-\(channelName)"
        if let fingerprint = creatorFingerprint {
            saltComponents += "-\(fingerprint)"
        }
        let salt = saltComponents.data(using: .utf8)!
        
        // Increased iterations for better security (OWASP recommends 210,000 for PBKDF2-SHA256)
        let keyData = pbkdf2(password: password, salt: salt, iterations: 210000, keyLength: 32)
        return SymmetricKey(data: keyData)
    }
    
    private func pbkdf2(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var derivedKey = Data(count: keyLength)
        let passwordData = password.data(using: .utf8)!
        
        _ = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress, passwordData.count,
                        saltBytes.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedKeyBytes.baseAddress, keyLength
                    )
                }
            }
        }
        
        return derivedKey
    }
    
    func switchToChannel(_ channel: String?) {
        // Check if channel needs password
        if let channel = channel, passwordProtectedChannels.contains(channel) && channelKeys[channel] == nil {
            // Need password, show prompt instead
            passwordPromptChannel = channel
            showPasswordPrompt = true
            return
        }
        
        currentChannel = channel
        selectedPrivateChatPeer = nil  // Exit private chat
        
        // Clear unread count for this channel
        if let channel = channel {
            unreadChannelMessages[channel] = 0
        }
    }
    
    private func sendChannelKeyVerificationRequest(for channel: String) {
        
        // Get channel members who might have the key
        let members = getChannelMembers(channel)
        
        // Filter to only connected members
        let connectedMembers = members.filter { connectedPeers.contains($0) && $0 != meshService.myPeerID }
        
        guard !connectedMembers.isEmpty else {
            channelVerificationStatus[channel] = .unverified
            return
        }
        
        // Compute our key commitment
        guard let key = channelKeys[channel] else { return }
        let commitment = computeKeyCommitment(for: key)
        
        // Create verification request
        let request = ChannelKeyVerifyRequest(
            channel: channel,
            requesterID: meshService.myPeerID,
            keyCommitment: commitment
        )
        
        // Send to all connected channel members
        meshService.sendChannelKeyVerifyRequest(request, to: connectedMembers)
        
        // Update verification status
        channelVerificationStatus[channel] = .verifying
        // Set verification status to verifying
        
        // Set timeout for verification
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            
            // Check if still verifying
            if self.channelVerificationStatus[channel] == .verifying {
                // No response received, assume unverified
                // Verification timeout
                self.channelVerificationStatus[channel] = .unverified
                
                let timeoutMsg = BitchatMessage(
                    sender: "system",
                    content: "no response from channel members. password may be correct but cannot verify at this time.",
                    timestamp: Date(),
                    isRelay: false
                )
                self.messages.append(timeoutMsg)
            }
        }
        
    }
    
    private func getChannelMembers(_ channel: String) -> [String] {
        // Return all peers who have sent messages to this channel
        return Array(channelMembers[channel] ?? [])
    }
    
    // Check if current user owns the channel (handles both legacy peer ID and new fingerprint)
    func isChannelOwner(_ channel: String) -> Bool {
        guard let creator = channelCreators[channel] else { 
            return false 
        }
        
        let myFingerprint = getMyFingerprint()
        
        
        // Only check against persistent fingerprint
        if myFingerprint != "Unknown" && creator == myFingerprint {
            return true
        }
        
        return false
    }
    
    // Migrate channel ownership from ephemeral peer IDs to persistent fingerprints
    private func cleanupLegacyChannelOwnership() {
        // Simple cleanup: only keep channels with fingerprint ownership
        let myFingerprint = getMyFingerprint()
        guard myFingerprint != "Unknown" else { return }
        
        var cleaned = false
        for (channel, creator) in channelCreators {
            // Remove any channel with 8-char creator ID (legacy)
            if creator.count == 8 {
                // Removing legacy ownership
                channelCreators.removeValue(forKey: channel)
                cleaned = true
            }
        }
        
        if cleaned {
            saveChannelData()
        }
    }
    
    
    func getChannelMessages(_ channel: String) -> [BitchatMessage] {
        return channelMessages[channel] ?? []
    }
    
    func parseChannels(from content: String) -> Set<String> {
        let pattern = "#([a-zA-Z0-9_]+)"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let matches = regex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        
        var channels = Set<String>()
        for match in matches {
            if let range = Range(match.range(at: 0), in: content) {
                let channel = String(content[range])
                channels.insert(channel)
            }
        }
        
        return channels
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
            // Parse mentions and channels from the content
            let mentions = parseMentions(from: content)
            let channels = parseChannels(from: content)
            
            // Auto-join any channels mentioned in the message
            for channel in channels {
                if !joinedChannels.contains(channel) {
                    let _ = joinChannel(channel)
                }
            }
            
            // Determine which channel this message belongs to
            let messageChannel = currentChannel  // Use current channel if we're in one
            
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
                channel: messageChannel
            )
            
            if let channel = messageChannel {
                // Add to channel messages
                if channelMessages[channel] == nil {
                    channelMessages[channel] = []
                }
                channelMessages[channel]?.append(message)
                
                // Save message if channel has retention enabled
                if retentionEnabledChannels.contains(channel) {
                    MessageRetentionService.shared.saveMessage(message, forChannel: channel)
                }
                
                // Track ourselves as a channel member
                if channelMembers[channel] == nil {
                    channelMembers[channel] = Set()
                }
                channelMembers[channel]?.insert(meshService.myPeerID)
            } else {
                // Add to main messages
                messages.append(message)
            }
            
            // Only auto-join channels if we're sending TO that channel
            if let messageChannel = messageChannel {
                if !joinedChannels.contains(messageChannel) {
                    let _ = joinChannel(messageChannel)
                }
            }
            
            // Check if channel is password protected and encrypt if needed
            if let channel = messageChannel, channelKeys[channel] != nil {
                // Send encrypted channel message
                meshService.sendEncryptedChannelMessage(content, mentions: mentions, channel: channel, channelKey: channelKeys[channel]!)
            } else {
                // Send via mesh with mentions and channel (unencrypted)
                meshService.sendMessage(content, mentions: mentions, channel: messageChannel)
            }
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
        
        // Track the message for delivery confirmation
        let isFavorite = isFavorite(peerID: peerID)
        DeliveryTracker.shared.trackMessage(message, recipientID: peerID, recipientNickname: recipientNickname, isFavorite: isFavorite)
        
        // Trigger UI update
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
            
        } else if let channel = currentChannel {
            // In a channel - send to channel
            // Check if channel is password protected and encrypt if needed
            if let channelKey = channelKeys[channel] {
                meshService.sendEncryptedChannelMessage(screenshotMessage, mentions: [], channel: channel, channelKey: channelKey)
            } else {
                meshService.sendMessage(screenshotMessage, mentions: [], channel: channel)
            }
            
            // Show local notification immediately as system message
            let localNotification = BitchatMessage(
                sender: "system",
                content: "you took a screenshot",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                channel: channel
            )
            if channelMessages[channel] == nil {
                channelMessages[channel] = []
            }
            channelMessages[channel]?.append(localNotification)
            
        } else {
            // In public chat - send to everyone
            meshService.sendMessage(screenshotMessage, mentions: [], channel: nil)
            
            // Show local notification immediately as system message
            let localNotification = BitchatMessage(
                sender: "system",
                content: "you took a screenshot",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(localNotification)
        }
    }
    
    @objc private func appWillResignActive() {
        // Save all channel data
        saveChannelData()
        userDefaults.synchronize()
    }
    
    @objc func applicationWillTerminate() {
        
        // Verify identity key is still there
        _ = KeychainManager.shared.verifyIdentityKeyExists()
        
        // Save all channel data
        saveChannelData()
        userDefaults.synchronize()
        
        // Verify identity key after save
        _ = KeychainManager.shared.verifyIdentityKeyExists()
    }
    
    @objc private func appWillTerminate() {
        // Save all channel data
        saveChannelData()
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
        // Clear all messages
        messages.removeAll()
        privateChats.removeAll()
        unreadPrivateMessages.removeAll()
        
        // Clear all channel data
        joinedChannels.removeAll()
        currentChannel = nil
        channelMessages.removeAll()
        unreadChannelMessages.removeAll()
        channelMembers.removeAll()
        channelPasswords.removeAll()
        channelKeys.removeAll()
        passwordProtectedChannels.removeAll()
        channelCreators.removeAll()
        channelKeyCommitments.removeAll()
        showPasswordPrompt = false
        passwordPromptChannel = nil
        
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
        
        // Clear all retained messages
        MessageRetentionService.shared.deleteAllStoredMessages()
        savedChannels.removeAll()
        retentionEnabledChannels.removeAll()
        
        // Clear message retry queue
        MessageRetryService.shared.clearRetryQueue()
        
        // Clear persisted channel data from UserDefaults
        userDefaults.removeObject(forKey: joinedChannelsKey)
        userDefaults.removeObject(forKey: passwordProtectedChannelsKey)
        userDefaults.removeObject(forKey: channelCreatorsKey)
        userDefaults.removeObject(forKey: channelKeyCommitmentsKey)
        userDefaults.removeObject(forKey: retentionEnabledChannelsKey)
        
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
        // RSSI typically ranges from -30 (excellent) to -90 (poor)
        // We'll map this to colors from green (strong) to red (weak)
        
        if rssi >= -50 {
            // Excellent signal: bright green
            return isDark ? Color(red: 0.0, green: 1.0, blue: 0.0) : Color(red: 0.0, green: 0.7, blue: 0.0)
        } else if rssi >= -60 {
            // Good signal: green-yellow
            return isDark ? Color(red: 0.5, green: 1.0, blue: 0.0) : Color(red: 0.3, green: 0.7, blue: 0.0)
        } else if rssi >= -70 {
            // Fair signal: yellow
            return isDark ? Color(red: 1.0, green: 1.0, blue: 0.0) : Color(red: 0.7, green: 0.7, blue: 0.0)
        } else if rssi >= -80 {
            // Weak signal: orange
            return isDark ? Color(red: 1.0, green: 0.6, blue: 0.0) : Color(red: 0.8, green: 0.4, blue: 0.0)
        } else {
            // Poor signal: red
            return isDark ? Color(red: 1.0, green: 0.2, blue: 0.2) : Color(red: 0.8, green: 0.0, blue: 0.0)
        }
    }
    
    func updateAutocomplete(for text: String, cursorPosition: Int) {
        // Find @ symbol before cursor
        let beforeCursor = String(text.prefix(cursorPosition))
        
        // Look for @ pattern
        let pattern = "@([a-zA-Z0-9_]*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: beforeCursor, options: [], range: NSRange(location: 0, length: beforeCursor.count)) else {
            showAutocomplete = false
            autocompleteSuggestions = []
            autocompleteRange = nil
            return
        }
        
        // Extract the partial nickname
        let partialRange = match.range(at: 1)
        guard let range = Range(partialRange, in: beforeCursor) else {
            showAutocomplete = false
            autocompleteSuggestions = []
            autocompleteRange = nil
            return
        }
        
        let partial = String(beforeCursor[range]).lowercased()
        
        // Get all available nicknames (excluding self)
        let peerNicknames = meshService.getPeerNicknames()
        let allNicknames = Array(peerNicknames.values)
        
        // Filter suggestions
        let suggestions = allNicknames.filter { nick in
            nick.lowercased().hasPrefix(partial)
        }.sorted()
        
        if !suggestions.isEmpty {
            autocompleteSuggestions = suggestions
            showAutocomplete = true
            autocompleteRange = match.range(at: 0) // Store full @mention range
            selectedAutocompleteIndex = 0
        } else {
            showAutocomplete = false
            autocompleteSuggestions = []
            autocompleteRange = nil
            selectedAutocompleteIndex = 0
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
        
        if message.sender == nickname {
            return primaryColor
        } else if let peerID = message.senderPeerID ?? getPeerIDForNickname(message.sender),
                  let rssi = meshService.getPeerRSSI()[peerID] {
            return getRSSIColor(rssi: rssi.intValue, colorScheme: colorScheme)
        } else {
            return primaryColor.opacity(0.9)
        }
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
        var result = AttributedString()
        
        let isDark = colorScheme == .dark
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
            
            // Get sender color
            let senderColor: Color
            if message.sender == nickname {
                senderColor = primaryColor
            } else if let peerID = message.senderPeerID ?? getPeerIDForNickname(message.sender),
                      let rssi = meshService.getPeerRSSI()[peerID] {
                senderColor = getRSSIColor(rssi: rssi.intValue, colorScheme: colorScheme)
            } else {
                senderColor = primaryColor.opacity(0.9)
            }
            
            senderStyle.foregroundColor = senderColor
            senderStyle.font = .system(size: 14, weight: .medium, design: .monospaced)
            result.append(sender.mergingAttributes(senderStyle))
            
            // Process content with hashtags, mentions, and markdown links
            var content = message.content
            
            // First, check if content starts with 👇 followed by markdown link
            if content.hasPrefix("👇 [") {
                // This is a URL share - remove everything after the emoji
                if let linkStart = content.firstIndex(of: "[") {
                    let indexBeforeLink = content.index(before: linkStart)
                    content = String(content[..<indexBeforeLink])
                }
            } else {
                // Handle normal markdown links
                let markdownLinkPattern = #"\[([^\]]+)\]\(([^)]+)\)"#
                if let markdownRegex = try? NSRegularExpression(pattern: markdownLinkPattern, options: []) {
                    let markdownMatches = markdownRegex.matches(in: content, options: [], range: NSRange(location: 0, length: content.count))
                    
                    // Process matches in reverse order to maintain string indices
                    for match in markdownMatches.reversed() {
                        if let fullRange = Range(match.range, in: content),
                           let titleRange = Range(match.range(at: 1), in: content) {
                            // Normal markdown link - replace with just the title
                            let linkTitle = String(content[titleRange])
                            content.replaceSubrange(fullRange, with: linkTitle)
                        }
                    }
                }
            }
            
            let hashtagPattern = "#([a-zA-Z0-9_]+)"
            let mentionPattern = "@([a-zA-Z0-9_]+)"
            
            let hashtagRegex = try? NSRegularExpression(pattern: hashtagPattern, options: [])
            let mentionRegex = try? NSRegularExpression(pattern: mentionPattern, options: [])
            
            let hashtagMatches = hashtagRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            let mentionMatches = mentionRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
            
            // Combine and sort matches
            var allMatches: [(range: NSRange, type: String)] = []
            for match in hashtagMatches {
                allMatches.append((match.range(at: 0), "hashtag"))
            }
            for match in mentionMatches {
                allMatches.append((match.range(at: 0), "mention"))
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
            let content = AttributedString("* \(message.content) *")
            var contentStyle = AttributeContainer()
            // Check for welcome message
            if message.content.contains("get people around you to download bitchat") {
                contentStyle.foregroundColor = Color.blue
            } else {
                contentStyle.foregroundColor = Color.gray
            }
            contentStyle.font = .system(size: 12, design: .monospaced).italic()
            result.append(content.mergingAttributes(contentStyle))
        }
        
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
            
            // Get RSSI-based color
            let senderColor: Color
            if message.sender == nickname {
                senderColor = primaryColor
            } else if let peerID = message.senderPeerID ?? getPeerIDForNickname(message.sender),
                      let rssi = meshService.getPeerRSSI()[peerID] {
                senderColor = getRSSIColor(rssi: rssi.intValue, colorScheme: colorScheme)
            } else {
                senderColor = primaryColor.opacity(0.9)
            }
            
            senderStyle.foregroundColor = senderColor
            senderStyle.font = .system(size: 12, weight: .medium, design: .monospaced)
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
        let noiseService = meshService.getNoiseService()
        
        for peerID in connectedPeers {
            if noiseService.hasEstablishedSession(with: peerID) {
                // Check if fingerprint is verified using our persisted data
                if let fingerprint = noiseService.getPeerFingerprint(peerID),
                   verifiedFingerprints.contains(fingerprint) {
                    peerEncryptionStatus[peerID] = .noiseVerified
                } else {
                    peerEncryptionStatus[peerID] = .noiseSecured
                }
            } else {
                // Always use Noise - no legacy encryption
                peerEncryptionStatus[peerID] = .noiseHandshaking
            }
        }
    }
    
    func getEncryptionStatus(for peerID: String) -> EncryptionStatus {
        // This must be a pure function - no state mutations allowed
        // to avoid SwiftUI update loops
        
        // Check if we have a fingerprint for this peer
        if let fingerprint = getFingerprint(for: peerID) {
            // Check if this fingerprint is verified
            if verifiedFingerprints.contains(fingerprint) {
                // Return verified if we have a Noise session
                if meshService.getNoiseService().hasEstablishedSession(with: peerID) {
                    return .noiseVerified
                }
            } else if meshService.getNoiseService().hasEstablishedSession(with: peerID) {
                return .noiseSecured
            }
        }
        
        // Fall back to stored status
        return peerEncryptionStatus[peerID] ?? .none
    }
    
    // Update encryption status in appropriate places, not during view updates
    private func updateEncryptionStatus(for peerID: String) {
        if let fingerprint = getFingerprint(for: peerID) {
            if verifiedFingerprints.contains(fingerprint) && meshService.getNoiseService().hasEstablishedSession(with: peerID) {
                peerEncryptionStatus[peerID] = .noiseVerified
            } else if meshService.getNoiseService().hasEstablishedSession(with: peerID) {
                peerEncryptionStatus[peerID] = .noiseSecured
            }
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
                // Update encryption status
                if self?.verifiedFingerprints.contains(fingerprint) == true {
                    self?.peerEncryptionStatus[peerID] = .noiseVerified
                } else {
                    self?.peerEncryptionStatus[peerID] = .noiseSecured
                }
                
                // Log for testing
                #if DEBUG
                NoiseTestingHelper.shared.logNoiseEvent("Peer authenticated", details: "PeerID: \(peerID), Fingerprint: \(fingerprint)")
                #endif
            }
        }
        
        // Set up handshake required callback
        noiseService.onHandshakeRequired = { [weak self] peerID in
            DispatchQueue.main.async {
                self?.peerEncryptionStatus[peerID] = .noiseHandshaking
                
                #if DEBUG
                NoiseTestingHelper.shared.logNoiseEvent("Handshake required", details: "PeerID: \(peerID)")
                #endif
            }
        }
    }
}

extension ChatViewModel: BitchatDelegate {
    func didReceiveChannelLeave(_ channel: String, from peerID: String) {
        // Remove peer from channel members
        if channelMembers[channel] != nil {
            channelMembers[channel]?.remove(peerID)
            
            // Force UI update
            objectWillChange.send()
        }
    }
    
    func didReceivePasswordProtectedChannelAnnouncement(_ channel: String, isProtected: Bool, creatorID: String?, keyCommitment: String?) {
        let wasAlreadyProtected = passwordProtectedChannels.contains(channel)
        
        if isProtected {
            passwordProtectedChannels.insert(channel)
            if let creator = creatorID {
                // Don't overwrite our own ownership
                let myFingerprint = getMyFingerprint()
                if channelCreators[channel] == nil || 
                   (channelCreators[channel] != meshService.myPeerID && channelCreators[channel] != myFingerprint) {
                    channelCreators[channel] = creator
                    // Received creator announcement
                }
            }
            
            // Store the key commitment if provided
            if let commitment = keyCommitment {
                channelKeyCommitments[channel] = commitment
            }
            
            // If we just learned this channel is protected and we're in it without a key, prompt for password
            if !wasAlreadyProtected && joinedChannels.contains(channel) && channelKeys[channel] == nil {
                
                // Add system message
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "channel \(channel) is password protected. you need the password to participate.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
                
                // If currently viewing this channel, show password prompt
                if currentChannel == channel {
                    passwordPromptChannel = channel
                    showPasswordPrompt = true
                }
            }
        } else {
            passwordProtectedChannels.remove(channel)
            // If we're in this channel and it's no longer protected, clear the key
            channelKeys.removeValue(forKey: channel)
            channelPasswords.removeValue(forKey: channel)
            channelKeyCommitments.removeValue(forKey: channel)
        }
        
        // Save updated channel data
        saveChannelData()
        
    }
    
    func decryptChannelMessage(_ encryptedContent: Data, channel: String, testKey: SymmetricKey? = nil) -> String? {
        let key = testKey ?? channelKeys[channel]
        guard let key = key else {
            return nil
        }
        
        // Debug logging removed
        
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedContent)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            let decryptedString = String(data: decryptedData, encoding: .utf8)
            return decryptedString
        } catch {
            return nil
        }
    }
    
    func didReceiveChannelRetentionAnnouncement(_ channel: String, enabled: Bool, creatorID: String?) {
        
        // Only process if we're a member of this channel
        guard joinedChannels.contains(channel) else { return }
        
        // Verify the announcement is from the channel owner
        if let creatorID = creatorID, channelCreators[channel] != creatorID {
            return
        }
        
        // Update retention status
        if enabled {
            retentionEnabledChannels.insert(channel)
            savedChannels.insert(channel)
            // Ensure channel is in favorites if not already
            if !MessageRetentionService.shared.getFavoriteChannels().contains(channel) {
                _ = MessageRetentionService.shared.toggleFavoriteChannel(channel)
            }
            
            // Show system message
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "channel owner enabled message retention for \(channel). all messages will be saved locally.",
                timestamp: Date(),
                isRelay: false
            )
            if currentChannel == channel {
                messages.append(systemMessage)
            } else if var channelMsgs = channelMessages[channel] {
                channelMsgs.append(systemMessage)
                channelMessages[channel] = channelMsgs
            } else {
                channelMessages[channel] = [systemMessage]
            }
        } else {
            retentionEnabledChannels.remove(channel)
            savedChannels.remove(channel)
            
            // Delete all saved messages for this channel
            MessageRetentionService.shared.deleteMessagesForChannel(channel)
            // Remove from favorites if currently set
            if MessageRetentionService.shared.getFavoriteChannels().contains(channel) {
                _ = MessageRetentionService.shared.toggleFavoriteChannel(channel)
            }
            
            // Show system message
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "channel owner disabled message retention for \(channel). all saved messages have been deleted.",
                timestamp: Date(),
                isRelay: false
            )
            if currentChannel == channel {
                messages.append(systemMessage)
            } else if var channelMsgs = channelMessages[channel] {
                channelMsgs.append(systemMessage)
                channelMessages[channel] = channelMsgs
            } else {
                channelMessages[channel] = [systemMessage]
            }
        }
        
        // Persist retention status
        userDefaults.set(Array(retentionEnabledChannels), forKey: retentionEnabledChannelsKey)
    }
    
    private func handleCommand(_ command: String) {
        let parts = command.split(separator: " ")
        guard let cmd = parts.first else { return }
        
        switch cmd {
        case "/j", "/join":
            if parts.count > 1 {
                let channelName = String(parts[1])
                // Ensure channel name starts with #
                let channel = channelName.hasPrefix("#") ? channelName : "#\(channelName)"
                
                // Validate channel name
                let cleanedName = channel.dropFirst()
                let isValidName = !cleanedName.isEmpty && cleanedName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
                
                if !isValidName {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "invalid channel name. use only letters, numbers, and underscores.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                } else {
                    let wasAlreadyJoined = joinedChannels.contains(channel)
                    let wasPasswordProtected = passwordProtectedChannels.contains(channel)
                    let hadCreator = channelCreators[channel] != nil
                    
                    let success = joinChannel(channel)
                    
                    if success {
                        if !wasAlreadyJoined {
                            var message = "joined channel \(channel)"
                            if !hadCreator && !wasPasswordProtected {
                                message += " (created new channel - you are the owner)"
                            }
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: message,
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                        } else {
                            // Already in channel, just switched to it
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "switched to channel \(channel)",
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                        }
                    }
                    // If not successful, password prompt will be shown
                }
            } else {
                // Show usage hint
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /j #channelname",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
        case "/create":
            // /create is now just an alias for /join
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "use /join #channelname to join or create a channel",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(systemMessage)
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
        case "/channels":
            // Discover all channels (both joined and not joined)
            var allChannels: Set<String> = Set()
            
            // Add joined channels
            allChannels.formUnion(joinedChannels)
            
            // Find channels from messages we've seen
            for msg in messages {
                if let channel = msg.channel {
                    allChannels.insert(channel)
                }
            }
            
            // Also check channel messages we've cached
            for (channel, _) in channelMessages {
                allChannels.insert(channel)
            }
            
            // Add password protected channels we know about
            allChannels.formUnion(passwordProtectedChannels)
            
            if allChannels.isEmpty {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "no channels discovered yet. channels appear as people use them.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            } else {
                let channelList = allChannels.sorted().map { channel in
                    var status = ""
                    if joinedChannels.contains(channel) {
                        status += " ✓"
                    }
                    if passwordProtectedChannels.contains(channel) {
                        status += " 🔒"
                    }
                    if retentionEnabledChannels.contains(channel) {
                        status += " 📌"
                    }
                    let myFingerprint = getMyFingerprint()
                    if channelCreators[channel] == meshService.myPeerID || channelCreators[channel] == myFingerprint {
                        status += " (owner)"
                    }
                    return "\(channel)\(status)"
                }.joined(separator: "\n")
                
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "discovered channels:\n\(channelList)\n\n✓ = joined, 🔒 = password protected, 📌 = retention enabled",
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
        case "/transfer":
            // Transfer channel ownership
            let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count < 2 {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /transfer @nickname",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            } else {
                transferChannelOwnership(to: parts[1])
            }
        case "/pass":
            // Change channel password (only available in channels)
            guard currentChannel != nil else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "you must be in a channel to use /pass.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
                break
            }
            let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count < 2 {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /pass <new password>",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            } else {
                changeChannelPassword(to: parts[1])
            }
        case "/clear":
            // Clear messages based on current context
            if let channel = currentChannel {
                // Clear channel messages
                channelMessages[channel]?.removeAll()
            } else if let peerID = selectedPrivateChatPeer {
                // Clear private chat
                privateChats[peerID]?.removeAll()
            } else {
                // Clear main messages
                messages.removeAll()
            }
        case "/save":
            // Toggle retention for current channel (owner only)
            guard let channel = currentChannel else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "you must be in a channel to toggle message retention.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
                break
            }
            
            // Check if user is the channel owner
            let myFingerprint = getMyFingerprint()
            guard channelCreators[channel] == meshService.myPeerID || channelCreators[channel] == myFingerprint else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "only the channel owner can toggle message retention.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
                break
            }
            
            // Toggle retention status
            let isEnabling = !retentionEnabledChannels.contains(channel)
            
            if isEnabling {
                // Enable retention for this channel
                retentionEnabledChannels.insert(channel)
                savedChannels.insert(channel)
                _ = MessageRetentionService.shared.toggleFavoriteChannel(channel) // Enable if not already
                
                // Announce to all members that retention is enabled
                meshService.sendChannelRetentionAnnouncement(channel, enabled: true)
                
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "message retention enabled for channel \(channel). all members will save messages locally.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
                
                // Load any previously saved messages
                let savedMessages = MessageRetentionService.shared.loadMessagesForChannel(channel)
                if !savedMessages.isEmpty {
                    // Merge saved messages with current messages, avoiding duplicates
                    var existingMessageIDs = Set(channelMessages[channel]?.map { $0.id } ?? [])
                    for savedMessage in savedMessages {
                        if !existingMessageIDs.contains(savedMessage.id) {
                            if channelMessages[channel] == nil {
                                channelMessages[channel] = []
                            }
                            channelMessages[channel]?.append(savedMessage)
                            existingMessageIDs.insert(savedMessage.id)
                        }
                    }
                    // Sort by timestamp
                    channelMessages[channel]?.sort { $0.timestamp < $1.timestamp }
                }
            } else {
                // Disable retention for this channel
                retentionEnabledChannels.remove(channel)
                savedChannels.remove(channel)
                
                // Delete all saved messages for this channel
                MessageRetentionService.shared.deleteMessagesForChannel(channel)
                _ = MessageRetentionService.shared.toggleFavoriteChannel(channel) // Disable if enabled
                
                // Announce to all members that retention is disabled
                meshService.sendChannelRetentionAnnouncement(channel, enabled: false)
                
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "message retention disabled for channel \(channel). all saved messages will be deleted on all devices.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
            
            // Save the updated channel data
            saveChannelData()
        case "/debug":
            // Debug command to check ownership info
            if let channel = currentChannel {
                let myPeerID = meshService.myPeerID
                let myFingerprint = getMyFingerprint()
                let creator = channelCreators[channel] ?? "unknown"
                let isOwner = isChannelOwner(channel)
                
                let debugInfo = """
                    🐛 Debug Info for \(channel):
                    • Channel creator: \(creator)
                    • My peer ID: \(myPeerID)
                    • My fingerprint: \(myFingerprint)
                    • Am I owner? \(isOwner ? "YES" : "NO")
                    • All creators: \(channelCreators)
                    """
                
                let debugMsg = BitchatMessage(
                    sender: "system",
                    content: debugInfo,
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(debugMsg)
            } else {
                let debugMsg = BitchatMessage(
                    sender: "system",
                    content: "use /debug in a channel to see ownership info",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(debugMsg)
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
                        senderPeerID: meshService.myPeerID,
                        channel: currentChannel
                    )
                    
                    // Send as a regular message but it will be displayed as system message due to content
                    let hugContent = "* 🫂 \(self.nickname) hugs \(nickname) *"
                    if let channel = currentChannel {
                        meshService.sendMessage(hugContent, channel: channel)
                        // Add to channel messages
                        if channelMessages[channel] == nil {
                            channelMessages[channel] = []
                        }
                        channelMessages[channel]?.append(hugMessage)
                    } else if selectedPrivateChatPeer != nil {
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
                        senderPeerID: meshService.myPeerID,
                        channel: currentChannel
                    )
                    
                    // Send as a regular message but it will be displayed as system message due to content
                    let slapContent = "* 🐟 \(self.nickname) slaps \(nickname) around a bit with a large trout *"
                    if let channel = currentChannel {
                        meshService.sendMessage(slapContent, channel: channel)
                        // Add to channel messages
                        if channelMessages[channel] == nil {
                            channelMessages[channel] = []
                        }
                        channelMessages[channel]?.append(slapMessage)
                    } else if selectedPrivateChatPeer != nil {
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
        
        // Track sender as a channel member if this is a channel message
        if let channel = message.channel, let senderPeerID = message.senderPeerID {
            if channelMembers[channel] == nil {
                channelMembers[channel] = Set()
            }
            channelMembers[channel]?.insert(senderPeerID)
        }
        
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
                        channel: messageToStore.channel,
                        deliveryStatus: messageToStore.deliveryStatus
                    )
                }
                
                privateChats[peerID]?.append(messageToStore)
                // Sort messages by timestamp to ensure proper ordering
                privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                
                // Debug logging
                
                // Trigger UI update for private chats
                objectWillChange.send()
                
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
        } else if let channel = message.channel {
            // Channel message
            
            // Only process channel messages if we've joined this channel
            if joinedChannels.contains(channel) {
                // Prepare the message to add (might be updated if decryption succeeds)
                var messageToAdd = message
                
                // Check if this is an encrypted message and we don't have the key
                if message.isEncrypted && channelKeys[channel] == nil {
                    // Mark channel as password protected if not already
                    let wasNewlyDiscovered = !passwordProtectedChannels.contains(channel)
                    if wasNewlyDiscovered {
                        passwordProtectedChannels.insert(channel)
                        saveChannelData()
                        
                        // Add a system message to indicate the channel is password protected (only once)
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "channel \(channel) is password protected. you need the password to read messages.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        if channelMessages[channel] == nil {
                            channelMessages[channel] = []
                        }
                        channelMessages[channel]?.append(systemMessage)
                    }
                    
                    // If we're currently viewing this channel, prompt for password
                    if currentChannel == channel {
                        passwordPromptChannel = channel
                        showPasswordPrompt = true
                    }
                } else if message.isEncrypted && channelKeys[channel] != nil && message.content == "[Encrypted message - password required]" {
                    // We have a key but the message shows as encrypted - try to decrypt it again
                    
                    // Check if this is the first encrypted message in the channel (password verification opportunity)
                    let isFirstEncryptedMessage = channelMessages[channel]?.filter { $0.isEncrypted }.isEmpty ?? true
                    
                    if let encryptedData = message.encryptedContent {
                        if let decryptedContent = decryptChannelMessage(encryptedData, channel: channel) {
                            // Successfully decrypted - update the message content
                            
                            if isFirstEncryptedMessage {
                                
                                // Add success message
                                let verifiedMsg = BitchatMessage(
                                    sender: "system",
                                    content: "password verified successfully for channel \(channel).",
                                    timestamp: Date(),
                                    isRelay: false
                                )
                                messages.append(verifiedMsg)
                            }
                            
                            // Create a new message with decrypted content
                            let decryptedMessage = BitchatMessage(
                                sender: message.sender,
                                content: decryptedContent,
                                timestamp: message.timestamp,
                                isRelay: message.isRelay,
                                originalSender: message.originalSender,
                                isPrivate: message.isPrivate,
                                recipientNickname: message.recipientNickname,
                                senderPeerID: message.senderPeerID,
                                mentions: message.mentions,
                                channel: message.channel,
                                encryptedContent: message.encryptedContent,
                                isEncrypted: message.isEncrypted
                            )
                            
                            // Update the message we'll add
                            messageToAdd = decryptedMessage
                        } else {
                            // Decryption really failed - wrong password
                            
                            // Clear the wrong password
                            channelKeys.removeValue(forKey: channel)
                            channelPasswords.removeValue(forKey: channel)
                            
                            // If this was the first encrypted message, we need to kick the user out
                            if isFirstEncryptedMessage {
                                
                                // Leave the channel
                                joinedChannels.remove(channel)
                                saveJoinedChannels()
                                
                                // Clear channel data
                                channelMessages.removeValue(forKey: channel)
                                channelMembers.removeValue(forKey: channel)
                                unreadChannelMessages.removeValue(forKey: channel)
                                
                                // If we're currently in this channel, exit to main
                                if currentChannel == channel {
                                    currentChannel = nil
                                }
                                
                                // Add error message
                                let errorMsg = BitchatMessage(
                                    sender: "system",
                                    content: "wrong password for channel \(channel). you have been removed from the channel.",
                                    timestamp: Date(),
                                    isRelay: false
                                )
                                messages.append(errorMsg)
                                
                                // Don't show password prompt - user needs to rejoin
                                return
                            }
                            
                            // Add system message for subsequent failures
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "wrong password for channel \(channel). please enter the correct password.",
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                            
                            // Show password prompt again
                            if currentChannel == channel {
                                passwordPromptChannel = channel
                                showPasswordPrompt = true
                            }
                        }
                    }
                }
                
                // Check if this is an action that should be converted to system message
                let isActionMessage = messageToAdd.content.hasPrefix("* ") && messageToAdd.content.hasSuffix(" *") &&
                                      (messageToAdd.content.contains("🫂") || messageToAdd.content.contains("🐟") || 
                                       messageToAdd.content.contains("took a screenshot"))
                
                let finalMessage: BitchatMessage
                if isActionMessage {
                    // Convert to system message
                    finalMessage = BitchatMessage(
                        sender: "system",
                        content: String(messageToAdd.content.dropFirst(2).dropLast(2)), // Remove * * wrapper
                        timestamp: messageToAdd.timestamp,
                        isRelay: messageToAdd.isRelay,
                        originalSender: messageToAdd.originalSender,
                        isPrivate: false,
                        recipientNickname: messageToAdd.recipientNickname,
                        senderPeerID: messageToAdd.senderPeerID,
                        mentions: messageToAdd.mentions,
                        channel: messageToAdd.channel
                    )
                } else {
                    finalMessage = messageToAdd
                }
                
                // Add to channel messages (using potentially decrypted version)
                if channelMessages[channel] == nil {
                    channelMessages[channel] = []
                }
                
                // Check if this is our own message being echoed back
                if finalMessage.sender != nickname && finalMessage.sender != "system" {
                    // Skip empty or whitespace-only messages
                    if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        channelMessages[channel]?.append(finalMessage)
                        channelMessages[channel]?.sort { $0.timestamp < $1.timestamp }
                    }
                } else if finalMessage.sender != "system" {
                    // Our own message - check if we already have it (by ID and content)
                    let messageExists = channelMessages[channel]?.contains { existingMsg in
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
                    } ?? false
                    if !messageExists {
                        // This is a message we sent from another device or it's missing locally
                        // Skip empty or whitespace-only messages
                        if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            channelMessages[channel]?.append(finalMessage)
                            channelMessages[channel]?.sort { $0.timestamp < $1.timestamp }
                        }
                    }
                } else {
                    // System message - always add
                    channelMessages[channel]?.append(finalMessage)
                    channelMessages[channel]?.sort { $0.timestamp < $1.timestamp }
                }
                
                // Save message if channel has retention enabled
                if retentionEnabledChannels.contains(channel) {
                    MessageRetentionService.shared.saveMessage(messageToAdd, forChannel: channel)
                }
                
                // Track channel members - only track the sender as a member
                if channelMembers[channel] == nil {
                    channelMembers[channel] = Set()
                }
                if let senderPeerID = message.senderPeerID {
                    channelMembers[channel]?.insert(senderPeerID)
                } else {
                }
                
                // Update unread count if not currently viewing this channel and it's not our own message
                if currentChannel != channel && finalMessage.sender != nickname {
                    unreadChannelMessages[channel] = (unreadChannelMessages[channel] ?? 0) + 1
                }
            } else {
                // We're not in this channel, ignore the message
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
                    mentions: message.mentions,
                    channel: message.channel
                )
            } else {
                finalMessage = message
            }
            
            // Check if this is our own message being echoed back
            if finalMessage.sender != nickname && finalMessage.sender != "system" {
                // Skip empty or whitespace-only messages
                if !finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.append(finalMessage)
                    // Sort messages by timestamp to ensure proper ordering
                    messages.sort { $0.timestamp < $1.timestamp }
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
                        messages.append(finalMessage)
                        messages.sort { $0.timestamp < $1.timestamp }
                    }
                }
            } else {
                // System message - always add
                messages.append(finalMessage)
                messages.sort { $0.timestamp < $1.timestamp }
            }
        }
        
        // Check if we're mentioned
        let isMentioned = message.mentions?.contains(nickname) ?? false
        
        // Send notifications for mentions and private messages when app is in background
        if isMentioned && message.sender != nickname {
            NotificationService.shared.sendMentionNotification(from: message.sender, message: message.content)
        } else if message.isPrivate && message.sender != nickname {
            NotificationService.shared.sendPrivateMessageNotification(from: message.sender, message: message.content)
        }
        
        #if os(iOS)
        // Haptic feedback for iOS only
        
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
        
        let systemMessage = BitchatMessage(
            sender: "system",
            content: "\(displayName) connected",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil
        )
        messages.append(systemMessage)
        
        // Force UI update
        objectWillChange.send()
    }
    
    func didDisconnectFromPeer(_ peerID: String) {
        // Remove ephemeral session from identity manager
        SecureIdentityStateManager.shared.removeEphemeralSession(peerID: peerID)
        
        // Resolve nickname using helper
        let displayName = resolveNickname(for: peerID)
        
        let systemMessage = BitchatMessage(
            sender: "system",
            content: "\(displayName) disconnected",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil
        )
        messages.append(systemMessage)
        
        // Force UI update
        objectWillChange.send()
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

            // Clean up channel members who disconnected
            for (channel, memberIDs) in self.channelMembers {
                let activeMembers = memberIDs.filter { memberID in
                    memberID == self.meshService.myPeerID || peers.contains(memberID)
                }
                if activeMembers != memberIDs {
                    self.channelMembers[channel] = activeMembers
                }
            }
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
                var updatedMessage = messages[index]
                updatedMessage.deliveryStatus = status
                messages[index] = updatedMessage
            }
        }
        
        // Update in private chats
        var updatedPrivateChats = privateChats
        for (peerID, var chatMessages) in updatedPrivateChats {
            if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                let currentStatus = chatMessages[index].deliveryStatus
                if !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) {
                    var updatedMessage = chatMessages[index]
                    updatedMessage.deliveryStatus = status
                    chatMessages[index] = updatedMessage
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
        
        // Update in channel messages
        for (channel, var channelMsgs) in channelMessages {
            if let index = channelMsgs.firstIndex(where: { $0.id == messageID }) {
                let currentStatus = channelMsgs[index].deliveryStatus
                if !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) {
                    var updatedMessage = channelMsgs[index]
                    updatedMessage.deliveryStatus = status
                    channelMsgs[index] = updatedMessage
                    channelMessages[channel] = channelMsgs
                    
                    // Force UI update
                    DispatchQueue.main.async { [weak self] in
                        self?.objectWillChange.send()
                    }
                }
            }
        }
    }
    
    // MARK: - Channel Key Verification
    
    func didReceiveChannelKeyVerifyRequest(_ request: ChannelKeyVerifyRequest, from peerID: String) {
        
        // Check if we have the key for this channel
        guard let myKey = channelKeys[request.channel] else {
            // We don't have the key, can't verify
            return
        }
        
        // Compute our key commitment
        let myCommitment = computeKeyCommitment(for: myKey)
        
        // Check if their commitment matches ours
        let verified = (myCommitment == request.keyCommitment)
        
        // Send response
        let response = ChannelKeyVerifyResponse(
            channel: request.channel,
            responderID: meshService.myPeerID,
            verified: verified
        )
        
        meshService.sendChannelKeyVerifyResponse(response, to: peerID)
        
        // If they have the wrong key, they might need the new password
        let myFingerprint = getMyFingerprint()
        if !verified && (channelCreators[request.channel] == meshService.myPeerID || channelCreators[request.channel] == myFingerprint) {
            // We're the owner and they have wrong key - could offer to send update
        }
    }
    
    func didReceiveChannelKeyVerifyResponse(_ response: ChannelKeyVerifyResponse, from peerID: String) {
        
        if response.verified {
            // Our key was verified - we have the correct password
            
            // Update verification status
            channelVerificationStatus[response.channel] = .verified
            
            // Mark channel as successfully joined
            if joinedChannels.contains(response.channel) {
                // Update UI to show successful verification
                DispatchQueue.main.async { [weak self] in
                    self?.objectWillChange.send()
                }
            }
        } else {
            // Our key was rejected - we have the wrong password
            
            // Update verification status
            channelVerificationStatus[response.channel] = .failed
            
            // Show error to user
            let errorMsg = BitchatMessage(
                sender: "system",
                content: "incorrect password for \(response.channel). please check with channel members for the correct password.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(errorMsg)
        }
    }
    
    func didReceiveChannelPasswordUpdate(_ update: ChannelPasswordUpdate, from peerID: String) {
        // Use the fingerprint from the update message (more reliable than looking up by peer ID)
        let senderFingerprint = update.ownerFingerprint
        
        // Verify sender is the channel owner by checking fingerprint
        guard let channelOwnerFingerprint = channelCreators[update.channel],
              channelOwnerFingerprint == senderFingerprint else {
            // Security: Ignoring password update from non-owner
            return
        }
        
        // Extract the new password
        let newPassword = String(data: update.encryptedPassword, encoding: .utf8) ?? ""
        
        // Verify the new key commitment matches
        let newKey = deriveChannelKey(from: newPassword, channelName: update.channel)
        let computedCommitment = computeKeyCommitment(for: newKey)
        
        guard computedCommitment == update.newKeyCommitment else {
            return
        }
        
        // Accept the new password
        channelKeys[update.channel] = newKey
        channelPasswords[update.channel] = newPassword
        channelKeyCommitments[update.channel] = update.newKeyCommitment
        
        // Save to keychain
        _ = KeychainManager.shared.saveChannelPassword(newPassword, for: update.channel)
        
        // Save channel data
        saveChannelData()
        
        // Notify user
        let notificationMsg = BitchatMessage(
            sender: "system",
            content: "password for \(update.channel) has been updated by the channel owner.",
            timestamp: Date(),
            isRelay: false
        )
        
        // Add to appropriate message list
        if currentChannel == update.channel {
            messages.append(notificationMsg)
        } else if channelMessages[update.channel] != nil {
            channelMessages[update.channel]?.append(notificationMsg)
        }
        
        // Force UI update
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    func didReceiveChannelMetadata(_ metadata: ChannelMetadata, from peerID: String) {
        
        // Check if we already have metadata for this channel
        if let existingMetadata = channelMetadata[metadata.channel] {
            // Keep the older one (first creator wins)
            if existingMetadata.createdAt < metadata.createdAt {
                return
            }
        }
        
        // Store the metadata
        channelMetadata[metadata.channel] = metadata
        
        // Update channel creator info
        if channelCreators[metadata.channel] == nil {
            channelCreators[metadata.channel] = metadata.creatorFingerprint
            
            if metadata.isPasswordProtected {
                passwordProtectedChannels.insert(metadata.channel)
                if let commitment = metadata.keyCommitment {
                    channelKeyCommitments[metadata.channel] = commitment
                }
            }
            
            saveChannelData()
            // Stored channel metadata
        }
    }
    
}
