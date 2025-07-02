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
    @Published var privateMessageNotification: (sender: String, message: String)? = nil
    
    let meshService = BluetoothMeshService()
    private let userDefaults = UserDefaults.standard
    private let nicknameKey = "bitchat.nickname"
    private var nicknameSaveTimer: Timer?
    private var notificationTimer: Timer?
    
    init() {
        loadNickname()
        meshService.delegate = self
        
        // Start mesh service immediately
        meshService.startServices()
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
    
    func sendMessage(_ content: String) {
        guard !content.isEmpty else { return }
        
        if let selectedPeer = selectedPrivateChatPeer {
            // Send as private message
            sendPrivateMessage(content, to: selectedPeer)
        } else {
            // Add message to local display
            let message = BitchatMessage(
                sender: nickname,
                content: content,
                timestamp: Date(),
                isRelay: false,
                originalSender: nil
            )
            messages.append(message)
            
            // Send via mesh
            meshService.sendMessage(content)
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
            senderStyle.foregroundColor = message.sender == nickname ? primaryColor : primaryColor.opacity(0.9)
            senderStyle.font = .system(size: 12, weight: .medium, design: .monospaced)
            result.append(sender.mergingAttributes(senderStyle))
            
            let content = AttributedString(message.content)
            var contentStyle = AttributeContainer()
            contentStyle.font = .system(size: 14, design: .monospaced)
            contentStyle.foregroundColor = isDark ? Color.white : Color.black
            result.append(content.mergingAttributes(contentStyle))
            
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
            print("[DEBUG] Received private message from \(message.sender)")
            
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
                    print("[DEBUG] Added unread message indicator for peer: \(peerID)")
                    
                    // Show notification banner
                    showPrivateMessageNotification(from: message.sender, content: message.content)
                } else {
                    // We're viewing this chat, make sure unread is cleared
                    unreadPrivateMessages.remove(peerID)
                }
            } else if message.sender == nickname {
                // Our own message that was echoed back - ignore it since we already added it locally
                print("[DEBUG] Ignoring our own private message echo")
            }
        } else {
            // Regular public message
            messages.append(message)
        }
        
        #if os(iOS)
        // Different haptic feedback for private vs public messages
        if message.isPrivate && message.sender != nickname {
            // Medium haptic for private messages
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
        } else {
            // Light haptic for public messages
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
        }
        #endif
    }
    
    func didConnectToPeer(_ peerID: String) {
        print("[DEBUG] didConnectToPeer called with: \(peerID)")
        isConnected = true
        let systemMessage = BitchatMessage(
            sender: "system",
            content: "\(peerID) has joined the channel",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil
        )
        messages.append(systemMessage)
        print("[DEBUG] Added join message, total messages: \(messages.count)")
    }
    
    func didDisconnectFromPeer(_ peerID: String) {
        print("[DEBUG] didDisconnectFromPeer called with: \(peerID)")
        let systemMessage = BitchatMessage(
            sender: "system",
            content: "\(peerID) has left the channel",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil
        )
        messages.append(systemMessage)
        print("[DEBUG] Added leave message, total messages: \(messages.count)")
    }
    
    func didUpdatePeerList(_ peers: [String]) {
        print("[DEBUG] ChatViewModel: Peer list updated with \(peers.count) peers: \(peers)")
        connectedPeers = peers
        isConnected = !peers.isEmpty
        
        // If we just disconnected from all peers, ensure UI updates
        if peers.isEmpty && isConnected {
            isConnected = false
        }
        
        // If we're in a private chat with someone who disconnected, exit the chat
        if let currentChatPeer = selectedPrivateChatPeer,
           !peers.contains(currentChatPeer) {
            print("[DEBUG] Private chat peer disconnected, exiting private chat")
            endPrivateChat()
        }
    }
}