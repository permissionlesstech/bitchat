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
    
    let meshService = BluetoothMeshService()
    private let userDefaults = UserDefaults.standard
    private let nicknameKey = "bitchat.nickname"
    private let favoritesKey = "bitchat.favorites"
    private var nicknameSaveTimer: Timer?
    
    @Published var favoritePeers: Set<String> = []  // Now stores public key fingerprints instead of peer IDs
    private var peerIDToPublicKeyFingerprint: [String: String] = [:]  // Maps ephemeral peer IDs to persistent fingerprints
    
    // Messages are naturally ephemeral - no persistent storage
    
    init() {
        loadNickname()
        loadFavorites()
        meshService.delegate = self
        
        // Start mesh service immediately
        meshService.startServices()
        
        // Request notification permission
        NotificationService.shared.requestAuthorization()
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
        
        if let selectedPeer = selectedPrivateChatPeer {
            // Send as private message
            sendPrivateMessage(content, to: selectedPeer)
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
                mentions: mentions.isEmpty ? nil : mentions
            )
            messages.append(message)
            
            // Send via mesh with mentions
            meshService.sendMessage(content, mentions: mentions)
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
            senderPeerID: meshService.myPeerID
        )
        
        // Add to our private chat history
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        privateChats[peerID]?.append(message)
        
        // Trigger UI update
        objectWillChange.send()
        
        // Send via mesh
        meshService.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname)
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
        
        // Reset nickname to anonymous
        nickname = "anon\(Int.random(in: 1000...9999))"
        saveNickname()
        
        // Clear favorites
        favoritePeers.removeAll()
        saveFavorites()
        
        // Clear autocomplete state
        autocompleteSuggestions.removeAll()
        showAutocomplete = false
        
        // Disconnect from all peers
        meshService.emergencyDisconnectAll()
        
        // Force UI update
        objectWillChange.send()
        
        // print("[PANIC] All data cleared for safety")
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
        } else {
            // Regular public message
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
    
}