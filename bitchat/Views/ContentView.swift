//
// ContentView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Supporting Types

// Pre-computed peer data for performance
struct PeerDisplayData: Identifiable {
    let id: String
    let displayName: String
    let isFavorite: Bool
    let isMe: Bool
    let hasUnreadMessages: Bool
    let encryptionStatus: EncryptionStatus
    let connectionState: BitchatPeer.ConnectionState
    let isMutualFavorite: Bool
}

// MARK: - Lazy Link Preview

// Lazy loading wrapper for link previews
struct LazyLinkPreviewView: View {
    let url: URL
    let title: String?
    @State private var isVisible = false
    
    var body: some View {
        GeometryReader { geometry in
            if isVisible {
                LinkPreviewView(url: url, title: title)
            } else {
                // Placeholder while not visible
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 80)
                    .onAppear {
                        // Only load when view appears on screen
                        isVisible = true
                    }
            }
        }
        .frame(height: 80)
    }
}

// MARK: - Main Content View

struct ContentView: View {
    // MARK: - Properties
    
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var messageText = ""
    @State private var textFieldSelection: NSRange? = nil
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @State private var showPeerList = false
    @State private var showSidebar = false
    @State private var sidebarDragOffset: CGFloat = 0
    @State private var showAppInfo = false
    @State private var showCommandSuggestions = false
    @State private var commandSuggestions: [String] = []
    @State private var backSwipeOffset: CGFloat = 0
    @State private var showPrivateChat = false
    @State private var showMessageActions = false
    @State private var selectedMessageSender: String?
    @State private var selectedMessageSenderID: String?
    @FocusState private var isNicknameFieldFocused: Bool
    @State private var lastScrollTime: Date = .distantPast
    @State private var scrollThrottleTimer: Timer?
    @State private var autocompleteDebounceTimer: Timer?
    
    // MARK: - Computed Properties
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    // MARK: - Body
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Base layer - Main public chat (always visible)
                mainChatView
                
