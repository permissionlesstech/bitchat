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
    @Published var unreadPrivateMessages: Set<String> = []
    @Published var autocompleteSuggestions: [String] = []
    @Published var showAutocomplete: Bool = false
    @Published var autocompleteRange: NSRange? = nil
    @Published var selectedAutocompleteIndex: Int = 0
    
    // Room support
    @Published var joinedRooms: Set<String> = []  // Set of room hashtags
    @Published var currentRoom: String? = nil  // Currently selected room
    @Published var roomMessages: [String: [BitchatMessage]] = [:]  // room -> messages
    @Published var unreadRoomMessages: [String: Int] = [:]  // room -> unread count
    @Published var roomMembers: [String: Set<String>] = [:]  // room -> set of peer IDs who have sent messages
    @Published var roomPasswords: [String: String] = [:]  // room -> password (stored locally only)
    @Published var roomKeys: [String: SymmetricKey] = [:]  // room -> derived encryption key
    @Published var passwordProtectedRooms: Set<String> = []  // Set of rooms that require passwords
    @Published var roomCreators: [String: String] = [:]  // room -> creator peerID
    @Published var roomKeyCommitments: [String: String] = [:]  // room -> SHA256(derivedKey) for verification
    @Published var showPasswordPrompt: Bool = false
    @Published var passwordPromptRoom: String? = nil
    @Published var savedRooms: Set<String> = []  // Rooms saved for message retention
    @Published var retentionEnabledRooms: Set<String> = []  // Rooms where owner enabled retention for all members
    
    let meshService = BluetoothMeshService()
    private let userDefaults = UserDefaults.standard
    private let nicknameKey = "bitchat.nickname"
    private let favoritesKey = "bitchat.favorites"
    private let joinedRoomsKey = "bitchat.joinedRooms"
    private let passwordProtectedRoomsKey = "bitchat.passwordProtectedRooms"
    private let roomCreatorsKey = "bitchat.roomCreators"
    // private let roomPasswordsKey = "bitchat.roomPasswords" // Now using Keychain
    private let roomKeyCommitmentsKey = "bitchat.roomKeyCommitments"
    private let retentionEnabledRoomsKey = "bitchat.retentionEnabledRooms"
    private var nicknameSaveTimer: Timer?
    
    @Published var favoritePeers: Set<String> = []  // Now stores public key fingerprints instead of peer IDs
    private var peerIDToPublicKeyFingerprint: [String: String] = [:]  // Maps ephemeral peer IDs to persistent fingerprints
    
    // Messages are naturally ephemeral - no persistent storage
    
    // Delivery tracking
    private var deliveryTrackerCancellable: AnyCancellable?
    
    init() {
        loadNickname()
        loadFavorites()
        loadJoinedRooms()
        loadRoomData()
        // Load saved rooms state
        savedRooms = MessageRetentionService.shared.getFavoriteRooms()
        meshService.delegate = self
        
        // Log startup info
        
        // Start mesh service immediately
        meshService.startServices()
        
        // Set up message retry service
        MessageRetryService.shared.meshService = meshService
        
        // Request notification permission
        NotificationService.shared.requestAuthorization()
        
        // Subscribe to delivery status updates
        deliveryTrackerCancellable = DeliveryTracker.shared.deliveryStatusUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (messageID, status) in
                self?.updateMessageDeliveryStatus(messageID, status: status)
            }
    }
    
    private func loadNickname() {
        if let savedNickname = userDefaults.string(forKey: nicknameKey) {
            nickname = savedNickname
        } else {
            nickname = "user\(Int.random(in: 1000...9999))"
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
        if let savedFavorites = userDefaults.stringArray(forKey: favoritesKey) {
            favoritePeers = Set(savedFavorites)
        }
    }
    
    private func saveFavorites() {
        userDefaults.set(Array(favoritePeers), forKey: favoritesKey)
        userDefaults.synchronize()
    }
    
    private func loadJoinedRooms() {
        if let savedRoomsList = userDefaults.stringArray(forKey: joinedRoomsKey) {
            joinedRooms = Set(savedRoomsList)
            // Initialize empty data structures for joined rooms
            for room in joinedRooms {
                if roomMessages[room] == nil {
                    roomMessages[room] = []
                }
                if roomMembers[room] == nil {
                    roomMembers[room] = Set()
                }
                
                // Load saved messages if this room has retention enabled
                if retentionEnabledRooms.contains(room) {
                    let savedMessages = MessageRetentionService.shared.loadMessagesForRoom(room)
                    if !savedMessages.isEmpty {
                        roomMessages[room] = savedMessages
                    }
                }
            }
        }
    }
    
    private func saveJoinedRooms() {
        userDefaults.set(Array(joinedRooms), forKey: joinedRoomsKey)
        userDefaults.synchronize()
    }
    
    private func loadRoomData() {
        // Load password protected rooms
        if let savedProtectedRooms = userDefaults.stringArray(forKey: passwordProtectedRoomsKey) {
            passwordProtectedRooms = Set(savedProtectedRooms)
        }
        
        // Load room creators
        if let savedCreators = userDefaults.dictionary(forKey: roomCreatorsKey) as? [String: String] {
            roomCreators = savedCreators
        }
        
        // Load room key commitments
        if let savedCommitments = userDefaults.dictionary(forKey: roomKeyCommitmentsKey) as? [String: String] {
            roomKeyCommitments = savedCommitments
        }
        
        // Load retention-enabled rooms
        if let savedRetentionRooms = userDefaults.stringArray(forKey: retentionEnabledRoomsKey) {
            retentionEnabledRooms = Set(savedRetentionRooms)
        }
        
        // Load room passwords from Keychain
        let savedPasswords = KeychainManager.shared.getAllRoomPasswords()
        roomPasswords = savedPasswords
        // Derive keys for all saved passwords
        for (room, password) in savedPasswords {
            roomKeys[room] = deriveRoomKey(from: password, roomName: room)
        }
    }
    
    private func saveRoomData() {
        userDefaults.set(Array(passwordProtectedRooms), forKey: passwordProtectedRoomsKey)
        userDefaults.set(roomCreators, forKey: roomCreatorsKey)
        // Save passwords to Keychain instead of UserDefaults
        for (room, password) in roomPasswords {
            _ = KeychainManager.shared.saveRoomPassword(password, for: room)
        }
        userDefaults.set(roomKeyCommitments, forKey: roomKeyCommitmentsKey)
        userDefaults.set(Array(retentionEnabledRooms), forKey: retentionEnabledRoomsKey)
        userDefaults.synchronize()
    }
    
    func joinRoom(_ room: String, password: String? = nil) -> Bool {
        // Ensure room starts with #
        let roomTag = room.hasPrefix("#") ? room : "#\(room)"
        
        
        // Check if room is already joined and we can access it
        if joinedRooms.contains(roomTag) {
            // Already joined, check if we need password verification
            if passwordProtectedRooms.contains(roomTag) && roomKeys[roomTag] == nil {
                if let password = password {
                    // User provided password for already-joined room - verify it
                    
                    // Derive key and try to verify
                    let key = deriveRoomKey(from: password, roomName: roomTag)
                    
                    // First, check if we have a key commitment to verify against
                    if let expectedCommitment = roomKeyCommitments[roomTag] {
                        let actualCommitment = computeKeyCommitment(for: key)
                        if actualCommitment != expectedCommitment {
                            return false
                        }
                    }
                    
                    // Check if we have messages to verify against
                    if let roomMsgs = roomMessages[roomTag], !roomMsgs.isEmpty {
                        let encryptedMessages = roomMsgs.filter { $0.isEncrypted && $0.encryptedContent != nil }
                        if let encryptedMsg = encryptedMessages.first,
                           let encryptedData = encryptedMsg.encryptedContent {
                            let testDecrypted = decryptRoomMessage(encryptedData, room: roomTag, testKey: key)
                            if testDecrypted == nil {
                                return false
                            }
                        }
                    }
                    
                    // Store the verified key
                    roomKeys[roomTag] = key
                    roomPasswords[roomTag] = password
                    
                    // Now switch to the room
                    switchToRoom(roomTag)
                    return true
                } else {
                    // Need password to access
                    passwordPromptRoom = roomTag
                    showPasswordPrompt = true
                    return false
                }
            }
            // Switch to the room (no password needed)
            switchToRoom(roomTag)
            return true
        }
        
        // If room is password protected and we don't have the key yet
        if passwordProtectedRooms.contains(roomTag) && roomKeys[roomTag] == nil {
            // Allow room creator to bypass password check
            if roomCreators[roomTag] == meshService.myPeerID {
                // Room creator should already have the key set when they created the password
                // This is a failsafe - just proceed without password
            } else if let password = password {
                // Derive key from password
                let key = deriveRoomKey(from: password, roomName: roomTag)
                
                // First, check if we have a key commitment to verify against
                if let expectedCommitment = roomKeyCommitments[roomTag] {
                    let actualCommitment = computeKeyCommitment(for: key)
                    if actualCommitment != expectedCommitment {
                        return false
                    }
                }
                
                // Try to verify password if there are existing encrypted messages
                var passwordVerified = false
                var shouldProceed = true
                
                if let roomMsgs = roomMessages[roomTag], !roomMsgs.isEmpty {
                    // Look for encrypted messages to verify against
                    let encryptedMessages = roomMsgs.filter { $0.isEncrypted && $0.encryptedContent != nil }
                    
                    if let encryptedMsg = encryptedMessages.first,
                       let encryptedData = encryptedMsg.encryptedContent {
                        // Test decryption with the derived key
                        let testDecrypted = decryptRoomMessage(encryptedData, room: roomTag, testKey: key)
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
                            content: "joined room \(roomTag). password will be verified when encrypted messages arrive.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(warningMsg)
                    }
                } else {
                    // Empty room - accept tentatively
                    
                    // Add info message
                    let infoMsg = BitchatMessage(
                        sender: "system",
                        content: "joined empty room \(roomTag). waiting for encrypted messages to verify password.",
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
                roomKeys[roomTag] = key
                roomPasswords[roomTag] = password
                // Save password to Keychain
                _ = KeychainManager.shared.saveRoomPassword(password, for: roomTag)
                
                if passwordVerified {
                } else {
                }
            } else {
                // Show password prompt and return early - don't join the room yet
                passwordPromptRoom = roomTag
                showPasswordPrompt = true
                return false
            }
        }
        
        // At this point, room is either not password protected or we don't know yet
        
        joinedRooms.insert(roomTag)
        saveJoinedRooms()
        
        // Only claim creator role if this is a brand new room (no one has announced it as protected)
        // If it's password protected, someone else already created it
        if roomCreators[roomTag] == nil && !passwordProtectedRooms.contains(roomTag) {
            roomCreators[roomTag] = meshService.myPeerID
            saveRoomData()
        }
        
        // Add ourselves as a member
        if roomMembers[roomTag] == nil {
            roomMembers[roomTag] = Set()
        }
        roomMembers[roomTag]?.insert(meshService.myPeerID)
        
        // Switch to the room
        currentRoom = roomTag
        selectedPrivateChatPeer = nil  // Exit private chat if in one
        
        // Clear unread count for this room
        unreadRoomMessages[roomTag] = 0
        
        // Initialize room messages if needed
        if roomMessages[roomTag] == nil {
            roomMessages[roomTag] = []
        }
        
        // Load saved messages if this is a favorite room
        if MessageRetentionService.shared.getFavoriteRooms().contains(roomTag) {
            let savedMessages = MessageRetentionService.shared.loadMessagesForRoom(roomTag)
            if !savedMessages.isEmpty {
                // Merge saved messages with current messages, avoiding duplicates
                var existingMessageIDs = Set(roomMessages[roomTag]?.map { $0.id } ?? [])
                for savedMessage in savedMessages {
                    if !existingMessageIDs.contains(savedMessage.id) {
                        roomMessages[roomTag]?.append(savedMessage)
                        existingMessageIDs.insert(savedMessage.id)
                    }
                }
                // Sort by timestamp
                roomMessages[roomTag]?.sort { $0.timestamp < $1.timestamp }
            }
        }
        
        // Hide password prompt if it was showing
        showPasswordPrompt = false
        passwordPromptRoom = nil
        
        return true
    }
    
    func leaveRoom(_ room: String) {
        joinedRooms.remove(room)
        saveJoinedRooms()
        
        // Send leave notification to other peers
        meshService.sendRoomLeaveNotification(room)
        
        // If we're currently in this room, exit to main chat
        if currentRoom == room {
            currentRoom = nil
        }
        
        // Clean up room data
        unreadRoomMessages.removeValue(forKey: room)
        roomMessages.removeValue(forKey: room)
        roomMembers.removeValue(forKey: room)
        roomKeys.removeValue(forKey: room)
        roomPasswords.removeValue(forKey: room)
        // Delete password from Keychain
        _ = KeychainManager.shared.deleteRoomPassword(for: room)
    }
    
    // Password management
    func setRoomPassword(_ password: String, for room: String) {
        guard joinedRooms.contains(room) else { return }
        
        // Check if room already has a creator
        if let existingCreator = roomCreators[room], existingCreator != meshService.myPeerID {
            return
        }
        
        // If room is already password protected by someone else, we can't claim it
        if passwordProtectedRooms.contains(room) && roomCreators[room] != meshService.myPeerID {
            return
        }
        
        // Claim creator role if not set and room is not already protected
        if roomCreators[room] == nil && !passwordProtectedRooms.contains(room) {
            roomCreators[room] = meshService.myPeerID
            saveRoomData()
        }
        
        // Derive encryption key from password
        let key = deriveRoomKey(from: password, roomName: room)
        roomKeys[room] = key
        roomPasswords[room] = password
        passwordProtectedRooms.insert(room)
        // Save password to Keychain
        _ = KeychainManager.shared.saveRoomPassword(password, for: room)
        
        // Compute and store key commitment for verification
        let commitment = computeKeyCommitment(for: key)
        roomKeyCommitments[room] = commitment
        
        // Save room data
        saveRoomData()
        
        // Announce that this room is now password protected with commitment
        meshService.announcePasswordProtectedRoom(room, creatorID: meshService.myPeerID, keyCommitment: commitment)
        
        // Send an encrypted initialization message with metadata
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let metadata = [
            "type": "room_init",
            "room": room,
            "creator": nickname,
            "creatorID": meshService.myPeerID,
            "timestamp": timestamp,
            "version": "1.0"
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: metadata)
        let metadataStr = jsonData?.base64EncodedString() ?? ""
        
        let initMessage = "🔐 Room \(room) initialized | Protected room created by \(nickname) | Metadata: \(metadataStr)"
        meshService.sendEncryptedRoomMessage(initMessage, mentions: [], room: room, roomKey: key)
        
    }
    
    func removeRoomPassword(for room: String) {
        // Only room creator can remove password
        guard roomCreators[room] == meshService.myPeerID else {
            return
        }
        
        roomKeys.removeValue(forKey: room)
        roomPasswords.removeValue(forKey: room)
        roomKeyCommitments.removeValue(forKey: room)
        passwordProtectedRooms.remove(room)
        // Delete password from Keychain
        _ = KeychainManager.shared.deleteRoomPassword(for: room)
        
        // Save room data
        saveRoomData()
        
        // Announce that this room is no longer password protected
        meshService.announcePasswordProtectedRoom(room, isProtected: false, creatorID: meshService.myPeerID)
        
    }
    
    // Transfer room ownership to another user
    func transferRoomOwnership(to nickname: String) {
        guard let currentRoom = currentRoom else {
            let msg = BitchatMessage(
                sender: "system",
                content: "you must be in a room to transfer ownership.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Check if current user is the owner
        guard roomCreators[currentRoom] == meshService.myPeerID else {
            let msg = BitchatMessage(
                sender: "system",
                content: "only the room owner can transfer ownership.",
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
        
        // Update ownership
        roomCreators[currentRoom] = targetPeerID
        saveRoomData()
        
        // Announce the ownership transfer
        if passwordProtectedRooms.contains(currentRoom) {
            let commitment = roomKeyCommitments[currentRoom]
            meshService.announcePasswordProtectedRoom(currentRoom, creatorID: targetPeerID, keyCommitment: commitment)
        }
        
        // Send notification message
        let transferMsg = BitchatMessage(
            sender: "system",
            content: "room ownership transferred from \(self.nickname) to \(targetNick).",
            timestamp: Date(),
            isRelay: false,
            room: currentRoom
        )
        messages.append(transferMsg)
        
        // Send encrypted notification if room is protected
        if let roomKey = roomKeys[currentRoom] {
            let notifyMsg = "🔑 Room ownership transferred to \(targetNick) by \(self.nickname)"
            meshService.sendEncryptedRoomMessage(notifyMsg, mentions: [targetNick], room: currentRoom, roomKey: roomKey)
        } else {
            meshService.sendMessage(transferMsg.content, mentions: [targetNick])
        }
        
    }
    
    // Change password for current room
    func changeRoomPassword(to newPassword: String) {
        guard let currentRoom = currentRoom else {
            let msg = BitchatMessage(
                sender: "system",
                content: "you must be in a room to change its password.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Check if current user is the owner
        guard roomCreators[currentRoom] == meshService.myPeerID else {
            let msg = BitchatMessage(
                sender: "system",
                content: "only the room owner can change the password.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Check if room is currently password protected
        guard passwordProtectedRooms.contains(currentRoom) else {
            let msg = BitchatMessage(
                sender: "system",
                content: "room is not password protected. use the lock button to set a password.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Store old key for re-encryption
        let oldKey = roomKeys[currentRoom]
        
        // Derive new encryption key from new password
        let newKey = deriveRoomKey(from: newPassword, roomName: currentRoom)
        roomKeys[currentRoom] = newKey
        roomPasswords[currentRoom] = newPassword
        // Update password in Keychain
        _ = KeychainManager.shared.saveRoomPassword(newPassword, for: currentRoom)
        
        // Compute new key commitment
        let newCommitment = computeKeyCommitment(for: newKey)
        roomKeyCommitments[currentRoom] = newCommitment
        
        // Save room data
        saveRoomData()
        
        // Send password change notification with old key
        if let oldKey = oldKey {
            let changeNotice = "🔐 Password changed by room owner. Please update your password."
            meshService.sendEncryptedRoomMessage(changeNotice, mentions: [], room: currentRoom, roomKey: oldKey)
        }
        
        // Send new initialization message with new key
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let metadata = [
            "type": "password_change",
            "room": currentRoom,
            "changer": nickname,
            "changerID": meshService.myPeerID,
            "timestamp": timestamp,
            "version": "1.0"
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: metadata)
        let metadataStr = jsonData?.base64EncodedString() ?? ""
        
        let initMessage = "🔑 Password changed | Room \(currentRoom) password updated by \(nickname) | Metadata: \(metadataStr)"
        meshService.sendEncryptedRoomMessage(initMessage, mentions: [], room: currentRoom, roomKey: newKey)
        
        // Announce the new commitment
        meshService.announcePasswordProtectedRoom(currentRoom, creatorID: meshService.myPeerID, keyCommitment: newCommitment)
        
        // Add local success message
        let successMsg = BitchatMessage(
            sender: "system",
            content: "password changed successfully. other users will need to re-enter the new password.",
            timestamp: Date(),
            isRelay: false
        )
        messages.append(successMsg)
        
    }
    
    // Compute SHA256 hash of the derived key for public verification
    private func computeKeyCommitment(for key: SymmetricKey) -> String {
        let keyData = key.withUnsafeBytes { Data($0) }
        let hash = SHA256.hash(data: keyData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func deriveRoomKey(from password: String, roomName: String) -> SymmetricKey {
        // Use PBKDF2 to derive a key from the password
        let salt = roomName.data(using: .utf8)!  // Use room name as salt for consistency
        let keyData = pbkdf2(password: password, salt: salt, iterations: 100000, keyLength: 32)
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
    
    func switchToRoom(_ room: String?) {
        // Check if room needs password
        if let room = room, passwordProtectedRooms.contains(room) && roomKeys[room] == nil {
            // Need password, show prompt instead
            passwordPromptRoom = room
            showPasswordPrompt = true
            return
        }
        
        currentRoom = room
        selectedPrivateChatPeer = nil  // Exit private chat
        
        // Clear unread count for this room
        if let room = room {
            unreadRoomMessages[room] = 0
        }
    }
    
    func getRoomMessages(_ room: String) -> [BitchatMessage] {
        return roomMessages[room] ?? []
    }
    
    func parseRooms(from content: String) -> Set<String> {
        let pattern = "#([a-zA-Z0-9_]+)"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let matches = regex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        
        var rooms = Set<String>()
        for match in matches {
            if let range = Range(match.range(at: 0), in: content) {
                let room = String(content[range])
                rooms.insert(room)
            }
        }
        
        return rooms
    }
    
    func toggleFavorite(peerID: String) {
        // Use public key fingerprints for persistent favorites
        guard let fingerprint = peerIDToPublicKeyFingerprint[peerID] else {
            // print("[FAVORITES] No public key fingerprint for peer \(peerID)")
            return
        }
        
        if favoritePeers.contains(fingerprint) {
            favoritePeers.remove(fingerprint)
        } else {
            favoritePeers.insert(fingerprint)
        }
        saveFavorites()
        
        // print("[FAVORITES] Toggled favorite for fingerprint: \(fingerprint)")
    }
    
    func isFavorite(peerID: String) -> Bool {
        guard let fingerprint = peerIDToPublicKeyFingerprint[peerID] else {
            return false
        }
        return favoritePeers.contains(fingerprint)
    }
    
    // Called when we receive a peer's public key
    func registerPeerPublicKey(peerID: String, publicKeyData: Data) {
        // Create a fingerprint from the public key
        let fingerprint = SHA256.hash(data: publicKeyData)
            .compactMap { String(format: "%02x", $0) }
            .joined()
            .prefix(16)  // Use first 16 chars for brevity
            .lowercased()
        
        let fingerprintStr = String(fingerprint)
        
        // Only register if not already registered
        if peerIDToPublicKeyFingerprint[peerID] != fingerprintStr {
            peerIDToPublicKeyFingerprint[peerID] = fingerprintStr
            // print("[FAVORITES] Registered fingerprint \(fingerprint) for peer \(peerID)")
        }
    }
    
    func sendMessage(_ content: String) {
        guard !content.isEmpty else { return }
        
        // Check for commands
        if content.hasPrefix("/") {
            handleCommand(content)
            return
        }
        
        if let selectedPeer = selectedPrivateChatPeer {
            // Send as private message
            sendPrivateMessage(content, to: selectedPeer)
        } else {
            // Parse mentions and rooms from the content
            let mentions = parseMentions(from: content)
            let rooms = parseRooms(from: content)
            
            // Auto-join any rooms mentioned in the message
            for room in rooms {
                if !joinedRooms.contains(room) {
                    let _ = joinRoom(room)
                }
            }
            
            // Determine which room this message belongs to
            let messageRoom = currentRoom  // Use current room if we're in one
            
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
                room: messageRoom
            )
            
            if let room = messageRoom {
                // Add to room messages
                if roomMessages[room] == nil {
                    roomMessages[room] = []
                }
                roomMessages[room]?.append(message)
                
                // Save message if room has retention enabled
                if retentionEnabledRooms.contains(room) {
                    MessageRetentionService.shared.saveMessage(message, forRoom: room)
                }
                
                // Track ourselves as a room member
                if roomMembers[room] == nil {
                    roomMembers[room] = Set()
                }
                roomMembers[room]?.insert(meshService.myPeerID)
            } else {
                // Add to main messages
                messages.append(message)
            }
            
            // Only auto-join rooms if we're sending TO that room
            if let messageRoom = messageRoom {
                if !joinedRooms.contains(messageRoom) {
                    let _ = joinRoom(messageRoom)
                }
            }
            
            // Check if room is password protected and encrypt if needed
            if let room = messageRoom, roomKeys[room] != nil {
                // Send encrypted room message
                meshService.sendEncryptedRoomMessage(content, mentions: mentions, room: room, roomKey: roomKeys[room]!)
            } else {
                // Send via mesh with mentions and room (unencrypted)
                meshService.sendMessage(content, mentions: mentions, room: messageRoom)
            }
        }
    }
    
    func sendPrivateMessage(_ content: String, to peerID: String) {
        guard !content.isEmpty else { return }
        guard let recipientNickname = meshService.getPeerNicknames()[peerID] else { return }
        
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
        selectedPrivateChatPeer = peerID
        unreadPrivateMessages.remove(peerID)
        
        // Initialize chat history if needed
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
    }
    
    func endPrivateChat() {
        selectedPrivateChatPeer = nil
    }
    
    func getPrivateChatMessages(for peerID: String) -> [BitchatMessage] {
        return privateChats[peerID] ?? []
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
        
        // Clear all room data
        joinedRooms.removeAll()
        currentRoom = nil
        roomMessages.removeAll()
        unreadRoomMessages.removeAll()
        roomMembers.removeAll()
        roomPasswords.removeAll()
        roomKeys.removeAll()
        passwordProtectedRooms.removeAll()
        roomCreators.removeAll()
        roomKeyCommitments.removeAll()
        showPasswordPrompt = false
        passwordPromptRoom = nil
        
        // Clear all keychain passwords
        _ = KeychainManager.shared.deleteAllPasswords()
        
        // Clear all retained messages
        MessageRetentionService.shared.deleteAllStoredMessages()
        savedRooms.removeAll()
        retentionEnabledRooms.removeAll()
        
        // Clear message retry queue
        MessageRetryService.shared.clearRetryQueue()
        
        // Clear persisted room data from UserDefaults
        userDefaults.removeObject(forKey: joinedRoomsKey)
        userDefaults.removeObject(forKey: passwordProtectedRoomsKey)
        userDefaults.removeObject(forKey: roomCreatorsKey)
        userDefaults.removeObject(forKey: roomKeyCommitmentsKey)
        userDefaults.removeObject(forKey: retentionEnabledRoomsKey)
        
        // Reset nickname to anonymous
        nickname = "anon\(Int.random(in: 1000...9999))"
        saveNickname()
        
        // Clear favorites
        favoritePeers.removeAll()
        peerIDToPublicKeyFingerprint.removeAll()
        saveFavorites()
        
        // Clear autocomplete state
        autocompleteSuggestions.removeAll()
        showAutocomplete = false
        autocompleteRange = nil
        selectedAutocompleteIndex = 0
        
        // Clear selected private chat
        selectedPrivateChatPeer = nil
        
        // Disconnect from all peers
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
    
    func formatMessage(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        var result = AttributedString()
        
        let isDark = colorScheme == .dark
        let primaryColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        let secondaryColor = primaryColor.opacity(0.7)
        
        let timestamp = AttributedString("[\(formatTimestamp(message.timestamp))] ")
        var timestampStyle = AttributeContainer()
        timestampStyle.foregroundColor = secondaryColor
        timestampStyle.font = .system(size: 12, design: .monospaced)
        result.append(timestamp.mergingAttributes(timestampStyle))
        
        if message.sender == "system" {
            let content = AttributedString("* \(message.content) *")
            var contentStyle = AttributeContainer()
            contentStyle.foregroundColor = secondaryColor
            contentStyle.font = .system(size: 14, design: .monospaced).italic()
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
}

extension ChatViewModel: BitchatDelegate {
    func didReceiveRoomLeave(_ room: String, from peerID: String) {
        // Remove peer from room members
        if roomMembers[room] != nil {
            roomMembers[room]?.remove(peerID)
            
            // Force UI update
            objectWillChange.send()
        }
    }
    
    func didReceivePasswordProtectedRoomAnnouncement(_ room: String, isProtected: Bool, creatorID: String?, keyCommitment: String?) {
        let wasAlreadyProtected = passwordProtectedRooms.contains(room)
        
        if isProtected {
            passwordProtectedRooms.insert(room)
            if let creator = creatorID {
                roomCreators[room] = creator
            }
            
            // Store the key commitment if provided
            if let commitment = keyCommitment {
                roomKeyCommitments[room] = commitment
            }
            
            // If we just learned this room is protected and we're in it without a key, prompt for password
            if !wasAlreadyProtected && joinedRooms.contains(room) && roomKeys[room] == nil {
                
                // Add system message
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "room \(room) is password protected. you need the password to participate.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
                
                // If currently viewing this room, show password prompt
                if currentRoom == room {
                    passwordPromptRoom = room
                    showPasswordPrompt = true
                }
            }
        } else {
            passwordProtectedRooms.remove(room)
            // If we're in this room and it's no longer protected, clear the key
            roomKeys.removeValue(forKey: room)
            roomPasswords.removeValue(forKey: room)
            roomKeyCommitments.removeValue(forKey: room)
        }
        
        // Save updated room data
        saveRoomData()
        
    }
    
    func decryptRoomMessage(_ encryptedContent: Data, room: String, testKey: SymmetricKey? = nil) -> String? {
        let key = testKey ?? roomKeys[room]
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
    
    func didReceiveRoomRetentionAnnouncement(_ room: String, enabled: Bool, creatorID: String?) {
        
        // Only process if we're a member of this room
        guard joinedRooms.contains(room) else { return }
        
        // Verify the announcement is from the room owner
        if let creatorID = creatorID, roomCreators[room] != creatorID {
            return
        }
        
        // Update retention status
        if enabled {
            retentionEnabledRooms.insert(room)
            savedRooms.insert(room)
            // Ensure room is in favorites if not already
            if !MessageRetentionService.shared.getFavoriteRooms().contains(room) {
                _ = MessageRetentionService.shared.toggleFavoriteRoom(room)
            }
            
            // Show system message
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "room owner enabled message retention for \(room). all messages will be saved locally.",
                timestamp: Date(),
                isRelay: false
            )
            if currentRoom == room {
                messages.append(systemMessage)
            } else if var roomMsgs = roomMessages[room] {
                roomMsgs.append(systemMessage)
                roomMessages[room] = roomMsgs
            } else {
                roomMessages[room] = [systemMessage]
            }
        } else {
            retentionEnabledRooms.remove(room)
            savedRooms.remove(room)
            
            // Delete all saved messages for this room
            MessageRetentionService.shared.deleteMessagesForRoom(room)
            // Remove from favorites if currently set
            if MessageRetentionService.shared.getFavoriteRooms().contains(room) {
                _ = MessageRetentionService.shared.toggleFavoriteRoom(room)
            }
            
            // Show system message
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "room owner disabled message retention for \(room). all saved messages have been deleted.",
                timestamp: Date(),
                isRelay: false
            )
            if currentRoom == room {
                messages.append(systemMessage)
            } else if var roomMsgs = roomMessages[room] {
                roomMsgs.append(systemMessage)
                roomMessages[room] = roomMsgs
            } else {
                roomMessages[room] = [systemMessage]
            }
        }
        
        // Persist retention status
        userDefaults.set(Array(retentionEnabledRooms), forKey: retentionEnabledRoomsKey)
    }
    
    private func handleCommand(_ command: String) {
        let parts = command.split(separator: " ")
        guard let cmd = parts.first else { return }
        
        switch cmd {
        case "/j":
            if parts.count > 1 {
                let roomName = String(parts[1])
                // Ensure room name starts with #
                let room = roomName.hasPrefix("#") ? roomName : "#\(roomName)"
                
                // Validate room name
                let cleanedName = room.dropFirst()
                let isValidName = !cleanedName.isEmpty && cleanedName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
                
                if !isValidName {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "invalid room name. use only letters, numbers, and underscores.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                } else {
                    let wasAlreadyJoined = joinedRooms.contains(room)
                    let wasPasswordProtected = passwordProtectedRooms.contains(room)
                    let hadCreator = roomCreators[room] != nil
                    
                    let success = joinRoom(room)
                    
                    if success {
                        if !wasAlreadyJoined {
                            var message = "joined room \(room)"
                            if !hadCreator && !wasPasswordProtected {
                                message += " (created new room - you are the owner)"
                            }
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: message,
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                        } else {
                            // Already in room, just switched to it
                            let systemMessage = BitchatMessage(
                                sender: "system",
                                content: "switched to room \(room)",
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
                    content: "usage: /j #roomname",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
        case "/create":
            // /create is now just an alias for /join
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "use /join #roomname to join or create a room",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(systemMessage)
        case "/m":
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
        case "/rooms":
            // Discover all rooms (both joined and not joined)
            var allRooms: Set<String> = Set()
            
            // Add joined rooms
            allRooms.formUnion(joinedRooms)
            
            // Find rooms from messages we've seen
            for msg in messages {
                if let room = msg.room {
                    allRooms.insert(room)
                }
            }
            
            // Also check room messages we've cached
            for (room, _) in roomMessages {
                allRooms.insert(room)
            }
            
            // Add password protected rooms we know about
            allRooms.formUnion(passwordProtectedRooms)
            
            if allRooms.isEmpty {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "no rooms discovered yet. rooms appear as people use them.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            } else {
                let roomList = allRooms.sorted().map { room in
                    var status = ""
                    if joinedRooms.contains(room) {
                        status += " ✓"
                    }
                    if passwordProtectedRooms.contains(room) {
                        status += " 🔒"
                    }
                    if retentionEnabledRooms.contains(room) {
                        status += " 📌"
                    }
                    if roomCreators[room] == meshService.myPeerID {
                        status += " (owner)"
                    }
                    return "\(room)\(status)"
                }.joined(separator: "\n")
                
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "discovered rooms:\n\(roomList)\n\n✓ = joined, 🔒 = password protected, 📌 = retention enabled",
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
            // Transfer room ownership
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
                transferRoomOwnership(to: parts[1])
            }
        case "/pass":
            // Change room password (only available in rooms)
            guard currentRoom != nil else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "you must be in a room to use /pass.",
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
                changeRoomPassword(to: parts[1])
            }
        case "/clear":
            // Clear messages based on current context
            if let room = currentRoom {
                // Clear room messages
                roomMessages[room]?.removeAll()
            } else if let peerID = selectedPrivateChatPeer {
                // Clear private chat
                privateChats[peerID]?.removeAll()
            } else {
                // Clear main messages
                messages.removeAll()
            }
        case "/save":
            // Toggle retention for current room (owner only)
            guard let room = currentRoom else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "you must be in a room to toggle message retention.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
                break
            }
            
            // Check if user is the room owner
            guard roomCreators[room] == meshService.myPeerID else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "only the room owner can toggle message retention.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
                break
            }
            
            // Toggle retention status
            let isEnabling = !retentionEnabledRooms.contains(room)
            
            if isEnabling {
                // Enable retention for this room
                retentionEnabledRooms.insert(room)
                savedRooms.insert(room)
                _ = MessageRetentionService.shared.toggleFavoriteRoom(room) // Enable if not already
                
                // Announce to all members that retention is enabled
                meshService.sendRoomRetentionAnnouncement(room, enabled: true)
                
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "message retention enabled for room \(room). all members will save messages locally.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
                
                // Load any previously saved messages
                let savedMessages = MessageRetentionService.shared.loadMessagesForRoom(room)
                if !savedMessages.isEmpty {
                    // Merge saved messages with current messages, avoiding duplicates
                    var existingMessageIDs = Set(roomMessages[room]?.map { $0.id } ?? [])
                    for savedMessage in savedMessages {
                        if !existingMessageIDs.contains(savedMessage.id) {
                            if roomMessages[room] == nil {
                                roomMessages[room] = []
                            }
                            roomMessages[room]?.append(savedMessage)
                            existingMessageIDs.insert(savedMessage.id)
                        }
                    }
                    // Sort by timestamp
                    roomMessages[room]?.sort { $0.timestamp < $1.timestamp }
                }
            } else {
                // Disable retention for this room
                retentionEnabledRooms.remove(room)
                savedRooms.remove(room)
                
                // Delete all saved messages for this room
                MessageRetentionService.shared.deleteMessagesForRoom(room)
                _ = MessageRetentionService.shared.toggleFavoriteRoom(room) // Disable if enabled
                
                // Announce to all members that retention is disabled
                meshService.sendRoomRetentionAnnouncement(room, enabled: false)
                
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "message retention disabled for room \(room). all saved messages will be deleted on all devices.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
            
            // Save the updated room data
            saveRoomData()
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
        
        if message.isPrivate {
            // Handle private message
            
            // Use the senderPeerID from the message if available
            let senderPeerID = message.senderPeerID ?? getPeerIDForNickname(message.sender)
            
            if let peerID = senderPeerID {
                // Message from someone else
                if privateChats[peerID] == nil {
                    privateChats[peerID] = []
                }
                privateChats[peerID]?.append(message)
                // Sort messages by timestamp to ensure proper ordering
                privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                
                // Trigger UI update for private chats
                objectWillChange.send()
                
                // Mark as unread if not currently viewing this chat
                if selectedPrivateChatPeer != peerID {
                    unreadPrivateMessages.insert(peerID)
                    
                } else {
                    // We're viewing this chat, make sure unread is cleared
                    unreadPrivateMessages.remove(peerID)
                }
            } else if message.sender == nickname {
                // Our own message that was echoed back - ignore it since we already added it locally
            }
        } else if let room = message.room {
            // Room message
            
            // Only process room messages if we've joined this room
            if joinedRooms.contains(room) {
                // Prepare the message to add (might be updated if decryption succeeds)
                var messageToAdd = message
                
                // Check if this is an encrypted message and we don't have the key
                if message.isEncrypted && roomKeys[room] == nil {
                    // Mark room as password protected if not already
                    let wasNewlyDiscovered = !passwordProtectedRooms.contains(room)
                    if wasNewlyDiscovered {
                        passwordProtectedRooms.insert(room)
                        saveRoomData()
                        
                        // Add a system message to indicate the room is password protected (only once)
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "room \(room) is password protected. you need the password to read messages.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        if roomMessages[room] == nil {
                            roomMessages[room] = []
                        }
                        roomMessages[room]?.append(systemMessage)
                    }
                    
                    // If we're currently viewing this room, prompt for password
                    if currentRoom == room {
                        passwordPromptRoom = room
                        showPasswordPrompt = true
                    }
                } else if message.isEncrypted && roomKeys[room] != nil && message.content == "[Encrypted message - password required]" {
                    // We have a key but the message shows as encrypted - try to decrypt it again
                    
                    // Check if this is the first encrypted message in the room (password verification opportunity)
                    let isFirstEncryptedMessage = roomMessages[room]?.filter { $0.isEncrypted }.isEmpty ?? true
                    
                    if let encryptedData = message.encryptedContent {
                        if let decryptedContent = decryptRoomMessage(encryptedData, room: room) {
                            // Successfully decrypted - update the message content
                            
                            if isFirstEncryptedMessage {
                                
                                // Add success message
                                let verifiedMsg = BitchatMessage(
                                    sender: "system",
                                    content: "password verified successfully for room \(room).",
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
                                room: message.room,
                                encryptedContent: message.encryptedContent,
                                isEncrypted: message.isEncrypted
                            )
                            
                            // Update the message we'll add
                            messageToAdd = decryptedMessage
                        } else {
                            // Decryption really failed - wrong password
                            
                            // Clear the wrong password
                            roomKeys.removeValue(forKey: room)
                            roomPasswords.removeValue(forKey: room)
                            
                            // If this was the first encrypted message, we need to kick the user out
                            if isFirstEncryptedMessage {
                                
                                // Leave the room
                                joinedRooms.remove(room)
                                saveJoinedRooms()
                                
                                // Clear room data
                                roomMessages.removeValue(forKey: room)
                                roomMembers.removeValue(forKey: room)
                                unreadRoomMessages.removeValue(forKey: room)
                                
                                // If we're currently in this room, exit to main
                                if currentRoom == room {
                                    currentRoom = nil
                                }
                                
                                // Add error message
                                let errorMsg = BitchatMessage(
                                    sender: "system",
                                    content: "wrong password for room \(room). you have been removed from the room.",
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
                                content: "wrong password for room \(room). please enter the correct password.",
                                timestamp: Date(),
                                isRelay: false
                            )
                            messages.append(systemMessage)
                            
                            // Show password prompt again
                            if currentRoom == room {
                                passwordPromptRoom = room
                                showPasswordPrompt = true
                            }
                        }
                    }
                }
                
                // Add to room messages (using potentially decrypted version)
                if roomMessages[room] == nil {
                    roomMessages[room] = []
                }
                roomMessages[room]?.append(messageToAdd)
                roomMessages[room]?.sort { $0.timestamp < $1.timestamp }
                
                // Save message if room has retention enabled
                if retentionEnabledRooms.contains(room) {
                    MessageRetentionService.shared.saveMessage(messageToAdd, forRoom: room)
                }
                
                // Track room members - only track the sender as a member
                if roomMembers[room] == nil {
                    roomMembers[room] = Set()
                }
                if let senderPeerID = message.senderPeerID {
                    roomMembers[room]?.insert(senderPeerID)
                } else {
                }
                
                // Update unread count if not currently viewing this room
                if currentRoom != room {
                    unreadRoomMessages[room] = (unreadRoomMessages[room] ?? 0) + 1
                }
            } else {
                // We're not in this room, ignore the message
            }
        } else {
            // Regular public message (main chat)
            messages.append(message)
            // Sort messages by timestamp to ensure proper ordering
            messages.sort { $0.timestamp < $1.timestamp }
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
        if isMentioned && message.sender != nickname {
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
        let systemMessage = BitchatMessage(
            sender: "system",
            content: "\(peerID) connected",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil
        )
        messages.append(systemMessage)
        
        // Force UI update
        objectWillChange.send()
    }
    
    func didDisconnectFromPeer(_ peerID: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: "\(peerID) disconnected",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil
        )
        messages.append(systemMessage)
        
        // Force UI update
        objectWillChange.send()
    }
    
    func didUpdatePeerList(_ peers: [String]) {
        // print("[DEBUG] Updating peer list: \(peers.count) peers: \(peers)")
        connectedPeers = peers
        isConnected = !peers.isEmpty
        
        // Clean up room members who disconnected
        for (room, memberIDs) in roomMembers {
            // Remove disconnected peers from room members
            let activeMembers = memberIDs.filter { memberID in
                memberID == meshService.myPeerID || peers.contains(memberID)
            }
            if activeMembers != memberIDs {
                roomMembers[room] = activeMembers
            }
        }
        
        // Force UI update
        objectWillChange.send()
        
        // If we're in a private chat with someone who disconnected, exit the chat
        if let currentChatPeer = selectedPrivateChatPeer,
           !peers.contains(currentChatPeer) {
            endPrivateChat()
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
        return favoritePeers.contains(fingerprint)
    }
    
    func didReceiveDeliveryAck(_ ack: DeliveryAck) {
        // Find the message and update its delivery status
        updateMessageDeliveryStatus(ack.originalMessageID, status: .delivered(to: ack.recipientNickname, at: ack.timestamp))
    }
    
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        updateMessageDeliveryStatus(messageID, status: status)
    }
    
    private func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        // Update in main messages
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            var updatedMessage = messages[index]
            updatedMessage.deliveryStatus = status
            messages[index] = updatedMessage
        }
        
        // Update in private chats
        for (peerID, var chatMessages) in privateChats {
            if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                var updatedMessage = chatMessages[index]
                updatedMessage.deliveryStatus = status
                chatMessages[index] = updatedMessage
                privateChats[peerID] = chatMessages
            }
        }
        
        // Update in room messages
        for (room, var roomMsgs) in roomMessages {
            if let index = roomMsgs.firstIndex(where: { $0.id == messageID }) {
                var updatedMessage = roomMsgs[index]
                updatedMessage.deliveryStatus = status
                roomMsgs[index] = updatedMessage
                roomMessages[room] = roomMsgs
            }
        }
    }
    
}
