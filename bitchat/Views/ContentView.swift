import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var messageText = ""
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @State private var showPeerList = false
    
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
                .animation(.easeInOut, value: viewModel.privateMessageNotification)
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
                Text("bitchat")
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)
                
                Spacer()
                
                // Peer status section
                peerStatusView
                
                Spacer()
                
                HStack(spacing: 4) {
                    Text("nick:")
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
                Text("No peers connected")
                    .font(.system(size: 12, design: .monospaced))
            } else {
                let peerNicknames = viewModel.meshService.getPeerNicknames()
                let myPeerID = viewModel.meshService.myPeerID
                ForEach(viewModel.connectedPeers.filter { $0 != myPeerID }.sorted(), id: \.self) { peerID in
                    let displayName = peerNicknames[peerID] ?? "peer-\(peerID.prefix(4))"
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
                    }
                    .buttonStyle(.plain)
                    .disabled(peerNicknames[peerID] == nil)
                }
            }
        } label: {
            HStack(spacing: 4) {
                // Notification indicator for unread messages
                if !viewModel.unreadPrivateMessages.isEmpty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                }
                
                // Text
                Text(viewModel.isConnected ? "\(viewModel.connectedPeers.count) \(viewModel.connectedPeers.count == 1 ? "peer" : "peers")" : "scanning")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(viewModel.isConnected ? textColor : Color.red)
                
                // Chevron
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(secondaryTextColor)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
                            Text(viewModel.formatMessage(message, colorScheme: colorScheme))
                                .font(.system(size: 14, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
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
                .onSubmit {
                    sendMessage()
                }
            
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
        .onAppear {
            isTextFieldFocused = true
        }
    }
    
    private func sendMessage() {
        viewModel.sendMessage(messageText)
        messageText = ""
    }
}