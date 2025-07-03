import Foundation
import SwiftUI
import Combine
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
    @Published var privateMessageNotification: (sender: String, message: String)? = nil
    
    let meshService = BluetoothMeshService()
    let audioRecorder = AudioRecordingService()
    let audioPlayer = AudioPlaybackService()
    private let userDefaults = UserDefaults.standard
    private let nicknameKey = "bitchat.nickname"
    private let favoritesKey = "bitchat.favorites"
    private var nicknameSaveTimer: Timer?
    private var notificationTimer: Timer?
    
    @Published var favoritePeers: Set<String> = []
    
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
        if favoritePeers.contains(peerID) {
            favoritePeers.remove(peerID)
        } else {
            favoritePeers.insert(peerID)
        }
        saveFavorites()
    }
    
    func isFavorite(peerID: String) -> Bool {
        return favoritePeers.contains(peerID)
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
    
    private func showPrivateMessageNotification(from sender: String, content: String) {
        // Show notification
        privateMessageNotification = (sender: sender, message: content)
        
        // Auto-dismiss after 3 seconds
        notificationTimer?.invalidate()
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.privateMessageNotification = nil
        }
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
    
    func formatVoiceNoteContent(_ message: BitchatMessage, colorScheme: ColorScheme) -> AttributedString {
        let isDark = colorScheme == .dark
        let primaryColor = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        
        var result = AttributedString()
        var contentStyle = AttributeContainer()
        contentStyle.font = .system(size: 14, design: .monospaced)
        contentStyle.foregroundColor = isDark ? Color.white : Color.black
        
        // Parse the emoji and duration from content
        let parts = message.content.components(separatedBy: " ")
        if parts.count >= 2 {
            // Emoji
            result.append(AttributedString(parts[0] + " ").mergingAttributes(contentStyle))
            
            // Play/pause button as text
            let playSymbol = audioPlayer.isPlaying && audioPlayer.currentPlayingMessageID == message.id ? "⏸" : "▶"
            var playStyle = AttributeContainer()
            playStyle.font = .system(size: 12, design: .monospaced)
            playStyle.foregroundColor = primaryColor
            result.append(AttributedString(playSymbol + " ").mergingAttributes(playStyle))
            
            // Duration
            result.append(AttributedString(parts[1]).mergingAttributes(contentStyle))
        } else {
            result.append(AttributedString(message.content).mergingAttributes(contentStyle))
        }
        
        return result
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
            
            // Special handling for voice notes
            if message.voiceNoteData != nil {
                // Add the content (emoji + duration) with play button integrated
                var contentStyle = AttributeContainer()
                contentStyle.font = .system(size: 14, design: .monospaced)
                contentStyle.foregroundColor = isDark ? Color.white : Color.black
                
                // Parse the emoji and duration from content
                let parts = message.content.components(separatedBy: " ")
                if parts.count >= 2 {
                    // Emoji
                    result.append(AttributedString(parts[0] + " ").mergingAttributes(contentStyle))
                    
                    // Play/pause button as text
                    let playSymbol = audioPlayer.isPlaying && audioPlayer.currentPlayingMessageID == message.id ? "⏸" : "▶"
                    var playStyle = AttributeContainer()
                    playStyle.font = .system(size: 12, design: .monospaced)
                    playStyle.foregroundColor = primaryColor
                    result.append(AttributedString(playSymbol + " ").mergingAttributes(playStyle))
                    
                    // Duration
                    result.append(AttributedString(parts[1]).mergingAttributes(contentStyle))
                } else {
                    result.append(AttributedString(message.content).mergingAttributes(contentStyle))
                }
                return result
            }
            
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
                
                // Trigger UI update for private chats
                objectWillChange.send()
                
                // Mark as unread if not currently viewing this chat
                if selectedPrivateChatPeer != peerID {
                    unreadPrivateMessages.insert(peerID)
                    
                    // Show notification banner
                    showPrivateMessageNotification(from: message.sender, content: message.content)
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
            content: "\(peerID) has joined the channel",
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
            content: "\(peerID) has left the channel",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil
        )
        messages.append(systemMessage)
        
        // Force UI update
        objectWillChange.send()
    }
    
    func didUpdatePeerList(_ peers: [String]) {
        connectedPeers = peers
        isConnected = !peers.isEmpty
        
        // If we just disconnected from all peers, ensure UI updates
        if peers.isEmpty && isConnected {
            isConnected = false
        }
        
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
    
    func sendVoiceNote(_ audioData: Data, duration: TimeInterval) {
        print("[VIEWMODEL] sendVoiceNote called with audio data: \(audioData.count) bytes, duration: \(duration)s")
        
        let message = BitchatMessage(
            sender: nickname,
            content: "🎤 \(String(format: "%.1f", duration))s",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            voiceNoteData: audioData,
            voiceNoteDuration: duration
        )
        messages.append(message)
        
        print("[VIEWMODEL] Added voice note to local messages, sending via mesh...")
        
        // Send via mesh
        meshService.sendVoiceNote(audioData, duration: duration)
    }
    
    func playVoiceNote(message: BitchatMessage) {
        guard let audioData = message.voiceNoteData else { return }
        
        audioPlayer.togglePlayback(messageID: message.id, audioData: audioData) { result in
            if case .failure(let error) = result {
                print("[AUDIO] Failed to play voice note: \(error)")
            }
        }
    }
}