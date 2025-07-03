import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var messageText = ""
    @State private var textFieldSelection: NSRange? = nil
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @State private var showPeerList = false
    @State private var isRecordingVoice = false
    @State private var recordingPulse = false
    @State private var recordingScale: CGFloat = 1.0
    @State private var showSidebar = false
    @State private var sidebarDragOffset: CGFloat = 0
    
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
                        Color.black.opacity(showSidebar ? 0.3 : 0.3 * (-sidebarDragOffset / (geometry.size.width * 0.7)))
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showSidebar = false
                                    sidebarDragOffset = 0
                                }
                            }
                        
                        sidebarView
                            .frame(width: geometry.size.width * 0.7)
                            .transition(.move(edge: .trailing))
                    }
                    .offset(x: showSidebar ? -sidebarDragOffset : geometry.size.width - sidebarDragOffset)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showSidebar)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sidebarDragOffset)
                }
            }
            
                // Recording ripples overlay
                if isRecordingVoice {
                    GeometryReader { geometry in
                        ZStack {
                            ForEach(0..<6) { index in
                                Circle()
                                    .stroke(Color.red.opacity(0.4 - Double(index) * 0.05), lineWidth: 1.5)
                                    .frame(width: 20, height: 20)  // Start at mic button size
                                    .scaleEffect(1 + (recordingScale - 1) * (1.0 - Double(index) * 0.1))
                                    .opacity(max(0, 1.0 - ((recordingScale - 1) / 40.0) * (1.0 - Double(index) * 0.1)))
                                    .position(
                                        // Position at mic button location
                                        x: geometry.size.width - 70,  // Account for padding and button position
                                        y: geometry.size.height - 32  // Account for input bar height
                                    )
                                    .animation(
                                        Animation.easeOut(duration: 3.0)
                                            .repeatForever(autoreverses: false)
                                            .delay(Double(index) * 0.4),
                                        value: recordingScale
                                    )
                            }
                        }
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            
            // Autocomplete overlay
            if viewModel.showAutocomplete && !viewModel.autocompleteSuggestions.isEmpty {
                VStack {
                    Spacer()
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
                    .frame(maxWidth: 200, alignment: .leading)
                    .offset(x: 100) // Align with input field
                    .padding(.bottom, 45) // Position just above input
                    .padding(.horizontal, 12)
                }
            }
            
            // Private message notification overlay
            if let notification = viewModel.privateMessageNotification {
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Message from \(notification.sender)")
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                            Text(notification.message)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color.orange)
                    .cornerRadius(8)
                    .shadow(radius: 4)
                    .padding(.horizontal)
                    .onTapGesture {
                        if let peerID = viewModel.getPeerIDForNickname(notification.sender) {
                            viewModel.startPrivateChat(with: peerID)
                            viewModel.privateMessageNotification = nil
                        }
                    }
                    Spacer()
                }
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut, value: viewModel.privateMessageNotification != nil)
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
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
                
                Text("private: \(privatePeerNick)")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.orange)
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
            } else {
                // Public chat header
                HStack(spacing: 4) {
                    Text("bitchat*")
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundColor(textColor)
                    
                    Text("name:")
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
                
                Spacer()
                
                // People counter
                let otherPeersCount = viewModel.connectedPeers.filter { $0 != viewModel.meshService.myPeerID }.count
                Text(viewModel.isConnected ? "\(otherPeersCount) \(otherPeersCount == 1 ? "person" : "people")" : "alone :/")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(viewModel.isConnected ? textColor : Color.red)
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
    
    private var peerStatusView: some View {
        Menu {
            if viewModel.connectedPeers.isEmpty {
                Text("No people connected")
                    .font(.system(size: 12, design: .monospaced))
            } else {
                let peerNicknames = viewModel.meshService.getPeerNicknames()
                let peerRSSI = viewModel.meshService.getPeerRSSI()
                let myPeerID = viewModel.meshService.myPeerID
                let _ = print("[UI DEBUG] connectedPeers: \(viewModel.connectedPeers), myPeerID: \(myPeerID), RSSI: \(peerRSSI)")
                ForEach(viewModel.connectedPeers.filter { $0 != myPeerID }.sorted(), id: \.self) { peerID in
                    let displayName = peerNicknames[peerID] ?? "person-\(peerID.prefix(4))"
                    Button(action: {
                        // Only allow private chat if peer has announced
                        if peerNicknames[peerID] != nil {
                            viewModel.startPrivateChat(with: peerID)
                        }
                    }) {
                        HStack {
                            Text(displayName)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(peerNicknames[peerID] != nil ? textColor : secondaryTextColor)
                            Spacer()
                            if viewModel.unreadPrivateMessages.contains(peerID) {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        #if os(macOS)
                        .frame(minWidth: 120)
                        #endif
                    }
                    .buttonStyle(.plain)
                    .disabled(peerNicknames[peerID] == nil)
                }
            }
        } label: {
            HStack(spacing: 2) {
                // Text
                let otherPeersCount = viewModel.connectedPeers.filter { $0 != viewModel.meshService.myPeerID }.count
                Text(viewModel.isConnected ? "\(otherPeersCount) \(otherPeersCount == 1 ? "person" : "people")" : "alone :/")
                    #if os(iOS)
                    .font(.system(size: 12, design: .monospaced))
                    #else
                    .font(.system(size: 14, design: .monospaced))
                    #endif
                    .foregroundColor(viewModel.isConnected ? textColor : Color.red)
                
                #if os(iOS)
                // Add chevron for iOS
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(textColor.opacity(0.6))
                #endif
                
                // Notification indicator (on the right after default chevron)
                if !viewModel.unreadPrivateMessages.isEmpty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                }
            }
            .fixedSize()
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        #else
        .menuStyle(.automatic)
        #endif
    }
    
    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let messages = viewModel.selectedPrivateChatPeer != nil 
                        ? viewModel.getPrivateChatMessages(for: viewModel.selectedPrivateChatPeer!)
                        : viewModel.messages
                    
                    ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                        VStack(alignment: .leading, spacing: 4) {
                            // Check if current user is mentioned
                            let isMentioned = message.mentions?.contains(viewModel.nickname) ?? false
                            
                            if message.sender == "system" {
                                // System messages
                                Text(viewModel.formatMessage(message, colorScheme: colorScheme))
                                    .font(.system(size: 14, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                // Regular messages with tappable sender name
                                HStack(alignment: .top, spacing: 0) {
                                    // Timestamp
                                    Text("[\\(viewModel.formatTimestamp(message.timestamp))] ")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(secondaryTextColor)
                                    
                                    // Tappable sender name
                                    if message.sender != viewModel.nickname {
                                        Button(action: {
                                            if let peerID = message.senderPeerID ?? viewModel.getPeerIDForNickname(message.sender) {
                                                viewModel.startPrivateChat(with: peerID)
                                            }
                                        }) {
                                            let senderColor = viewModel.getSenderColor(for: message, colorScheme: colorScheme)
                                            Text("<\\(message.sender)>")
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundColor(senderColor)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        // Own messages not tappable
                                        Text("<\\(message.sender)>")
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(textColor)
                                    }
                                    
                                    Text(" ")
                                    
                                    // Message content
                                    if message.voiceNoteData != nil {
                                        // Voice note with play button
                                        Text(viewModel.formatVoiceNoteContent(message, colorScheme: colorScheme))
                                            .font(.system(size: 14, design: .monospaced))
                                            .fontWeight(isMentioned ? .bold : .regular)
                                            .onTapGesture {
                                                viewModel.playVoiceNote(message: message)
                                            }
                                    } else {
                                        // Regular text content
                                        Text(viewModel.formatMessageContent(message, colorScheme: colorScheme))
                                            .font(.system(size: 14, design: .monospaced))
                                            .fontWeight(isMentioned ? .bold : .regular)
                                    }
                                    
                                    Spacer()
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                        .id(index)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(backgroundColor)
            .onChange(of: viewModel.messages.count) { _ in
                if viewModel.selectedPrivateChatPeer == nil {
                    withAnimation {
                        proxy.scrollTo(viewModel.messages.count - 1, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.privateChats) { _ in
                if let peerID = viewModel.selectedPrivateChatPeer,
                   let messages = viewModel.privateChats[peerID],
                   !messages.isEmpty {
                    withAnimation {
                        proxy.scrollTo(messages.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private var inputView: some View {
        HStack(alignment: .center, spacing: 4) {
            if viewModel.selectedPrivateChatPeer != nil {
                Text("<\(viewModel.nickname)> →")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 12)
            } else {
                Text("<\(viewModel.nickname)>")
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
                }
                .onSubmit {
                    sendMessage()
                }
            
            // Push to talk button
            ZStack {
                // Mic icon
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(isRecordingVoice ? Color.red.opacity(0.8) : textColor)
                
                // Local ripples that start from the button itself
                if isRecordingVoice {
                    ForEach(0..<4) { index in
                        Circle()
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                            .frame(width: 20, height: 20)
                            .scaleEffect(1 + Double(index) * 0.5)
                            .opacity(isRecordingVoice ? 0.5 - Double(index) * 0.1 : 0)
                            .animation(
                                Animation.easeOut(duration: 1.5)
                                    .repeatForever(autoreverses: false)
                                    .delay(Double(index) * 0.2),
                                value: isRecordingVoice
                            )
                    }
                }
            }
            .contentShape(Rectangle()) // Make entire area tappable
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isRecordingVoice {
                            print("[UI] Starting voice recording")
                            startVoiceRecording()
                        }
                    }
                    .onEnded { _ in
                        if isRecordingVoice {
                            print("[UI] Stopping voice recording")
                            stopVoiceRecording()
                        }
                    }
            )
            
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(textColor)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            }
            .padding(.vertical, 8)
            .background(backgroundColor.opacity(0.95))
        .onAppear {
            isTextFieldFocused = true
        }
    }
    
    private func sendMessage() {
        viewModel.sendMessage(messageText)
        messageText = ""
    }
    
    private func startVoiceRecording() {
        isRecordingVoice = true
        withAnimation(.easeOut(duration: 0.3)) {
            recordingScale = 50.0  // Scale up to cover entire screen from mic button size
        }
        #if os(iOS)
        // Light haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        #endif
        
        viewModel.audioRecorder.startRecording { result in
            if case .failure(let error) = result {
                print("[UI] Failed to start recording: \(error)")
                isRecordingVoice = false
                recordingScale = 1.0
            }
        }
    }
    
    private func stopVoiceRecording() {
        // Capture duration before stopping
        let duration = viewModel.audioRecorder.recordingTime
        isRecordingVoice = false
        recordingScale = 1.0
        
        viewModel.audioRecorder.stopRecording { result in
            switch result {
            case .success(let audioURL):
                // Read audio file and send as voice note
                do {
                    let audioData = try Data(contentsOf: audioURL)
                    print("[UI] Read audio file: \(audioData.count) bytes, duration: \(duration)s")
                    
                    // Use the captured duration, ensure it's at least 0.1s
                    viewModel.sendVoiceNote(audioData, duration: max(0.1, duration))
                    
                    // Clean up temporary file
                    try FileManager.default.removeItem(at: audioURL)
                } catch {
                    print("[UI] Failed to read audio file: \(error)")
                }
            case .failure(let error):
                print("[AUDIO] Recording failed: \(error)")
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
                    Text("connected")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(textColor)
                    Spacer()
                }
                .frame(height: 44) // Match header height
                .padding(.horizontal, 12)
                .background(backgroundColor.opacity(0.95))
                
                Divider()
            
            // People list
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.connectedPeers.isEmpty {
                        Text("No one connected")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                            .padding(.horizontal)
                    } else {
                        let peerNicknames = viewModel.meshService.getPeerNicknames()
                        let peerRSSI = viewModel.meshService.getPeerRSSI()
                        let myPeerID = viewModel.meshService.myPeerID
                        
                        // Sort peers: favorites first, then alphabetically by nickname
                        let sortedPeers = viewModel.connectedPeers.filter { $0 != myPeerID }.sorted { peer1, peer2 in
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
                            let displayName = peerNicknames[peerID] ?? "person-\(peerID.prefix(4))"
                            let rssi = peerRSSI[peerID]?.intValue ?? -100
                            let isFavorite = viewModel.isFavorite(peerID: peerID)
                            
                            HStack(spacing: 8) {
                                // Signal strength indicator
                                Circle()
                                    .fill(viewModel.getRSSIColor(rssi: rssi, colorScheme: colorScheme))
                                    .frame(width: 8, height: 8)
                                
                                // Favorite star
                                Button(action: {
                                    viewModel.toggleFavorite(peerID: peerID)
                                }) {
                                    Image(systemName: isFavorite ? "star.fill" : "star")
                                        .font(.system(size: 12))
                                        .foregroundColor(isFavorite ? Color.yellow : secondaryTextColor)
                                }
                                .buttonStyle(.plain)
                                
                                // Peer name button
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
                                        
                                        if viewModel.unreadPrivateMessages.contains(peerID) {
                                            Circle()
                                                .fill(Color.orange)
                                                .frame(width: 8, height: 8)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(peerNicknames[peerID] == nil)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
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