//
// ContentView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct ContentView: View {
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
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
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
                        .offset(x: showPrivateChat ? -1 : geometry.size.width)
                        .offset(x: backSwipeOffset)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if value.translation.width > 0 {
                                        backSwipeOffset = min(value.translation.width, geometry.size.width)
                                    }
                                }
                                .onEnded { value in
                                    if value.translation.width > 50 || (value.translation.width > 30 && value.velocity.width > 300) {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            showPrivateChat = false
                                            backSwipeOffset = 0
                                            viewModel.endPrivateChat()
                                        }
                                    } else {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            backSwipeOffset = 0
                                        }
                                    }
                                }
                        )
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showPrivateChat)
                }
                
                // Sidebar overlay
                HStack(spacing: 0) {
                    // Tap to dismiss area
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showSidebar = false
                                sidebarDragOffset = 0
                            }
                        }
                    
                    sidebarView
                        #if os(macOS)
                        .frame(width: min(300, geometry.size.width * 0.4))
                        #else
                        .frame(width: geometry.size.width * 0.7)
                        #endif
                        .transition(.move(edge: .trailing))
                }
                .offset(x: showSidebar ? -sidebarDragOffset : geometry.size.width - sidebarDragOffset)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showSidebar)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sidebarDragOffset)
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
        .onChange(of: viewModel.selectedPrivateChatPeer) { newValue in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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
    }
    
    private func messagesView(privatePeer: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
                    
                    ForEach(Array(windowedMessages), id: \.id) { message in
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
                                        ForEach(Array(urls.prefix(3).enumerated()), id: \.offset) { index, urlInfo in
                                            LinkPreviewView(url: urlInfo.url, title: nil)
                                                .padding(.top, 2)
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
                        .padding(.vertical, 1)
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
                    withAnimation {
                        // Scroll to last message in windowed view
                        let lastId = viewModel.messages.suffix(100).last?.id
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.privateChats) { _ in
                if let peerID = privatePeer,
                   let messages = viewModel.privateChats[peerID],
                   !messages.isEmpty {
                    withAnimation {
                        // Scroll to last message in windowed view
                        let lastId = messages.suffix(100).last?.id
                        proxy.scrollTo(lastId, anchor: .bottom)
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
    
    private var inputView: some View {
        VStack(spacing: 0) {
            // @mentions autocomplete
            if viewModel.showAutocomplete && !viewModel.autocompleteSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.autocompleteSuggestions.enumerated()), id: \.element) { index, suggestion in
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
                .onChange(of: messageText) { newValue in
                    // Get cursor position (approximate - end of text for now)
                    let cursorPosition = newValue.count
                    viewModel.updateAutocomplete(for: newValue, cursorPosition: cursorPosition)
                    
                    // Check for command autocomplete
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
            isTextFieldFocused = true
        }
    }
    
    private func sendMessage() {
        viewModel.sendMessage(messageText)
        messageText = ""
    }
    
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
                VStack(alignment: .leading, spacing: 12) {
                    // People section
                    VStack(alignment: .leading, spacing: 8) {
                        // Show appropriate header based on context
                        if !viewModel.connectedPeers.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 10))
                                    .accessibilityHidden(true)
                                Text("PEOPLE")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(secondaryTextColor)
                            .padding(.horizontal, 12)
                        }
                        
                        if viewModel.connectedPeers.isEmpty {
                            Text("nobody around...")
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .padding(.horizontal)
                        } else {
                            let peerNicknames = viewModel.meshService.getPeerNicknames()
                            let peerRSSI = viewModel.meshService.getPeerRSSI()
                            let myPeerID = viewModel.meshService.myPeerID
                            
                            // Show all connected peers
                            let peersToShow: [String] = viewModel.connectedPeers
                            
                        // Sort peers: favorites first, then alphabetically by nickname
                        let sortedPeers = peersToShow.sorted { peer1, peer2 in
                            let isFav1 = viewModel.isFavorite(peerID: peer1)
                            let isFav2 = viewModel.isFavorite(peerID: peer2)
                            
                            if isFav1 != isFav2 {
                                return isFav1 // Favorites come first
                            }
                            
                            let name1 = peerNicknames[peer1] ?? "anon\(peer1.prefix(4))"
                            let name2 = peerNicknames[peer2] ?? "anon\(peer2.prefix(4))"
                            return name1 < name2
                        }
                        
                        ForEach(sortedPeers, id: \.self) { peerID in
                            let displayName = peerID == myPeerID ? viewModel.nickname : (peerNicknames[peerID] ?? "anon\(peerID.prefix(4))")
                            let rssi = peerRSSI[peerID]?.intValue
                            let isFavorite = viewModel.isFavorite(peerID: peerID)
                            let isMe = peerID == myPeerID
                            
                            HStack(spacing: 8) {
                                // Signal strength indicator or unread message icon
                                if isMe {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(textColor)
                                        .accessibilityLabel("You")
                                } else if viewModel.unreadPrivateMessages.contains(peerID) {
                                    Image(systemName: "envelope.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color.orange)
                                        .accessibilityLabel("Unread message from \(displayName)")
                                } else if let rssi = rssi {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundColor(viewModel.getRSSIColor(rssi: rssi, colorScheme: colorScheme))
                                        .accessibilityLabel("Signal strength: \(rssi > -60 ? "excellent" : rssi > -70 ? "good" : rssi > -80 ? "fair" : "poor")")
                                } else {
                                    // No RSSI data available
                                    Image(systemName: "circle")
                                        .font(.system(size: 8))
                                        .foregroundColor(Color.secondary.opacity(0.5))
                                        .accessibilityLabel("Signal strength: unknown")
                                }
                                
                                // Peer name
                                if isMe {
                                    HStack {
                                        Text(displayName + " (you)")
                                            .font(.system(size: 14, design: .monospaced))
                                            .foregroundColor(textColor)
                                        
                                        Spacer()
                                    }
                                } else {
                                    Text(displayName)
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundColor(peerNicknames[peerID] != nil ? textColor : secondaryTextColor)
                                    
                                    // Encryption status icon (after peer name)
                                    let encryptionStatus = viewModel.getEncryptionStatus(for: peerID)
                                    Image(systemName: encryptionStatus.icon)
                                        .font(.system(size: 10))
                                        .foregroundColor(encryptionStatus == .noiseVerified ? Color.green : 
                                                       encryptionStatus == .noiseSecured ? textColor :
                                                       encryptionStatus == .noiseHandshaking ? Color.orange :
                                                       Color.red)
                                        .accessibilityLabel("Encryption: \(encryptionStatus == .noiseVerified ? "verified" : encryptionStatus == .noiseSecured ? "secured" : encryptionStatus == .noiseHandshaking ? "establishing" : "none")")
                                    
                                    Spacer()
                                    
                                    // Favorite star
                                    Button(action: {
                                        viewModel.toggleFavorite(peerID: peerID)
                                    }) {
                                        Image(systemName: isFavorite ? "star.fill" : "star")
                                            .font(.system(size: 12))
                                            .foregroundColor(isFavorite ? Color.yellow : secondaryTextColor)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(isFavorite ? "Remove \(displayName) from favorites" : "Add \(displayName) to favorites")
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !isMe && peerNicknames[peerID] != nil {
                                    viewModel.startPrivateChat(with: peerID)
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        showSidebar = false
                                        sidebarDragOffset = 0
                                    }
                                }
                            }
                            .onTapGesture(count: 2) {
                                if !isMe {
                                    // Show fingerprint on double tap
                                    viewModel.showFingerprint(for: peerID)
                                }
                            }
                        }
                        }
                    }
                }
                .padding(.vertical, 8)
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
                    if !showSidebar && value.translation.width < 0 {
                        sidebarDragOffset = max(value.translation.width, -300)
                    } else if showSidebar && value.translation.width > 0 {
                        sidebarDragOffset = min(-300 + value.translation.width, 0)
                    }
                }
                .onEnded { value in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        if !showSidebar {
                            if value.translation.width < -100 || (value.translation.width < -50 && value.velocity.width < -500) {
                                showSidebar = true
                                sidebarDragOffset = 0
                            } else {
                                sidebarDragOffset = 0
                            }
                        } else {
                            if value.translation.width > 100 || (value.translation.width > 50 && value.velocity.width > 500) {
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
                
                let otherPeersCount = viewModel.connectedPeers.filter { $0 != viewModel.meshService.myPeerID }.count
                
                HStack(spacing: 4) {
                    // People icon with count
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11))
                        .accessibilityLabel("\(otherPeersCount) connected \(otherPeersCount == 1 ? "person" : "people")")
                    Text("\(otherPeersCount)")
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityHidden(true)
                }
                .foregroundColor(viewModel.isConnected ? textColor : Color.red)
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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
            if let privatePeerID = viewModel.selectedPrivateChatPeer,
               let privatePeerNick = viewModel.meshService.getPeerNicknames()[privatePeerID] {
                HStack {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showPrivateChat = false
                            viewModel.endPrivateChat()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12))
                            Text("back")
                                .font(.system(size: 14, design: .monospaced))
                        }
                        .foregroundColor(textColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to main chat")
                    
                    Spacer()
                    
                    Button(action: {
                        viewModel.showFingerprint(for: privatePeerID)
                    }) {
                        HStack(spacing: 6) {
                            Text("\(privatePeerNick)")
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundColor(Color.orange)
                            // Dynamic encryption status icon
                            let encryptionStatus = viewModel.getEncryptionStatus(for: privatePeerID)
                            Image(systemName: encryptionStatus.icon)
                                .font(.system(size: 14))
                                .foregroundColor(encryptionStatus == .noiseVerified ? Color.green : 
                                               encryptionStatus == .noiseSecured ? Color.orange :
                                               Color.red)
                                .accessibilityLabel("Encryption status: \(encryptionStatus == .noiseVerified ? "verified" : encryptionStatus == .noiseSecured ? "secured" : "not encrypted")")
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Private chat with \(privatePeerNick)")
                        .accessibilityHint("Tap to view encryption fingerprint")
                    }
                    .buttonStyle(.plain)
                    
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
                .frame(height: 44)
                .padding(.horizontal, 12)
                .background(backgroundColor.opacity(0.95))
            } else {
                EmptyView()
            }
        }
    }
    
}

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
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
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