                // Private chat slide-over
                if viewModel.selectedPrivateChatPeer != nil {
                    privateChatView
                        .frame(width: geometry.size.width)
                        .background(backgroundColor)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .trailing)
                        ))
                        .offset(x: showPrivateChat ? -1 : max(0, geometry.size.width))
                        .offset(x: backSwipeOffset.isNaN ? 0 : backSwipeOffset)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if value.translation.width > 0 && !value.translation.width.isNaN {
                                        let maxWidth = max(0, geometry.size.width)
                                        backSwipeOffset = min(value.translation.width, maxWidth.isNaN ? 0 : maxWidth)
                                    }
                                }
                                .onEnded { value in
                                    let translation = value.translation.width.isNaN ? 0 : value.translation.width
                                    let velocity = value.velocity.width.isNaN ? 0 : value.velocity.width
                                    if translation > 50 || (translation > 30 && velocity > 300) {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            showPrivateChat = false
                                            backSwipeOffset = 0
                                            viewModel.endPrivateChat()
                                        }
                                    } else {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            backSwipeOffset = 0
                                        }
                                    }
                                }
                        )
                }
                
                // Sidebar overlay
                HStack(spacing: 0) {
                    // Tap to dismiss area
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSidebar = false
                                sidebarDragOffset = 0
                            }
                        }
                    
                    // Only render sidebar content when it's visible or animating
                    if showSidebar || sidebarDragOffset != 0 {
                        sidebarView
                            #if os(macOS)
                            .frame(width: min(300, max(0, geometry.size.width.isNaN ? 300 : geometry.size.width) * 0.4))
                            #else
                            .frame(width: max(0, geometry.size.width.isNaN ? 300 : geometry.size.width) * 0.7)
                            #endif
                            .transition(.move(edge: .trailing))
                    } else {
                        // Empty placeholder when hidden
                        Color.clear
                            #if os(macOS)
                            .frame(width: min(300, max(0, geometry.size.width.isNaN ? 300 : geometry.size.width) * 0.4))
                            #else
                            .frame(width: max(0, geometry.size.width.isNaN ? 300 : geometry.size.width) * 0.7)
                            #endif
                    }
                }
                .offset(x: {
                    let dragOffset = sidebarDragOffset.isNaN ? 0 : sidebarDragOffset
                    let width = geometry.size.width.isNaN ? 0 : max(0, geometry.size.width)
                    return showSidebar ? -dragOffset : width - dragOffset
                }())
                .animation(.easeInOut(duration: 0.25), value: showSidebar)
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
        .onChange(of: viewModel.selectedPrivateChatPeer) { newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                showPrivateChat = newValue != nil
            }
        }
        .sheet(isPresented: $showAppInfo) {
            AppInfoView()
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showingFingerprintFor != nil },
            set: { _ in viewModel.showingFingerprintFor = nil }
        )) {
            if let peerID = viewModel.showingFingerprintFor {
                FingerprintView(viewModel: viewModel, peerID: peerID)
            }
        }
        .confirmationDialog(
            selectedMessageSender.map { "@\($0)" } ?? "Actions",
            isPresented: $showMessageActions,
            titleVisibility: .visible
        ) {
            Button("private message") {
                if let peerID = selectedMessageSenderID {
                    viewModel.startPrivateChat(with: peerID)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSidebar = false
                        sidebarDragOffset = 0
                    }
                }
            }
            
            Button("hug") {
                if let sender = selectedMessageSender {
                    viewModel.sendMessage("/hug @\(sender)")
                }
            }
            
            Button("slap") {
                if let sender = selectedMessageSender {
                    viewModel.sendMessage("/slap @\(sender)")
                }
            }
            
            Button("BLOCK", role: .destructive) {
                if let sender = selectedMessageSender {
                    viewModel.sendMessage("/block \(sender)")
                }
            }
            
            Button("cancel", role: .cancel) {}
        }
        .alert("Bluetooth Required", isPresented: $viewModel.showBluetoothAlert) {
            Button("Settings") {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #endif
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.bluetoothAlertMessage)
        }
        .onDisappear {
            // Clean up timers
            scrollThrottleTimer?.invalidate()
            autocompleteDebounceTimer?.invalidate()
        }
    }
    
    // MARK: - Message List View
    
    private func messagesView(privatePeer: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Extract messages based on context (private or public chat)
                    let messages: [BitchatMessage] = {
                        if let privatePeer = privatePeer {
                            let msgs = viewModel.getPrivateChatMessages(for: privatePeer)
                            return msgs
                        } else {
                            return viewModel.messages
                        }
                    }()
                    
                    // Implement windowing - show last 100 messages for performance
                    let windowedMessages = messages.suffix(100)
                    
                    ForEach(windowedMessages, id: \.id) { message in
                        VStack(alignment: .leading, spacing: 0) {
                            // Check if current user is mentioned
                            let _ = message.mentions?.contains(viewModel.nickname) ?? false
                            
                            if message.sender == "system" {
                                // System messages
                                Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                // Regular messages with natural text wrapping
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(alignment: .top, spacing: 0) {
                                        // Single text view for natural wrapping
                                        Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        
                                        // Delivery status indicator for private messages
                                        if message.isPrivate && message.sender == viewModel.nickname,
                                           let status = message.deliveryStatus {
                                            DeliveryStatusView(status: status, colorScheme: colorScheme)
                                                .padding(.leading, 4)
                                        }
                                    }
                                    
                                    // Check for plain URLs
                                    let urls = message.content.extractURLs()
                                    if !urls.isEmpty {
                                        ForEach(urls.prefix(3).indices, id: \.self) { index in
                                            let urlInfo = urls[index]
                                            LazyLinkPreviewView(url: urlInfo.url, title: nil)
                                                .padding(.top, 3)
                                                .padding(.horizontal, 1)
                                                .id("\(message.id)-\(urlInfo.url.absoluteString)")
                                        }
                                    }
                                }
                            }
                        }
                        .id(message.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Only show actions for messages from other users (not system or self)
                            if message.sender != "system" && message.sender != viewModel.nickname {
                                selectedMessageSender = message.sender
                                selectedMessageSenderID = message.senderPeerID
                                showMessageActions = true
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(backgroundColor)
            .onTapGesture(count: 3) {
                // Triple-tap to clear current chat
                viewModel.sendMessage("/clear")
            }
            .onChange(of: viewModel.messages.count) { _ in
                if privatePeer == nil && !viewModel.messages.isEmpty {
                    // Throttle scroll animations to prevent excessive UI updates
                    let now = Date()
                    if now.timeIntervalSince(lastScrollTime) > 0.5 {
                        // Immediate scroll if enough time has passed
                        lastScrollTime = now
                        proxy.scrollTo(viewModel.messages.suffix(100).last?.id, anchor: .bottom)
                    } else {
                        // Schedule a delayed scroll
                        scrollThrottleTimer?.invalidate()
                        scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                            lastScrollTime = Date()
                            proxy.scrollTo(viewModel.messages.suffix(100).last?.id, anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: viewModel.privateChats) { _ in
                if let peerID = privatePeer,
                   let messages = viewModel.privateChats[peerID],
                   !messages.isEmpty {
                    // Same throttling for private chats
                    let now = Date()
                    if now.timeIntervalSince(lastScrollTime) > 0.5 {
                        lastScrollTime = now
                        proxy.scrollTo(messages.suffix(100).last?.id, anchor: .bottom)
                    } else {
                        scrollThrottleTimer?.invalidate()
                        scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                            lastScrollTime = Date()
                            proxy.scrollTo(messages.suffix(100).last?.id, anchor: .bottom)
                        }
                    }
                }
            }
            .onAppear {
                // Also check when view appears
                if let peerID = privatePeer {
                    // Try multiple times to ensure read receipts are sent
                    viewModel.markPrivateMessagesAsRead(from: peerID)
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        viewModel.markPrivateMessagesAsRead(from: peerID)
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        viewModel.markPrivateMessagesAsRead(from: peerID)
                    }
                }
            }
        }
    }
    
    // MARK: - Input View
    
    private var inputView: some View {
        VStack(spacing: 0) {
            // @mentions autocomplete
            if viewModel.showAutocomplete && !viewModel.autocompleteSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.autocompleteSuggestions.prefix(4)), id: \.self) { suggestion in
                        Button(action: {
                            _ = viewModel.completeNickname(suggestion, in: &messageText)
                        }) {
                            HStack {
                                Text("@\(suggestion)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(textColor)
                                    .fontWeight(.medium)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .background(Color.gray.opacity(0.1))
                    }
                }
                .background(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(secondaryTextColor.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, 12)
            }
            
            // Command suggestions
            if showCommandSuggestions && !commandSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // Define commands with aliases and syntax
                    let commandInfo: [(commands: [String], syntax: String?, description: String)] = [
                        (["/block"], "[nickname]", "block or list blocked peers"),
                        (["/clear"], nil, "clear chat messages"),
                        (["/hug"], "<nickname>", "send someone a warm hug"),
                        (["/m", "/msg"], "<nickname> [message]", "send private message"),
                        (["/slap"], "<nickname>", "slap someone with a trout"),
                        (["/unblock"], "<nickname>", "unblock a peer"),
                        (["/w"], nil, "see who's online")
                    ]
                    
                    // Build the display
                    let allCommands = commandInfo
                    
                    // Show matching commands
                    ForEach(commandSuggestions, id: \.self) { command in
                        // Find the command info for this suggestion
                        if let info = allCommands.first(where: { $0.commands.contains(command) }) {
                            Button(action: {
                                // Replace current text with selected command
                                messageText = command + " "
                                showCommandSuggestions = false
                                commandSuggestions = []
                            }) {
                                HStack {
                                    // Show all aliases together
                                    Text(info.commands.joined(separator: ", "))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(textColor)
                                        .fontWeight(.medium)
                                    
                                    // Show syntax if any
                                    if let syntax = info.syntax {
                                        Text(syntax)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(secondaryTextColor.opacity(0.8))
                                    }
                                    
                                    Spacer()
                                    
                                    // Show description
                                    Text(info.description)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(secondaryTextColor)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .background(Color.gray.opacity(0.1))
                        }
                    }
                }
                .background(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(secondaryTextColor.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, 12)
            }
            
            HStack(alignment: .center, spacing: 4) {
            TextField("type a message...", text: $messageText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(textColor)
                .focused($isTextFieldFocused)
                .padding(.leading, 12)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: messageText) { newValue in
                    // Cancel previous debounce timer
                    autocompleteDebounceTimer?.invalidate()
                    
                    // Debounce autocomplete updates to reduce calls during rapid typing
                    autocompleteDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
                        // Get cursor position (approximate - end of text for now)
                        let cursorPosition = newValue.count
                        viewModel.updateAutocomplete(for: newValue, cursorPosition: cursorPosition)
                    }
                    
                    // Check for command autocomplete (instant, no debounce needed)
                    if newValue.hasPrefix("/") && newValue.count >= 1 {
                        // Build context-aware command list
                        let commandDescriptions = [
                            ("/block", "block or list blocked peers"),
                            ("/clear", "clear chat messages"),
                            ("/hug", "send someone a warm hug"),
                            ("/m", "send private message"),
                            ("/slap", "slap someone with a trout"),
                            ("/unblock", "unblock a peer"),
                            ("/w", "see who's online")
                        ]
                        
                        let input = newValue.lowercased()
                        
                        // Map of aliases to primary commands
                        let aliases: [String: String] = [
                            "/join": "/j",
                            "/msg": "/m"
                        ]
                        
                        // Filter commands, but convert aliases to primary
                        commandSuggestions = commandDescriptions
                            .filter { $0.0.starts(with: input) }
                            .map { $0.0 }
                        
                        // Also check if input matches an alias
                        for (alias, primary) in aliases {
                            if alias.starts(with: input) && !commandSuggestions.contains(primary) {
                                if commandDescriptions.contains(where: { $0.0 == primary }) {
                                    commandSuggestions.append(primary)
                                }
                            }
                        }
                        
                        // Remove duplicates and sort
                        commandSuggestions = Array(Set(commandSuggestions)).sorted()
                        showCommandSuggestions = !commandSuggestions.isEmpty
                    } else {
                        showCommandSuggestions = false
                        commandSuggestions = []
                    }
                }
                .onSubmit {
                    sendMessage()
                }
            
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(messageText.isEmpty ? Color.gray :
                                            viewModel.selectedPrivateChatPeer != nil
                                             ? Color.orange : textColor)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .accessibilityLabel("Send message")
            .accessibilityHint(messageText.isEmpty ? "Enter a message to send" : "Double tap to send")
            }
            .padding(.vertical, 8)
            .background(backgroundColor.opacity(0.95))
        }
        .onAppear {
            // Delay keyboard focus to avoid iOS constraint warnings
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }
    
    // MARK: - Actions
    
    private func sendMessage() {
        viewModel.sendMessage(messageText)
        messageText = ""
    }
    
    // MARK: - Sidebar View
    
    private var sidebarView: some View {
        HStack(spacing: 0) {
            // Grey vertical bar for visual continuity
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1)
            
            VStack(alignment: .leading, spacing: 0) {
                // Header - match main toolbar height
                HStack {
                    Text("NETWORK")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(textColor)
                    Spacer()
                }
                .frame(height: 44) // Match header height
                .padding(.horizontal, 12)
                .background(backgroundColor.opacity(0.95))
                
                Divider()
            
            // Rooms and People list
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    // People section
                    VStack(alignment: .leading, spacing: 4) {
                        // Show appropriate header based on context
                        if !viewModel.allPeers.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 10))
                                    .accessibilityHidden(true)
                                Text("PEOPLE")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(secondaryTextColor)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                        }
                        
                        if viewModel.allPeers.isEmpty {
                            Text("nobody around...")
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .padding(.horizontal)
                                .padding(.top, 12)
                        } else {
                            // Extract peer data for display
                            let peerNicknames = viewModel.meshService.getPeerNicknames()
                            
                            // Show all peers (connected and favorites)
                            // Pre-compute peer data outside ForEach to reduce overhead
                            let peerData = viewModel.allPeers.map { peer in
                                // Get current myPeerID for each peer to avoid stale values
                                let currentMyPeerID = viewModel.meshService.myPeerID
                                return PeerDisplayData(
                                    id: peer.id,
                                    displayName: peer.id == currentMyPeerID ? viewModel.nickname : peer.nickname,
                                    isFavorite: peer.favoriteStatus?.isFavorite ?? false,
                                    isMe: peer.id == currentMyPeerID,
                                    hasUnreadMessages: viewModel.unreadPrivateMessages.contains(peer.id),
                                    encryptionStatus: viewModel.getEncryptionStatus(for: peer.id),
                                    connectionState: peer.connectionState,
                                    isMutualFavorite: peer.favoriteStatus?.isMutual ?? false
                                )
                            }.sorted { (peer1: PeerDisplayData, peer2: PeerDisplayData) in
                                // Sort: favorites first, then alphabetically by nickname
                                if peer1.isFavorite != peer2.isFavorite {
                                    return peer1.isFavorite
                                }
                                return peer1.displayName < peer2.displayName
                            }
                        
                        ForEach(peerData) { peer in
                            HStack(spacing: 4) {
                                // Signal strength indicator or unread message icon
                                if peer.isMe {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(textColor)
                                        .accessibilityLabel("You")
                                } else if peer.hasUnreadMessages {
                                    Image(systemName: "envelope.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color.orange)
                                        .accessibilityLabel("Unread message from \(peer.displayName)")
                                } else {
                                    // Connection state indicator
                                    switch peer.connectionState {
                                    case .bluetoothConnected:
                                        // Radio icon for mesh connection
                                        Image(systemName: "dot.radiowaves.left.and.right")
                                            .font(.system(size: 10))
                                            .foregroundColor(textColor)
                                            .accessibilityLabel("Connected via mesh")
                                    case .relayConnected:
                                        // Chain link for relay connection
                                        Image(systemName: "link")
                                            .font(.system(size: 10))
                                            .foregroundColor(Color.blue)
                                            .accessibilityLabel("Connected via relay")
                                    case .nostrAvailable:
                                        // Purple globe for mutual favorites reachable via Nostr
                                        Image(systemName: "globe")
                                            .font(.system(size: 10))
                                            .foregroundColor(.purple)
                                            .accessibilityLabel("Available via Nostr")
                                    case .offline:
                                        if peer.isFavorite {
                                            // Crescent moon for non-mutual favorites
                                            Image(systemName: "moon.fill")
                                                .font(.system(size: 10))
                                                .foregroundColor(Color.secondary.opacity(0.5))
                                                .accessibilityLabel("Favorite - Offline")
                                        } else {
                                            // Offline indicator for non-favorites (shouldn't happen since we only show favorites when offline)
                                            Image(systemName: "circle")
                                                .font(.system(size: 8))
                                                .foregroundColor(Color.secondary.opacity(0.3))
                                                .accessibilityLabel("Offline")
                                        }
                                    }
                                }
                                
                                // Peer name
                                if peer.isMe {
                                    HStack {
                                        Text(peer.displayName + " (you)")
                                            .font(.system(size: 14, design: .monospaced))
                                            .foregroundColor(textColor)
                                        
                                        Spacer()
                                    }
                                } else {
                                    Text(peer.displayName)
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundColor(peer.isFavorite || peerNicknames[peer.id] != nil ? textColor : secondaryTextColor)
                                    
                                    // Encryption status icon (after peer name)
                                    if let icon = peer.encryptionStatus.icon {
                                        Image(systemName: icon)
                                            .font(.system(size: 10))
                                            .foregroundColor(peer.encryptionStatus == .noiseVerified ? textColor : 
                                                           peer.encryptionStatus == .noiseSecured ? textColor :
                                                           peer.encryptionStatus == .noiseHandshaking ? Color.orange :
                                                           Color.red)
                                            .accessibilityLabel("Encryption: \(peer.encryptionStatus == .noiseVerified ? "verified" : peer.encryptionStatus == .noiseSecured ? "secured" : peer.encryptionStatus == .noiseHandshaking ? "establishing" : "none")")
                                    }
                                    
                                    Spacer()
                                    
                                    // Favorite star
                                    Button(action: {
                                        viewModel.toggleFavorite(peerID: peer.id)
                                    }) {
                                        Image(systemName: peer.isFavorite ? "star.fill" : "star")
                                            .font(.system(size: 12))
                                            .foregroundColor(peer.isFavorite ? Color.yellow : secondaryTextColor)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(peer.isFavorite ? "Remove \(peer.displayName) from favorites" : "Add \(peer.displayName) to favorites")
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !peer.isMe {
                                    // Allow tapping on any peer (connected or offline favorite)
                                    viewModel.startPrivateChat(with: peer.id)
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showSidebar = false
                                        sidebarDragOffset = 0
                                    }
                                }
                            }
                            .onTapGesture(count: 2) {
                                if !peer.isMe {
                                    // Show fingerprint on double tap
                                    viewModel.showFingerprint(for: peer.id)
                                }
                            }
                        }
                        }
                    }
                }
                .id(viewModel.allPeers.map { "\($0.id)-\($0.isConnected)" }.joined())
            }
            
            Spacer()
        }
        .background(backgroundColor)
        }
    }
    
    // MARK: - View Components
    
    private var mainChatView: some View {
        VStack(spacing: 0) {
            mainHeaderView
            Divider()
            messagesView(privatePeer: nil)
            Divider()
            inputView
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let translation = value.translation.width.isNaN ? 0 : value.translation.width
                    if !showSidebar && translation < 0 {
                        sidebarDragOffset = max(translation, -300)
                    } else if showSidebar && translation > 0 {
                        sidebarDragOffset = min(-300 + translation, 0)
                    }
                }
                .onEnded { value in
                    let translation = value.translation.width.isNaN ? 0 : value.translation.width
                    let velocity = value.velocity.width.isNaN ? 0 : value.velocity.width
                    withAnimation(.easeOut(duration: 0.2)) {
                        if !showSidebar {
                            if translation < -100 || (translation < -50 && velocity < -500) {
                                showSidebar = true
                                sidebarDragOffset = 0
                            } else {
                                sidebarDragOffset = 0
                            }
                        } else {
                            if translation > 100 || (translation > 50 && velocity > 500) {
                                showSidebar = false
                                sidebarDragOffset = 0
                            } else {
                                sidebarDragOffset = 0
                            }
                        }
                    }
                }
        )
    }
    
    private var privateChatView: some View {
        HStack(spacing: 0) {
            // Vertical separator bar
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1)
            
            VStack(spacing: 0) {
                privateHeaderView
                Divider()
                messagesView(privatePeer: viewModel.selectedPrivateChatPeer)
                Divider()
                inputView
            }
            .background(backgroundColor)
            .foregroundColor(textColor)
        }
    }
    
    
    private var mainHeaderView: some View {
        HStack(spacing: 0) {
            Text("bitchat/")
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(textColor)
                .onTapGesture(count: 3) {
                    // PANIC: Triple-tap to clear all data
                    viewModel.panicClearAllData()
                }
                .onTapGesture(count: 1) {
                    // Single tap for app info
                    showAppInfo = true
                }
            
            HStack(spacing: 0) {
                Text("@")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                
                TextField("nickname", text: $viewModel.nickname)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(maxWidth: 100)
                    .foregroundColor(textColor)
                    .focused($isNicknameFieldFocused)
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: isNicknameFieldFocused) { isFocused in
                        if !isFocused {
                            // Only validate when losing focus
                            viewModel.validateAndSaveNickname()
                        }
                    }
                    .onSubmit {
                        viewModel.validateAndSaveNickname()
                    }
            }
            
            Spacer()
            
            // People counter with unread indicator
            HStack(spacing: 4) {
                if !viewModel.unreadPrivateMessages.isEmpty {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.orange)
                        .accessibilityLabel("Unread private messages")
                }
                
                // Single pass to count both metrics
                let peerCounts = viewModel.allPeers.reduce(into: (others: 0, mesh: 0)) { counts, peer in
                    guard peer.id != viewModel.meshService.myPeerID else { return }
                    
                    let isMeshConnected = peer.isConnected || peer.isRelayConnected
                    if isMeshConnected {
                        counts.mesh += 1
                        counts.others += 1
                    } else if peer.isMutualFavorite {
                        counts.others += 1
                    }
                }
                
                let otherPeersCount = peerCounts.others
                let meshPeerCount = peerCounts.mesh
                
                // Purple only if we have peers but none are reachable via mesh (only via Nostr)
                let isNostrOnly = otherPeersCount > 0 && meshPeerCount == 0
                
                HStack(spacing: 4) {
                    // People icon with count
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11))
                        .accessibilityLabel("\(otherPeersCount) \(otherPeersCount == 1 ? "person" : "people")")
                    Text("\(otherPeersCount)")
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityHidden(true)
                }
                .foregroundColor(isNostrOnly ? Color.purple : (meshPeerCount > 0 ? textColor : Color.red))
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSidebar.toggle()
                    sidebarDragOffset = 0
                }
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
        .background(backgroundColor.opacity(0.95))
    }
    
    private var privateHeaderView: some View {
        Group {
            if let privatePeerID = viewModel.selectedPrivateChatPeer {
                privateHeaderContent(for: privatePeerID)
            }
        }
    }
    
    @ViewBuilder
    private func privateHeaderContent(for privatePeerID: String) -> some View {
        // Try to resolve to current peer ID if this is an old one
        // resolveCurrentPeerID not implemented
        let currentPeerID: String = privatePeerID
        
        let peer = viewModel.getPeer(byID: currentPeerID)
        let privatePeerNick = peer?.displayName ?? 
                              viewModel.meshService.getPeerNicknames()[currentPeerID] ?? 
                              FavoritesPersistenceService.shared.getFavoriteStatus(for: Data(hexString: privatePeerID) ?? Data())?.peerNickname ?? 
                              // getFavoriteStatusByNostrKey not implemented
                              // FavoritesPersistenceService.shared.getFavoriteStatusByNostrKey(privatePeerID)?.peerNickname ?? 
                              "Unknown"
        let isNostrAvailable: Bool = {
            guard let connectionState = peer?.connectionState else { 
                // Check if we can reach this peer via Nostr even if not in allPeers
                if let noiseKey = Data(hexString: privatePeerID),
                   let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                   favoriteStatus.isMutual {
                    return true
                }
                return false 
            }
            switch connectionState {
            case .nostrAvailable:
                return true
            default:
                return false
            }
        }()
        
        ZStack {
                    // Center content - always perfectly centered
                    Button(action: {
                        viewModel.showFingerprint(for: privatePeerID)
                    }) {
                        HStack(spacing: 6) {
                            // Show transport icon based on connection state (like peer list)
                            if let connectionState = peer?.connectionState {
                                switch connectionState {
                                case .bluetoothConnected:
                                    // Radio icon for mesh connection
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .font(.system(size: 14))
                                        .foregroundColor(textColor)
                                        .accessibilityLabel("Connected via mesh")
                                case .relayConnected:
                                    // Chain link for relay connection
                                    Image(systemName: "link")
                                        .font(.system(size: 14))
                                        .foregroundColor(Color.blue)
                                        .accessibilityLabel("Connected via relay")
                                case .nostrAvailable:
                                    // Purple globe for Nostr
                                    Image(systemName: "globe")
                                        .font(.system(size: 14))
                                        .foregroundColor(.purple)
                                        .accessibilityLabel("Available via Nostr")
                                case .offline:
                                    // Should not happen for PM header, but handle gracefully
                                    EmptyView()
                                }
                            } else if isNostrAvailable {
                                // Fallback to Nostr if peer not in list but is mutual favorite
                                Image(systemName: "globe")
                                    .font(.system(size: 14))
                                    .foregroundColor(.purple)
                                    .accessibilityLabel("Available via Nostr")
                            }
                            
                            Text("\(privatePeerNick)")
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundColor(textColor)
                            
                            // Dynamic encryption status icon
                            let encryptionStatus = viewModel.getEncryptionStatus(for: privatePeerID)
                            if let icon = encryptionStatus.icon {
                                Image(systemName: icon)
                                    .font(.system(size: 14))
                                    .foregroundColor(encryptionStatus == .noiseVerified ? textColor : 
                                                   encryptionStatus == .noiseSecured ? textColor :
                                                   Color.red)
                                    .accessibilityLabel("Encryption status: \(encryptionStatus == .noiseVerified ? "verified" : encryptionStatus == .noiseSecured ? "secured" : "not encrypted")")
                            }
                        }
                        .accessibilityLabel("Private chat with \(privatePeerNick)")
                        .accessibilityHint("Tap to view encryption fingerprint")
                    }
                    .buttonStyle(.plain)
                    
                    // Left and right buttons positioned with HStack
                    HStack {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showPrivateChat = false
                                viewModel.endPrivateChat()
                            }
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12))
                                .foregroundColor(textColor)
                                .frame(width: 44, height: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Back to main chat")
                        
                        Spacer()
                        
                        // Favorite button
                        Button(action: {
                            viewModel.toggleFavorite(peerID: privatePeerID)
                        }) {
                            Image(systemName: viewModel.isFavorite(peerID: privatePeerID) ? "star.fill" : "star")
                                .font(.system(size: 16))
                                .foregroundColor(viewModel.isFavorite(peerID: privatePeerID) ? Color.yellow : textColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(viewModel.isFavorite(peerID: privatePeerID) ? "Remove from favorites" : "Add to favorites")
                        .accessibilityHint("Double tap to toggle favorite status")
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 12)
                .background(backgroundColor.opacity(0.95))
    }
    
}

