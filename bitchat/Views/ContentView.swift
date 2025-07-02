import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var messageText = ""
    @State private var textFieldSelection: NSRange? = nil
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @State private var showPeerList = false
    @State private var isRecordingVoice = false
    
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
            VStack(spacing: 0) {
                headerView
                Divider()
                messagesView
                Divider()
                inputView
            }
            .background(backgroundColor)
            .foregroundColor(textColor)
            
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
                
                // Invisible spacer to balance the back button
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12))
                    Text("back")
                        .font(.system(size: 14, design: .monospaced))
                }
                .opacity(0)
            } else {
                // Public chat header
                HStack(spacing: 8) {
                    Text("bitchat")
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundColor(textColor)
                    
                    // Peer status section
                    peerStatusView
                }
                
                Spacer()
                
                HStack(spacing: 4) {
                    Text("name:")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                    
                    TextField("nickname", text: $viewModel.nickname)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
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
                Text(viewModel.isConnected ? "\(otherPeersCount) \(otherPeersCount == 1 ? "person" : "people")" : "scanning")
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
                            
                            if message.voiceNoteData != nil {
                                // Voice note message
                                HStack(spacing: 8) {
                                    Button(action: {
                                        viewModel.playVoiceNote(message: message)
                                    }) {
                                        Image(systemName: viewModel.audioPlayer.isPlaying && viewModel.audioPlayer.currentPlayingMessageID == message.id ? "pause.circle.fill" : "play.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(textColor)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Text(viewModel.formatMessage(message, colorScheme: colorScheme))
                                        .font(.system(size: 14, design: .monospaced))
                                        .fontWeight(isMentioned ? .bold : .regular)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                // Regular text message
                                Text(viewModel.formatMessage(message, colorScheme: colorScheme))
                                    .font(.system(size: 14, design: .monospaced))
                                    .fontWeight(isMentioned ? .bold : .regular)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Autocomplete suggestions overlay
                if viewModel.showAutocomplete && !viewModel.autocompleteSuggestions.isEmpty {
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
                    .padding(.leading, 100) // Align with input field
                    .padding(.bottom, 4)
                }
                
                Spacer()
            }
            
            HStack(spacing: 4) {
            Text("[\(viewModel.formatTimestamp(Date()))]")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(secondaryTextColor)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 12)
            
            if viewModel.selectedPrivateChatPeer != nil {
                Text("<\(viewModel.nickname)> →")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.orange)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text("<\(viewModel.nickname)>")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .fixedSize()
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
            Button(action: {}) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(isRecordingVoice ? Color.red : textColor)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isRecordingVoice {
                            startVoiceRecording()
                        }
                    }
                    .onEnded { _ in
                        if isRecordingVoice {
                            stopVoiceRecording()
                        }
                    }
            )
            
            Button(action: sendMessage) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(textColor)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            }
            .padding(.vertical, 10)
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
    
    private func startVoiceRecording() {
        isRecordingVoice = true
        #if os(iOS)
        // Light haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        #endif
        
        viewModel.audioRecorder.startRecording { result in
            // Will handle result in stopVoiceRecording
        }
    }
    
    private func stopVoiceRecording() {
        isRecordingVoice = false
        
        viewModel.audioRecorder.stopRecording { result in
            switch result {
            case .success(let audioURL):
                // Read audio file and send as voice note
                if let audioData = try? Data(contentsOf: audioURL) {
                    let duration = viewModel.audioRecorder.recordingTime
                    viewModel.sendVoiceNote(audioData, duration: duration)
                    
                    // Clean up temporary file
                    try? FileManager.default.removeItem(at: audioURL)
                }
            case .failure(let error):
                print("[AUDIO] Recording failed: \(error)")
            }
        }
    }
}