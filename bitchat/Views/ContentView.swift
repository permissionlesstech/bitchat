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
    @State private var passwordInputRoom: String? = nil
    @State private var passwordInput = ""
    @State private var showPasswordPrompt = false
    @State private var passwordPromptInput = ""
    @State private var showPasswordError = false
    @State private var showCommandSuggestions = false
    @State private var commandSuggestions: [String] = []
    @State private var showNetworkStatus = false
    @State private var transportButtonFrame: CGRect = .zero
    @State private var networkStatusDebounceTimer: Timer?
    
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
            
            // Network Status Overlay
            if showNetworkStatus {
                Color.black.opacity(0.001) // Invisible tap area
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showNetworkStatus = false
                        }
                    }
                
                GeometryReader { geometry in
                    VStack {
                        HStack {
                            Spacer()
                            
                            networkStatusView
                                .fixedSize()
                            .padding(.trailing, transportButtonFrame.width > 0 ? 
                                geometry.size.width - transportButtonFrame.maxX + (transportButtonFrame.width / 2) - 140 : 25)
                        }
                        .padding(.top, transportButtonFrame.height > 0 ? 
                            transportButtonFrame.maxY + 8 : 52)
                        
                        Spacer()
                    }
                    .transition(.scale(scale: 0.95, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            
            // Autocomplete overlay
            if viewModel.showAutocomplete && !viewModel.autocompleteSuggestions.isEmpty {
                GeometryReader { geometry in
                    VStack {
                        Spacer()
                        HStack {
                            // Calculate approximate position based on nickname length and @ position
                            let nicknameWidth: CGFloat = viewModel.selectedPrivateChatPeer != nil ? 90 : 80
                            let charWidth: CGFloat = 8.5 // Approximate width of monospace character
                            let atPosition = CGFloat(viewModel.autocompleteRange?.location ?? 0)
                            let offsetX = nicknameWidth + (atPosition * charWidth)
                            
                            // Ensure offsetX is valid (not NaN or infinite)
                            let safeOffsetX = offsetX.isFinite ? offsetX : nicknameWidth
                            
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(viewModel.autocompleteSuggestions.enumerated()), id: \.element) { index, suggestion in
                                    Button(action: {
                                        _ = viewModel.completeNickname(suggestion, in: &messageText)
                                    }) {
                                        HStack {
                                            Text("@\(suggestion)")
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundColor(index == viewModel.selectedAutocompleteIndex ? backgroundColor : textColor)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(index == viewModel.selectedAutocompleteIndex ? textColor : Color.clear)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .background(backgroundColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(secondaryTextColor.opacity(0.5), lineWidth: 1)
                            )
                            .frame(width: 150, alignment: .leading)
                            .offset(x: min(safeOffsetX, max(0, geometry.size.width - 180))) // Prevent going off-screen
                            .padding(.bottom, 45) // Position just above input
                            
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
        .sheet(isPresented: $showAppInfo) {
            AppInfoView()
        }
        .alert("Set Room Password", isPresented: $showPasswordInput) {
            SecureField("Password", text: $passwordInput)
            Button("Cancel", role: .cancel) {
                passwordInput = ""
                passwordInputRoom = nil
            }
            Button("Set Password") {
                if let room = passwordInputRoom, !passwordInput.isEmpty {
                    viewModel.setRoomPassword(passwordInput, for: room)
                    passwordInput = ""
                    passwordInputRoom = nil
                }
            }
        } message: {
            Text("Enter a password to protect \(passwordInputRoom ?? "room"). Others will need this password to read messages.")
        }
        .alert("Enter Room Password", isPresented: Binding(
            get: { viewModel.showPasswordPrompt },
            set: { viewModel.showPasswordPrompt = $0 }
        )) {
            SecureField("Password", text: $passwordPromptInput)
            Button("Cancel", role: .cancel) {
                passwordPromptInput = ""
                viewModel.passwordPromptRoom = nil
            }
            Button("Join") {
                if let room = viewModel.passwordPromptRoom, !passwordPromptInput.isEmpty {
                    let success = viewModel.joinRoom(room, password: passwordPromptInput)
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
            Text("Room \(viewModel.passwordPromptRoom ?? "") is password protected. Enter the password to join.")
        }
        .alert("Wrong Password", isPresented: $showPasswordError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The password you entered is incorrect. Please try again.")
        }
        .coordinateSpace(name: "ContentView")
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
                
                Spacer()
                
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color.orange)
                    Text("private: \(privatePeerNick)")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.orange)
                }
                .frame(maxWidth: .infinity)
                
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
            } else if let currentRoom = viewModel.currentRoom {
                // Room header
                Button(action: {
                    viewModel.switchToRoom(nil)
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
                
                Spacer()
                
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showSidebar.toggle()
                        sidebarDragOffset = 0
                    }
                }) {
                    HStack(spacing: 6) {
                        if viewModel.passwordProtectedRooms.contains(currentRoom) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color.orange)
                        }
                        Text("room: \(currentRoom)")
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .foregroundColor(viewModel.passwordProtectedRooms.contains(currentRoom) ? Color.orange : Color.blue)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                
                Spacer()
                
                HStack(spacing: 8) {
                    // Show retention indicator for all users
                    if viewModel.retentionEnabledRooms.contains(currentRoom) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color.yellow)
                            .help("Messages in this room are being saved locally")
                    }
                    
                    // Save button - only for room owner
                    if viewModel.roomCreators[currentRoom] == viewModel.meshService.myPeerID {
                        Button(action: {
                            viewModel.sendMessage("/save")
                        }) {
                            Image(systemName: viewModel.retentionEnabledRooms.contains(currentRoom) ? "bookmark.slash" : "bookmark")
                                .font(.system(size: 16))
                                .foregroundColor(textColor)
                        }
                        .buttonStyle(.plain)
                        .help(viewModel.retentionEnabledRooms.contains(currentRoom) ? "Disable message retention" : "Enable message retention")
                    }
                    
                    // Password button for room creator only
                    if viewModel.roomCreators[currentRoom] == viewModel.meshService.myPeerID {
                        Button(action: {
                            // Toggle password protection
                            if viewModel.passwordProtectedRooms.contains(currentRoom) {
                                viewModel.removeRoomPassword(for: currentRoom)
                            } else {
                                // Show password input
                                showPasswordInput = true
                                passwordInputRoom = currentRoom
                            }
                        }) {
                            Image(systemName: viewModel.passwordProtectedRooms.contains(currentRoom) ? "lock.fill" : "lock")
                                .font(.system(size: 16))
                                .foregroundColor(viewModel.passwordProtectedRooms.contains(currentRoom) ? Color.yellow : textColor)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // Leave room button
                    Button(action: {
                        viewModel.leaveRoom(currentRoom)
                    }) {
                        Text("leave")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color.red)
                    }
                    .buttonStyle(.plain)
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
                
                // Transport indicator
                Button(action: {
                    // Debounce rapid taps
                    networkStatusDebounceTimer?.invalidate()
                    networkStatusDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            showNetworkStatus.toggle()
                        }
                    }
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: viewModel.transportManager.currentTransportInfo.iconName)
                            .font(.system(size: 14))
                            .foregroundColor(viewModel.transportManager.currentTransportInfo.isBridging ? Color.purple : textColor)
                        
                        // Show secondary icon if both transports are active
                        if let secondaryIcon = viewModel.transportManager.currentTransportInfo.secondaryIconName {
                            Image(systemName: secondaryIcon)
                                .font(.system(size: 14))
                                .foregroundColor(textColor.opacity(0.7))
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Transport: \(viewModel.transportManager.currentTransportInfo.displayText)")
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .preference(key: TransportButtonFrameKey.self, value: geometry.frame(in: .named("ContentView")))
                    }
                )
                .onPreferenceChange(TransportButtonFrameKey.self) { frame in
                    transportButtonFrame = frame
                }
                
                Divider()
                    .frame(height: 16)
                
                // People counter with unread indicator
                HStack(spacing: 4) {
                    // Check for any unread room messages
                    let hasUnreadRoomMessages = viewModel.unreadRoomMessages.values.contains { $0 > 0 }
                    
                    if hasUnreadRoomMessages {
                        Image(systemName: "number")
                            .font(.system(size: 12))
                            .foregroundColor(Color.blue)
                    }
                    
                    if !viewModel.unreadPrivateMessages.isEmpty {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color.orange)
                    }
                    
                    let otherPeersCount = viewModel.connectedPeers.filter { $0 != viewModel.meshService.myPeerID }.count
                    let roomCount = viewModel.joinedRooms.count
                    let statusText = if !viewModel.isConnected {
                        "alone :/"
                    } else if roomCount > 0 {
                        "\(otherPeersCount) \(otherPeersCount == 1 ? "person" : "people")/\(roomCount) \(roomCount == 1 ? "room" : "rooms")"
                    } else {
                        "\(otherPeersCount) \(otherPeersCount == 1 ? "person" : "people")"
                    }
                    Text(statusText)
                        .font(.system(size: 12, design: .monospaced))
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
                            // Log what we're showing
                            // Removed debug logging
                            return msgs
                        } else if let currentRoom = viewModel.currentRoom {
                            return viewModel.getRoomMessages(currentRoom)
                        } else {
                            return viewModel.messages
                        }
                    }()
                    
                    ForEach(messages, id: \.id) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            // Check if current user is mentioned
                            let isMentioned = message.mentions?.contains(viewModel.nickname) ?? false
                            
                            if message.sender == "system" {
                                // System messages
                                Text(viewModel.formatMessage(message, colorScheme: colorScheme))
                                    .font(.system(size: 14, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            } else {
                                // Regular messages with tappable sender name
                                HStack(alignment: .center, spacing: 0) {
                                    // Timestamp
                                    Text("[\(viewModel.formatTimestamp(message.timestamp))] ")
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundColor(secondaryTextColor)
                                        .textSelection(.enabled)
                                    
                                    // Tappable sender name
                                    if message.sender != viewModel.nickname {
                                        Button(action: {
                                            if let peerID = message.senderPeerID ?? viewModel.getPeerIDForNickname(message.sender) {
                                                viewModel.startPrivateChat(with: peerID)
                                            }
                                        }) {
                                            let senderColor = viewModel.getSenderColor(for: message, colorScheme: colorScheme)
                                            Text("<@\(message.sender)>")
                                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                                .foregroundColor(senderColor)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        // Own messages not tappable
                                        Text("<@\(message.sender)>")
                                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                                            .foregroundColor(textColor)
                                            .textSelection(.enabled)
                                    }
                                    
                                    Text(" ")
                                    
                                    // Message content with clickable hashtags
                                    MessageContentView(
                                        message: message,
                                        viewModel: viewModel,
                                        colorScheme: colorScheme,
                                        isMentioned: isMentioned
                                    )
                                    
                                    // Delivery status indicator for private messages
                                    if message.isPrivate && message.sender == viewModel.nickname,
                                       let status = message.deliveryStatus {
                                        DeliveryStatusView(status: status, colorScheme: colorScheme)
                                            .padding(.leading, 4)
                                            .alignmentGuide(.firstTextBaseline) { _ in 12 }
                                    }
                                    
                                    Spacer()
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
            // Command suggestions
            if showCommandSuggestions && !commandSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    let baseCommands: [String: String] = [
                        "/j": "join or create a room",
                        "/rooms": "show all discovered rooms",
                        "/w": "see who's online",
                        "/m": "send private message",
                        "/clear": "clear chat messages"
                    ]
                    
                    let roomCommands: [String: String] = [
                        "/transfer": "transfer room ownership",
                        "/pass": "change room password",
                        "/save": "save room messages locally"
                    ]
                    
                    let commandDescriptions = viewModel.currentRoom != nil 
                        ? baseCommands.merging(roomCommands) { (_, new) in new }
                        : baseCommands
                    
                    ForEach(commandSuggestions, id: \.self) { command in
                        Button(action: {
                            // Replace current text with selected command
                            messageText = command + " "
                            showCommandSuggestions = false
                            commandSuggestions = []
                        }) {
                            HStack {
                                Text(command)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(textColor)
                                    .fontWeight(.medium)
                                Spacer()
                                if let description = commandDescriptions[command] {
                                    Text(description)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(secondaryTextColor)
                                }
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
                .padding(.bottom, 4)
            }
            
            HStack(alignment: .center, spacing: 4) {
            if viewModel.selectedPrivateChatPeer != nil {
                Text("<@\(viewModel.nickname)> →")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 12)
            } else if let currentRoom = viewModel.currentRoom, viewModel.passwordProtectedRooms.contains(currentRoom) {
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
                .focused($isTextFieldFocused)
                .onChange(of: messageText) { newValue in
                    // Get cursor position (approximate - end of text for now)
                    let cursorPosition = newValue.count
                    viewModel.updateAutocomplete(for: newValue, cursorPosition: cursorPosition)
                    
                    // Check for command autocomplete
                    if newValue.hasPrefix("/") && newValue.count >= 1 {
                        // Build context-aware command list
                        var commandDescriptions = [
                            ("/j", "join or create a room"),
                            ("/rooms", "show all discovered rooms"),
                            ("/w", "see who's online"),
                            ("/m", "send private message"),
                            ("/clear", "clear chat messages")
                        ]
                        
                        // Add room-specific commands if in a room
                        if viewModel.currentRoom != nil {
                            commandDescriptions.append(("/transfer", "transfer room ownership"))
                            commandDescriptions.append(("/pass", "change room password"))
                            commandDescriptions.append(("/save", "save room messages locally"))
                        }
                        
                        let input = newValue.lowercased()
                        commandSuggestions = commandDescriptions
                            .filter { $0.0.starts(with: input) }
                            .map { $0.0 }
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
                    .foregroundColor((viewModel.selectedPrivateChatPeer != nil || 
                                     (viewModel.currentRoom != nil && viewModel.passwordProtectedRooms.contains(viewModel.currentRoom ?? ""))) 
                                     ? Color.orange : textColor)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
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
                    Text("connected")
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
                    // Joined Rooms section
                    if !viewModel.joinedRooms.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ROOMS")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .padding(.horizontal, 12)
                            
                            ForEach(Array(viewModel.joinedRooms).sorted(), id: \.self) { room in
                                Button(action: {
                                    // Check if room needs password and we don't have it
                                    if viewModel.passwordProtectedRooms.contains(room) && viewModel.roomKeys[room] == nil {
                                        // Need password
                                        viewModel.passwordPromptRoom = room
                                        viewModel.showPasswordPrompt = true
                                    } else {
                                        // Can enter room
                                        viewModel.switchToRoom(room)
                                        withAnimation(.spring()) {
                                            showSidebar = false
                                        }
                                    }
                                }) {
                                    HStack {
                                        // Lock icon for password protected rooms
                                        if viewModel.passwordProtectedRooms.contains(room) {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 10))
                                                .foregroundColor(secondaryTextColor)
                                        }
                                        
                                        Text(room)
                                            .font(.system(size: 14, design: .monospaced))
                                            .foregroundColor(viewModel.currentRoom == room ? Color.blue : textColor)
                                        
                                        Spacer()
                                        
                                        // Unread count
                                        if let unreadCount = viewModel.unreadRoomMessages[room], unreadCount > 0 {
                                            Text("\(unreadCount)")
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .foregroundColor(backgroundColor)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.orange)
                                                .clipShape(Capsule())
                                        }
                                        
                                        // Room controls
                                        if viewModel.currentRoom == room {
                                            HStack(spacing: 4) {
                                                // Password button for room creator only
                                                if viewModel.roomCreators[room] == viewModel.meshService.myPeerID {
                                                    Button(action: {
                                                        // Toggle password protection
                                                        if viewModel.passwordProtectedRooms.contains(room) {
                                                            viewModel.removeRoomPassword(for: room)
                                                        } else {
                                                            // Show password input
                                                            showPasswordInput = true
                                                            passwordInputRoom = room
                                                        }
                                                    }) {
                                                        HStack(spacing: 2) {
                                                            Image(systemName: viewModel.passwordProtectedRooms.contains(room) ? "lock.fill" : "lock")
                                                                .font(.system(size: 10))
                                                        }
                                                        .foregroundColor(viewModel.passwordProtectedRooms.contains(room) ? backgroundColor : secondaryTextColor)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 2)
                                                        .background(viewModel.passwordProtectedRooms.contains(room) ? Color.orange : Color.clear)
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 4)
                                                                .stroke(viewModel.passwordProtectedRooms.contains(room) ? Color.orange : secondaryTextColor.opacity(0.5), lineWidth: 1)
                                                        )
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                                
                                                // Leave button
                                                Button(action: {
                                                    viewModel.leaveRoom(room)
                                                }) {
                                                    Text("leave room")
                                                        .font(.system(size: 10, design: .monospaced))
                                                        .foregroundColor(secondaryTextColor)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 2)
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 4)
                                                                .stroke(secondaryTextColor.opacity(0.5), lineWidth: 1)
                                                        )
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(viewModel.currentRoom == room ? backgroundColor.opacity(0.5) : Color.clear)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                        Divider()
                            .padding(.vertical, 4)
                    }
                    
                    // People section
                    VStack(alignment: .leading, spacing: 8) {
                        // Show appropriate header based on context
                        if let currentRoom = viewModel.currentRoom {
                            Text("IN \(currentRoom.uppercased())")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .padding(.horizontal, 12)
                        } else if !viewModel.connectedPeers.isEmpty {
                            Text("PEOPLE")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .padding(.horizontal, 12)
                        }
                        
                        if viewModel.connectedPeers.isEmpty {
                            Text("No one connected")
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .padding(.horizontal)
                        } else if let currentRoom = viewModel.currentRoom,
                                  let roomMemberIDs = viewModel.roomMembers[currentRoom],
                                  roomMemberIDs.isEmpty {
                            Text("No one in this room yet")
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .padding(.horizontal)
                        } else {
                            let peerNicknames = viewModel.meshService.getPeerNicknames()
                            let peerRSSI = viewModel.meshService.getPeerRSSI()
                            let myPeerID = viewModel.meshService.myPeerID
                            
                            // Filter peers based on current room
                            let peersToShow: [String] = {
                                if let currentRoom = viewModel.currentRoom,
                                   let roomMemberIDs = viewModel.roomMembers[currentRoom] {
                                    // Show only peers who have sent messages to this room (including self)
                                    
                                    // Start with room members who are also connected
                                    var memberPeers = viewModel.connectedPeers.filter { roomMemberIDs.contains($0) }
                                    
                                    // Always include ourselves if we're a room member
                                    if roomMemberIDs.contains(myPeerID) && !memberPeers.contains(myPeerID) {
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
                            
                            let name1 = peerNicknames[peer1] ?? "person-\(peer1.prefix(4))"
                            let name2 = peerNicknames[peer2] ?? "person-\(peer2.prefix(4))"
                            return name1 < name2
                        }
                        
                        ForEach(sortedPeers, id: \.self) { peerID in
                            let displayName = peerID == myPeerID ? viewModel.nickname : (peerNicknames[peerID] ?? "person-\(peerID.prefix(4))")
                            let rssi = peerRSSI[peerID]?.intValue ?? -100
                            let isFavorite = viewModel.isFavorite(peerID: peerID)
                            let isMe = peerID == myPeerID
                            let peerTransports = viewModel.transportManager.getPeerTransports(peerID)
                            
                            HStack(spacing: 8) {
                                // Signal strength indicator or unread message icon
                                if isMe {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(textColor)
                                } else if viewModel.unreadPrivateMessages.contains(peerID) {
                                    Image(systemName: "envelope.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color.orange)
                                } else {
                                    Circle()
                                        .fill(viewModel.getRSSIColor(rssi: rssi, colorScheme: colorScheme))
                                        .frame(width: 8, height: 8)
                                }
                                
                                // Favorite star (not for self)
                                if !isMe {
                                    Button(action: {
                                        viewModel.toggleFavorite(peerID: peerID)
                                    }) {
                                        Image(systemName: isFavorite ? "star.fill" : "star")
                                            .font(.system(size: 12))
                                            .foregroundColor(isFavorite ? Color.yellow : secondaryTextColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                // Peer name
                                if isMe {
                                    HStack {
                                        Text(displayName + " (you)")
                                            .font(.system(size: 14, design: .monospaced))
                                            .foregroundColor(textColor)
                                        
                                        Spacer()
                                        
                                        // Transport indicators
                                        HStack(spacing: 2) {
                                            if peerTransports.contains(.bluetooth) {
                                                Image(systemName: "dot.radiowaves.left.and.right")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Color.blue.opacity(0.7))
                                            }
                                            if peerTransports.contains(.wifiDirect) {
                                                Image(systemName: "wifi")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Color.green.opacity(0.7))
                                            }
                                        }
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
                                        HStack {
                                            Text(displayName)
                                                .font(.system(size: 14, design: .monospaced))
                                                .foregroundColor(peerNicknames[peerID] != nil ? textColor : secondaryTextColor)
                                            
                                            Spacer()
                                            
                                            // Transport indicators
                                            HStack(spacing: 2) {
                                                if peerTransports.contains(.bluetooth) {
                                                    Image(systemName: "dot.radiowaves.left.and.right")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(Color.blue.opacity(0.7))
                                                }
                                                if peerTransports.contains(.wifiDirect) {
                                                    Image(systemName: "wifi")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(Color.green.opacity(0.7))
                                                }
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(peerNicknames[peerID] == nil)
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
    
    private var networkStatusView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title
            Text("Network Status")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(textColor)
            
            Divider()
            
            // Transport Status
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Active Transports")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                } icon: {
                    Image(systemName: "network")
                        .font(.system(size: 12))
                }
                .foregroundColor(textColor)
                
                HStack(spacing: 4) {
                    // Combined peer count display
                    let btCount = viewModel.transportManager.currentTransportInfo.bluetoothPeerCount
                    let wifiCount = viewModel.transportManager.currentTransportInfo.wifiDirectPeerCount
                    let isWiFiActive = viewModel.transportManager.currentTransportInfo.isWiFiDirectActive
                    
                    HStack(spacing: 0) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 12))
                            .foregroundColor(btCount > 0 ? Color.blue : Color.gray)
                        Text(" \(btCount) ")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textColor)
                        Text("BT")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.blue)
                        Text(" \(btCount == 1 ? "peer" : "peers")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        
                        // Only show WiFi Direct peer count if it's enabled
                        if isWiFiActive {
                            Text("  ")
                            Image(systemName: "wifi")
                                .font(.system(size: 12))
                                .foregroundColor(wifiCount > 0 ? Color.green : Color.gray)
                            Text(" \(wifiCount) WiFi \(wifiCount == 1 ? "peer" : "peers")")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                        }
                    }
                }
            }
            
            // Bridge Status
            if viewModel.transportManager.currentTransportInfo.isBridging {
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Bridge Mode Active")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    } icon: {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color.purple)
                    
                    Text("Bridging \(viewModel.transportManager.currentTransportInfo.bridgedClusters) network clusters")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            }
            
            // Bridge Manager Status
            let bridgeStatus = BridgeManager.shared.bridgeStatus
            if case .evaluating = bridgeStatus {
                Divider()
                
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Evaluating bridge eligibility...")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            } else if case .lowBattery = bridgeStatus {
                Divider()
                
                HStack(spacing: 4) {
                    Image(systemName: "battery.25")
                        .font(.system(size: 12))
                        .foregroundColor(Color.orange)
                    Text("Bridge disabled: Low battery")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            }
            
            // Connection Quality
            if viewModel.transportManager.currentTransportInfo.bluetoothPeerCount > 0 || 
               viewModel.transportManager.currentTransportInfo.wifiDirectPeerCount > 0 {
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Network Quality")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    } icon: {
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(textColor)
                    
                    // Show mesh network info
                    let totalPeers = viewModel.connectedPeers.count
                    let meshDensity = totalPeers > 10 ? "High" : (totalPeers > 5 ? "Medium" : "Low")
                    
                    HStack {
                        Text("Mesh Density:")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        Text(meshDensity)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(meshDensity == "High" ? Color.green : (meshDensity == "Medium" ? Color.orange : Color.red))
                    }
                }
            }
            
            // Battery status
            let batteryLevel = Int(BatteryOptimizer.shared.batteryLevel * 100)
            Divider()
            
            HStack(spacing: 4) {
                Image(systemName: batteryLevel > 80 ? "battery.100" : (batteryLevel > 50 ? "battery.75" : (batteryLevel > 20 ? "battery.50" : "battery.25")))
                    .font(.system(size: 12))
                    .foregroundColor(batteryLevel > 50 ? Color.green : (batteryLevel > 20 ? Color.orange : Color.red))
                Text("\(batteryLevel)% battery")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }
            
            // Transport Controls (for testing)
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Transport Mode")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                
                HStack(spacing: 8) {
                    // Bluetooth Only
                    Button(action: {
                        viewModel.transportManager.enableWiFiDirect = false
                        viewModel.transportManager.autoSelectTransport = false
                        viewModel.transportManager.primaryTransport = .bluetooth
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 10))
                            Text("BT Only")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(!viewModel.transportManager.enableWiFiDirect && !viewModel.transportManager.autoSelectTransport ? Color.blue : Color.gray.opacity(0.3))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // WiFi Direct
                    Button(action: {
                        viewModel.transportManager.enableWiFiDirect = true
                        viewModel.transportManager.autoSelectTransport = false
                        viewModel.transportManager.primaryTransport = .wifiDirect
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "wifi")
                                .font(.system(size: 10))
                            Text("WiFi")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(viewModel.transportManager.enableWiFiDirect && !viewModel.transportManager.autoSelectTransport && viewModel.transportManager.primaryTransport == .wifiDirect ? Color.green : Color.gray.opacity(0.3))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Auto
                    Button(action: {
                        viewModel.transportManager.enableWiFiDirect = true
                        viewModel.transportManager.autoSelectTransport = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.rays")
                                .font(.system(size: 10))
                            Text("Auto")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(viewModel.transportManager.autoSelectTransport ? Color.purple : Color.gray.opacity(0.3))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(colorScheme == .dark ? Color(white: 0.15).opacity(0.92) : Color(white: 0.95).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(textColor.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
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
        
        // Build the text view with clickable hashtags
        return HStack(spacing: 0) {
            ForEach(Array(buildTextSegments().enumerated()), id: \.offset) { _, segment in
                if segment.type == "hashtag" {
                    Button(action: {
                        _ = viewModel.joinRoom(segment.text)
                    }) {
                        Text(segment.text)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color.blue)
                            .underline()
                            .textSelection(.enabled)
                    }
                    .buttonStyle(.plain)
                } else if segment.type == "mention" {
                    Text(segment.text)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color.orange)
                        .textSelection(.enabled)
                } else {
                    Text(segment.text)
                        .font(.system(size: 14, design: .monospaced))
                        .fontWeight(isMentioned ? .bold : .regular)
                        .textSelection(.enabled)
                }
            }
        }
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

// Triangle shape for popover arrow
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// Preference key for transport button frame
struct TransportButtonFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
