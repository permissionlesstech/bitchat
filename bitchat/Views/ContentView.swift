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
    @State private var showPasswordInput = false
    @State private var passwordInputChannel: String? = nil
    @State private var passwordInput = ""
    @State private var showPasswordPrompt = false
    @State private var passwordPromptInput = ""
    @State private var showPasswordError = false
    @State private var showCommandSuggestions = false
    @State private var commandSuggestions: [String] = []
    @State private var showLeaveChannelAlert = false
    
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
        ZStack {
            // Main content
            GeometryReader { geometry in
                ZStack {
                    VStack(spacing: 0) {
                        headerView
                        Divider()
                        messagesView
                        Divider()
                        inputView
                    }
                    .background(backgroundColor)
                    .foregroundColor(textColor)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // Only respond to leftward swipes when sidebar is closed
                                // or rightward swipes when sidebar is open
                                if !showSidebar && value.translation.width < 0 {
                                    sidebarDragOffset = max(value.translation.width, -geometry.size.width * 0.7)
                                } else if showSidebar && value.translation.width > 0 {
                                    sidebarDragOffset = min(-geometry.size.width * 0.7 + value.translation.width, 0)
                                }
                            }
                            .onEnded { value in
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    if !showSidebar {
                                        // Opening gesture (swipe left)
                                        if value.translation.width < -100 || (value.translation.width < -50 && value.velocity.width < -500) {
                                            showSidebar = true
                                            sidebarDragOffset = 0
                                        } else {
                                            sidebarDragOffset = 0
                                        }
                                    } else {
                                        // Closing gesture (swipe right)
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
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
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
        .alert("Set Channel Password", isPresented: $showPasswordInput) {
            SecureField("Password", text: $passwordInput)
            Button("Cancel", role: .cancel) {
                passwordInput = ""
                passwordInputChannel = nil
            }
            Button("Set Password") {
                if let channel = passwordInputChannel, !passwordInput.isEmpty {
                    viewModel.setChannelPassword(passwordInput, for: channel)
                    passwordInput = ""
                    passwordInputChannel = nil
                }
            }
        } message: {
            Text("Enter a password to protect \(passwordInputChannel ?? "channel"). Others will need this password to read messages.")
        }
        .alert("Enter Channel Password", isPresented: Binding(
            get: { viewModel.showPasswordPrompt },
            set: { viewModel.showPasswordPrompt = $0 }
        )) {
            SecureField("Password", text: $passwordPromptInput)
            Button("Cancel", role: .cancel) {
                passwordPromptInput = ""
                viewModel.passwordPromptChannel = nil
            }
            Button("Join") {
                if let channel = viewModel.passwordPromptChannel, !passwordPromptInput.isEmpty {
                    let success = viewModel.joinChannel(channel, password: passwordPromptInput)
                    if success {
                        passwordPromptInput = ""
                    } else {
                        // Wrong password - show error
                        passwordPromptInput = ""
                        showPasswordError = true
                    }
                }
            }
        } message: {
            Text("Channel \(viewModel.passwordPromptChannel ?? "") is password protected. Enter the password to join.")
        }
        .alert("Wrong Password", isPresented: $showPasswordError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The password you entered is incorrect. Please try again.")
        }
    }
    
    private var headerView: some View {
        HStack {
            if let privatePeerID = viewModel.selectedPrivateChatPeer,
               let privatePeerNick = viewModel.meshService.getPeerNicknames()[privatePeerID] {
                // Private chat header
                Button(action: {
                    viewModel.endPrivateChat()
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
                        // Dynamic encryption status icon
                        let encryptionStatus = viewModel.getEncryptionStatus(for: privatePeerID)
                        Image(systemName: encryptionStatus.icon)
                            .font(.system(size: 14))
                            .foregroundColor(encryptionStatus == .noiseVerified ? Color.green : 
                                           encryptionStatus == .noiseSecured ? Color.orange :
                                           Color.red)
                            .accessibilityLabel("Encryption status: \(encryptionStatus == .noiseVerified ? "verified" : encryptionStatus == .noiseSecured ? "secured" : "not encrypted")")
                        Text("\(privatePeerNick)")
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.orange)
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
            } else if let currentChannel = viewModel.currentChannel {
                // Channel header
                Button(action: {
                    viewModel.switchToChannel(nil)
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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showSidebar.toggle()
                        sidebarDragOffset = 0
                    }
                }) {
                    HStack(spacing: 4) {
                        if viewModel.passwordProtectedChannels.contains(currentChannel) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color.orange)
                                .accessibilityLabel("Password protected channel")
                        }
                        
                        Text(currentChannel)
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .foregroundColor(viewModel.passwordProtectedChannels.contains(currentChannel) ? Color.orange : Color.blue)
                        
                        // Verification status indicator after channel name
                        if viewModel.passwordProtectedChannels.contains(currentChannel),
                           let status = viewModel.channelVerificationStatus[currentChannel] {
                            switch status {
                            case .verifying:
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            case .verified:
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.green)
                            case .failed:
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.red)
                            case .unverified:
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.gray)
                                    .help("Password verification pending")
                            }
                        } else if viewModel.passwordProtectedChannels.contains(currentChannel) {
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                
                Spacer()
                
                HStack(spacing: 8) {
                    // Show retention indicator for all users
                    if viewModel.retentionEnabledChannels.contains(currentChannel) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color.yellow)
                            .help("Messages in this channel are being saved locally")
                            .accessibilityLabel("Message retention enabled")
                    }
                    
                    // Save button - only for channel owner
                    if viewModel.isChannelOwner(currentChannel) {
                        Button(action: {
                            viewModel.sendMessage("/save")
                        }) {
                            Image(systemName: viewModel.retentionEnabledChannels.contains(currentChannel) ? "bookmark.slash" : "bookmark")
                                .font(.system(size: 16))
                                .foregroundColor(textColor)
                        }
                        .buttonStyle(.plain)
                        .help(viewModel.retentionEnabledChannels.contains(currentChannel) ? "Disable message retention" : "Enable message retention")
                        .accessibilityLabel(viewModel.retentionEnabledChannels.contains(currentChannel) ? "Disable message retention" : "Enable message retention")
                    }
                    
                    // Password button for channel creator only
                    if viewModel.isChannelOwner(currentChannel) {
                        Button(action: {
                            // Toggle password protection
                            if viewModel.passwordProtectedChannels.contains(currentChannel) {
                                viewModel.removeChannelPassword(for: currentChannel)
                            } else {
                                // Show password input
                                showPasswordInput = true
                                passwordInputChannel = currentChannel
                            }
                        }) {
                            Image(systemName: viewModel.passwordProtectedChannels.contains(currentChannel) ? "lock.fill" : "lock")
                                .font(.system(size: 16))
                                .foregroundColor(viewModel.passwordProtectedChannels.contains(currentChannel) ? Color.yellow : textColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(viewModel.passwordProtectedChannels.contains(currentChannel) ? "Remove channel password" : "Set channel password")
                    }
                    
                    // Leave channel button
                    Button(action: {
                        showLeaveChannelAlert = true
                    }) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 16))
                            .foregroundColor(Color.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .alert("leave channel?", isPresented: $showLeaveChannelAlert) {
                        Button("cancel", role: .cancel) { }
                        Button("leave", role: .destructive) {
                            viewModel.leaveChannel(currentChannel)
                        }
                    } message: {
                        Text("sure you want to leave \(currentChannel)?")
                    }
                }
            } else {
                // Public chat header
                HStack(spacing: 4) {
                    Text("bitchat*")
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
                            .onChange(of: viewModel.nickname) { _ in
                                viewModel.saveNickname()
                            }
                            .onSubmit {
                                viewModel.saveNickname()
                            }
                    }
                }
                
                Spacer()
                
                // People counter with unread indicator
                HStack(spacing: 4) {
                    // Check for any unread channel messages
                    let hasUnreadChannelMessages = viewModel.unreadChannelMessages.values.contains { $0 > 0 }
                    
                    if hasUnreadChannelMessages {
                        Image(systemName: "number")
                            .font(.system(size: 12))
                            .foregroundColor(Color.blue)
                            .accessibilityLabel("Unread channel messages")
                    }
                    
                    if !viewModel.unreadPrivateMessages.isEmpty {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color.orange)
                            .accessibilityLabel("Unread private messages")
                    }
                    
                    let otherPeersCount = viewModel.connectedPeers.filter { $0 != viewModel.meshService.myPeerID }.count
                    let channelCount = viewModel.joinedChannels.count
                    
                    HStack(spacing: 4) {
                        // People icon with count
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 11))
                            .accessibilityLabel("\(otherPeersCount) connected \(otherPeersCount == 1 ? "person" : "people")")
                        Text("\(otherPeersCount)")
                            .font(.system(size: 12, design: .monospaced))
                            .accessibilityHidden(true)
                        
                        // Channels icon with count (only if there are channels)
                        if channelCount > 0 {
                            Text("·")
                                .font(.system(size: 12, design: .monospaced))
                            Image(systemName: "square.split.2x2")
                                .font(.system(size: 11))
                                .accessibilityLabel("\(channelCount) active \(channelCount == 1 ? "channel" : "channels")")
                            Text("\(channelCount)")
                                .font(.system(size: 12, design: .monospaced))
                                .accessibilityHidden(true)
                        }
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
        }
        .frame(height: 44) // Fixed height to prevent bouncing
        .padding(.horizontal, 12)
        .background(backgroundColor.opacity(0.95))
    }
    
    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let messages: [BitchatMessage] = {
                        if let privatePeer = viewModel.selectedPrivateChatPeer {
                            let msgs = viewModel.getPrivateChatMessages(for: privatePeer)
                            return msgs
                        } else if let currentChannel = viewModel.currentChannel {
                            let msgs = viewModel.getChannelMessages(currentChannel)
                            return msgs
                        } else {
                            return viewModel.messages
                        }
                    }()
                    
                    ForEach(messages, id: \.id) { message in
                        VStack(alignment: .leading, spacing: 4) {
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
                                VStack(alignment: .leading, spacing: 8) {
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
                                    
                                    // Check for links and show preview
                                    if let markdownLink = message.content.extractMarkdownLink() {
                                        // Don't show link preview if the message is just the emoji
                                        let cleanContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if cleanContent.hasPrefix("👇") {
                                            LinkPreviewView(url: markdownLink.url, title: markdownLink.title)
                                                .padding(.top, 4)
                                        }
                                    } else {
                                        // Check for plain URLs
                                        let urls = message.content.extractURLs()
                                        ForEach(urls.prefix(3), id: \.url) { urlInfo in
                                            LinkPreviewView(url: urlInfo.url, title: nil)
                                                .padding(.top, 4)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                        .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(backgroundColor)
            .onChange(of: viewModel.messages.count) { _ in
                if viewModel.selectedPrivateChatPeer == nil && !viewModel.messages.isEmpty {
                    withAnimation {
                        proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.privateChats) { _ in
                if let peerID = viewModel.selectedPrivateChatPeer,
                   let messages = viewModel.privateChats[peerID],
                   !messages.isEmpty {
                    withAnimation {
                        proxy.scrollTo(messages.last?.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.selectedPrivateChatPeer) { newPeerID in
                // When switching to a private chat, send read receipts
                if let peerID = newPeerID {
                    // Small delay to ensure messages are loaded
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        viewModel.markPrivateMessagesAsRead(from: peerID)
                    }
                }
            }
            .onAppear {
                // Also check when view appears
                if let peerID = viewModel.selectedPrivateChatPeer {
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
                        (["/j", "/join"], "<channel>", "join or create a channel"),
                        (["/m", "/msg"], "<nickname> [message]", "send private message"),
                        (["/channels"], nil, "show all discovered channels"),
                        (["/slap"], "<nickname>", "slap someone with a trout"),
                        (["/unblock"], "<nickname>", "unblock a peer"),
                        (["/w"], nil, "see who's online")
                    ]
                    
                    let channelCommandInfo: [(commands: [String], syntax: String?, description: String)] = [
                        (["/pass"], "[password]", "change channel password"),
                        (["/save"], nil, "save channel messages locally"),
                        (["/transfer"], "<nickname>", "transfer channel ownership")
                    ]
                    
                    // Build the display
                    let allCommands = viewModel.currentChannel != nil 
                        ? commandInfo + channelCommandInfo 
                        : commandInfo
                    
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
            if viewModel.selectedPrivateChatPeer != nil {
                Text("<@\(viewModel.nickname)> →")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 12)
            } else if let currentChannel = viewModel.currentChannel, viewModel.passwordProtectedChannels.contains(currentChannel) {
                Text("<@\(viewModel.nickname)> →")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 12)
            } else {
                Text("<@\(viewModel.nickname)>")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 12)
            }
            
            TextField("", text: $messageText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(textColor)
                .autocorrectionDisabled()
                .focused($isTextFieldFocused)
                .onChange(of: messageText) { newValue in
                    // Get cursor position (approximate - end of text for now)
                    let cursorPosition = newValue.count
                    viewModel.updateAutocomplete(for: newValue, cursorPosition: cursorPosition)
                    
                    // Check for command autocomplete
                    if newValue.hasPrefix("/") && newValue.count >= 1 {
                        // Build context-aware command list
                        var commandDescriptions = [
                            ("/block", "block or list blocked peers"),
                            ("/channels", "show all discovered channels"),
                            ("/clear", "clear chat messages"),
                            ("/hug", "send someone a warm hug"),
                            ("/j", "join or create a channel"),
                            ("/m", "send private message"),
                            ("/slap", "slap someone with a trout"),
                            ("/unblock", "unblock a peer"),
                            ("/w", "see who's online")
                        ]
                        
                        // Add channel-specific commands if in a channel
                        if viewModel.currentChannel != nil {
                            commandDescriptions.append(("/pass", "change channel password"))
                            commandDescriptions.append(("/save", "save channel messages locally"))
                            commandDescriptions.append(("/transfer", "transfer channel ownership"))
                        }
                        
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
                                            (viewModel.selectedPrivateChatPeer != nil ||
                                             (viewModel.currentChannel != nil && viewModel.passwordProtectedChannels.contains(viewModel.currentChannel ?? "")))
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
    
    @ViewBuilder
    private var channelsSection: some View {
        if !viewModel.joinedChannels.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "square.split.2x2")
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text("CHANNELS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundColor(secondaryTextColor)
                .padding(.horizontal, 12)
                
                ForEach(Array(viewModel.joinedChannels).sorted(), id: \.self) { channel in
                    channelButton(for: channel)
                }
            }
        }
    }
    
    @ViewBuilder
    private func channelButton(for channel: String) -> some View {
        Button(action: {
            // Check if channel needs password and we don't have it
            if viewModel.passwordProtectedChannels.contains(channel) && viewModel.channelKeys[channel] == nil {
                // Need password
                viewModel.passwordPromptChannel = channel
                viewModel.showPasswordPrompt = true
            } else {
                // Can enter channel
                viewModel.switchToChannel(channel)
                withAnimation(.spring()) {
                    showSidebar = false
                }
            }
        }) {
            HStack {
                // Lock icon for password protected channels
                if viewModel.passwordProtectedChannels.contains(channel) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(secondaryTextColor)
                        .accessibilityLabel("Password protected")
                }
                
                Text(channel)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(viewModel.currentChannel == channel ? Color.blue : textColor)
                
                Spacer()
                
                // Unread count
                if let unreadCount = viewModel.unreadChannelMessages[channel], unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(backgroundColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .clipShape(Capsule())
                }
                
                // Channel controls
                if viewModel.currentChannel == channel {
                    channelControls(for: channel)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(viewModel.currentChannel == channel ? backgroundColor.opacity(0.5) : Color.clear)
    }
    
    @ViewBuilder
    private func channelControls(for channel: String) -> some View {
        HStack(spacing: 4) {
            // Password button for channel creator only
            if viewModel.isChannelOwner(channel) {
                Button(action: {
                    // Toggle password protection
                    if viewModel.passwordProtectedChannels.contains(channel) {
                        viewModel.removeChannelPassword(for: channel)
                    } else {
                        // Show password input
                        showPasswordInput = true
                        passwordInputChannel = channel
                    }
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: viewModel.passwordProtectedChannels.contains(channel) ? "lock.fill" : "lock")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(viewModel.passwordProtectedChannels.contains(channel) ? backgroundColor : secondaryTextColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(viewModel.passwordProtectedChannels.contains(channel) ? Color.orange : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(viewModel.passwordProtectedChannels.contains(channel) ? Color.orange : secondaryTextColor.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.passwordProtectedChannels.contains(channel) ? "Remove password" : "Set password")
            }
            
            // Leave button
            Button(action: {
                showLeaveChannelAlert = true
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Color.red.opacity(0.6))
            }
            .buttonStyle(.plain)
            .alert("leave channel", isPresented: $showLeaveChannelAlert) {
                Button("cancel", role: .cancel) { }
                Button("leave", role: .destructive) {
                    viewModel.leaveChannel(channel)
                }
            } message: {
                Text("sure you want to leave \(channel)?")
            }
        }
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
                    Text("YOUR NETWORK")
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
                    // Channels section
                    channelsSection
                    
                    if !viewModel.joinedChannels.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    
                    // People section
                    VStack(alignment: .leading, spacing: 8) {
                        // Show appropriate header based on context
                        if let currentChannel = viewModel.currentChannel {
                            Text("IN \(currentChannel.uppercased())")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .padding(.horizontal, 12)
                        } else if !viewModel.connectedPeers.isEmpty {
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
                            Text("No one connected")
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .padding(.horizontal)
                        } else if let currentChannel = viewModel.currentChannel,
                                  let channelMemberIDs = viewModel.channelMembers[currentChannel],
                                  channelMemberIDs.isEmpty {
                            Text("No one in this channel yet")
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .padding(.horizontal)
                        } else {
                            let peerNicknames = viewModel.meshService.getPeerNicknames()
                            let peerRSSI = viewModel.meshService.getPeerRSSI()
                            let myPeerID = viewModel.meshService.myPeerID
                            
                            // Filter peers based on current channel
                            let peersToShow: [String] = {
                                if let currentChannel = viewModel.currentChannel,
                                   let channelMemberIDs = viewModel.channelMembers[currentChannel] {
                                    // Show only peers who have sent messages to this channel (including self)
                                    
                                    // Start with channel members who are also connected
                                    var memberPeers = viewModel.connectedPeers.filter { channelMemberIDs.contains($0) }
                                    
                                    // Always include ourselves if we're a channel member
                                    if channelMemberIDs.contains(myPeerID) && !memberPeers.contains(myPeerID) {
                                        memberPeers.append(myPeerID)
                                    }
                                    
                                    return memberPeers
                                } else {
                                    // Show all connected peers in main chat
                                    return viewModel.connectedPeers
                                }
                            }()
                            
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
                            let rssi = peerRSSI[peerID]?.intValue ?? -100
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
                                } else {
                                    Image(systemName: "radiowaves.left")
                                        .font(.system(size: 12))
                                        .foregroundColor(viewModel.getRSSIColor(rssi: rssi, colorScheme: colorScheme))
                                        .accessibilityLabel("Signal strength: \(rssi > -60 ? "excellent" : rssi > -70 ? "good" : rssi > -80 ? "fair" : "poor")")
                                }
                                
                                // Encryption status icon (between connection dot and name)
                                if !isMe {
                                    let encryptionStatus = viewModel.getEncryptionStatus(for: peerID)
                                    Image(systemName: encryptionStatus.icon)
                                        .font(.system(size: 10))
                                        .foregroundColor(encryptionStatus == .noiseVerified ? Color.green : 
                                                       encryptionStatus == .noiseSecured ? textColor :
                                                       encryptionStatus == .noiseHandshaking ? Color.orange :
                                                       Color.red)
                                        .accessibilityLabel("Encryption: \(encryptionStatus == .noiseVerified ? "verified" : encryptionStatus == .noiseSecured ? "secured" : encryptionStatus == .noiseHandshaking ? "establishing" : "none")")
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
                                    Button(action: {
                                        if peerNicknames[peerID] != nil {
                                            viewModel.startPrivateChat(with: peerID)
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                showSidebar = false
                                                sidebarDragOffset = 0
                                            }
                                        }
                                    }) {
                                        Text(displayName)
                                            .font(.system(size: 14, design: .monospaced))
                                            .foregroundColor(peerNicknames[peerID] != nil ? textColor : secondaryTextColor)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(peerNicknames[peerID] == nil)
                                    .onTapGesture(count: 2) {
                                        // Show fingerprint on double tap
                                        viewModel.showFingerprint(for: peerID)
                                    }
                                    
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
