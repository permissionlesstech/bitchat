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
        VStack(spacing: 0) {
            headerView
            Divider()
            messagesView
            Divider()
            inputView
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
    }
    
    private var headerView: some View {
        HStack {
            Text("bitchat")
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(textColor)
            
            Spacer()
            
            Menu {
                if viewModel.connectedPeers.isEmpty {
                    Text("No peers connected")
                        .font(.system(size: 12, design: .monospaced))
                } else {
                    let peerNicknames = viewModel.meshService.getPeerNicknames()
                    ForEach(viewModel.connectedPeers, id: \.self) { peerID in
                        if let displayName = peerNicknames[peerID], displayName != peerID {
                            // Only show if we have a real nickname
                            Label(displayName, systemImage: "person.fill")
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.isConnected ? textColor : Color.red)
                        .frame(width: 8, height: 8)
                    
                    HStack(spacing: 0) {
                        Text(viewModel.isConnected ? "\(viewModel.connectedPeers.count) \(viewModel.connectedPeers.count == 1 ? "peer" : "peers")" : "Scanning...")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        Text(Image(systemName: "chevron.down"))
                            .font(.system(size: 10))
                            .foregroundColor(secondaryTextColor)
                            .baselineOffset(-1)
                    }
                }
                .contentShape(Rectangle()) // Make entire area tappable
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(backgroundColor.opacity(0.95))
    }
    
    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(viewModel.messages.enumerated()), id: \.offset) { index, message in
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
                withAnimation {
                    proxy.scrollTo(viewModel.messages.count - 1, anchor: .bottom)
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
            
            Text("<\(viewModel.nickname)>")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(textColor)
                .lineLimit(1)
                .fixedSize()
            
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
                    .font(.system(size: 16))
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