// MARK: - Helper Views

// Helper view for rendering message content with clickable hashtags
struct MessageContentView: View {
    let message: BitchatMessage
    let viewModel: ChatViewModel
    let colorScheme: ColorScheme
    let isMentioned: Bool
    
    var body: some View {
        let content = message.content
        let hashtagPattern = "#([a-zA-Z0-9_]+)"
        let mentionPattern = "@([a-zA-Z0-9_]+)"
        
        let hashtagRegex = try? NSRegularExpression(pattern: hashtagPattern, options: [])
        let mentionRegex = try? NSRegularExpression(pattern: mentionPattern, options: [])
        
        let hashtagMatches = hashtagRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        let mentionMatches = mentionRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        
        // Combine all matches and sort by location
        var allMatches: [(range: NSRange, type: String)] = []
        for match in hashtagMatches {
            allMatches.append((match.range(at: 0), "hashtag"))
        }
        for match in mentionMatches {
            allMatches.append((match.range(at: 0), "mention"))
        }
        allMatches.sort { $0.range.location < $1.range.location }
        
        // Build the text as a concatenated Text view for natural wrapping
        let segments = buildTextSegments()
        var result = Text("")
        
        for segment in segments {
            if segment.type == "hashtag" {
                // Note: We can't have clickable links in concatenated Text, so hashtags won't be clickable
                result = result + Text(segment.text)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.blue)
                    .underline()
            } else if segment.type == "mention" {
                result = result + Text(segment.text)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.orange)
            } else {
                result = result + Text(segment.text)
                    .font(.system(size: 14, design: .monospaced))
                    .fontWeight(isMentioned ? .bold : .regular)
            }
        }
        
        return result
            .textSelection(.enabled)
    }
    
    // MARK: - Helper Methods
    
    private func buildTextSegments() -> [(text: String, type: String)] {
        var segments: [(text: String, type: String)] = []
        let content = message.content
        var lastEnd = content.startIndex
        
        let hashtagPattern = "#([a-zA-Z0-9_]+)"
        let mentionPattern = "@([a-zA-Z0-9_]+)"
        
        let hashtagRegex = try? NSRegularExpression(pattern: hashtagPattern, options: [])
        let mentionRegex = try? NSRegularExpression(pattern: mentionPattern, options: [])
        
        let hashtagMatches = hashtagRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        let mentionMatches = mentionRegex?.matches(in: content, options: [], range: NSRange(location: 0, length: content.count)) ?? []
        
        // Combine all matches and sort by location
        var allMatches: [(range: NSRange, type: String)] = []
        for match in hashtagMatches {
            allMatches.append((match.range(at: 0), "hashtag"))
        }
        for match in mentionMatches {
            allMatches.append((match.range(at: 0), "mention"))
        }
        allMatches.sort { $0.range.location < $1.range.location }
        
        for (matchRange, matchType) in allMatches {
            if let range = Range(matchRange, in: content) {
                // Add text before the match
                if lastEnd < range.lowerBound {
                    let beforeText = String(content[lastEnd..<range.lowerBound])
                    if !beforeText.isEmpty {
                        segments.append((beforeText, "text"))
                    }
                }
                
                // Add the match
                let matchText = String(content[range])
                segments.append((matchText, matchType))
                
                lastEnd = range.upperBound
            }
        }
        
        // Add any remaining text
        if lastEnd < content.endIndex {
            let remainingText = String(content[lastEnd...])
            if !remainingText.isEmpty {
                segments.append((remainingText, "text"))
            }
        }
        
        return segments
    }
}

// Delivery status indicator view
struct DeliveryStatusView: View {
    let status: DeliveryStatus
    let colorScheme: ColorScheme
    
    // MARK: - Computed Properties
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    // MARK: - Body
    
    var body: some View {
        switch status {
        case .sending:
            Image(systemName: "circle")
                .font(.system(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.6))
            
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 10))
                .foregroundColor(secondaryTextColor.opacity(0.6))
            
        case .delivered(let nickname, _):
            HStack(spacing: -2) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10))
                Image(systemName: "checkmark")
                    .font(.system(size: 10))
            }
            .foregroundColor(textColor.opacity(0.8))
            .help("Delivered to \(nickname)")
            
        case .read(let nickname, _):
            HStack(spacing: -2) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(Color(red: 0.0, green: 0.478, blue: 1.0))  // Bright blue
            .help("Read by \(nickname)")
            
        case .failed(let reason):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundColor(Color.red.opacity(0.8))
                .help("Failed: \(reason)")
            
        case .partiallyDelivered(let reached, let total):
            HStack(spacing: 1) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10))
                Text("\(reached)/\(total)")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundColor(secondaryTextColor.opacity(0.6))
            .help("Delivered to \(reached) of \(total) members")
        }
    }
}
