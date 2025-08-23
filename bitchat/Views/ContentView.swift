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

// MARK: - Lazy Link Preview (removed)

// MARK: - Main Content View

struct ContentView: View {
    // MARK: - Properties
    
    @EnvironmentObject var viewModel: ChatViewModel
    #if os(iOS)
    @ObservedObject private var locationManager = LocationChannelManager.shared
    #endif
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
    @State private var isAtBottomPublic: Bool = true
    @State private var isAtBottomPrivate: Bool = true
    @State private var lastScrollTime: Date = .distantPast
    @State private var scrollThrottleTimer: Timer?
    @State private var autocompleteDebounceTimer: Timer?
    @State private var showLocationChannelsSheet = false
    @State private var expandedMessageIDs: Set<String> = []
    // Window sizes for rendering (infinite scroll up)
    @State private var windowCountPublic: Int = 180
    @State private var windowCountPrivate: [String: Int] = [:]
    #if os(iOS)
    @State private var keyboardIsVisible: Bool = false
    #endif
    
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
        #if os(iOS)
        // Track keyboard visibility
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
        }
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
            Button("direct message") {
                if let peerID = selectedMessageSenderID {
                    #if os(iOS)
                    if peerID.hasPrefix("nostr:") {
                        if let full = viewModel.fullNostrHex(forSenderPeerID: peerID) {
                            viewModel.startGeohashDM(withPubkeyHex: full)
                        }
                    } else {
                        viewModel.startPrivateChat(with: peerID)
                    }
                    #else
                    viewModel.startPrivateChat(with: peerID)
                    #endif
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
                // Prefer direct geohash block when we have a Nostr sender ID
                #if os(iOS)
                if let peerID = selectedMessageSenderID, peerID.hasPrefix("nostr:"),
                   let full = viewModel.fullNostrHex(forSenderPeerID: peerID),
                   let sender = selectedMessageSender {
                    viewModel.blockGeohashUser(pubkeyHexLowercased: full, displayName: sender)
                } else if let sender = selectedMessageSender {
                    viewModel.sendMessage("/block \(sender)")
                }
                #else
                if let sender = selectedMessageSender { viewModel.sendMessage("/block \(sender)") }
                #endif
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
    
    private func messagesView(privatePeer: String?, isAtBottom: Binding<Bool>) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Precompute data outside the row builder to keep type-checking simple
                let localMessages: [BitchatMessage] = {
                    if let peer = privatePeer { return viewModel.getPrivateChatMessages(for: peer) }
                    return viewModel.messages
                }()
                // Show the full set for clarity (avoid truncation issues)
                let currentWindowCount: Int = localMessages.count
                let windowed: ArraySlice<BitchatMessage> = localMessages.suffix(currentWindowCount)
                let idPrefix: String = {
                    if let peer = privatePeer { return "dm:\(peer)" }
                    #if os(iOS)
                    switch locationManager.selectedChannel {
                    case .mesh: return "mesh"
                    case .location(let ch): return "geo:\(ch.geohash)"
                    }
                    #else
                    return "mesh"
                    #endif
                }()
                let items: [(uiID: String, message: BitchatMessage)] = windowed.map { (uiID: "\(idPrefix)|\($0.id)", message: $0) }
                
                LazyVStack(alignment: .leading, spacing: 0) {
                    
                    ForEach(items.indices, id: \.self) { idx in
                        let item = items[idx]
                        let message = item.message
                        VStack(alignment: .leading, spacing: 0) {
                            // Check if current user is mentioned
                            
                            if message.sender == "system" {
                                // System messages
                                Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                // Regular messages with natural text wrapping
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(alignment: .top, spacing: 0) {
                                        // Render as a single Text so wrapping naturally continues under the prefix
                                        let isLong: Bool = message.content.count > 2000 || message.content.hasVeryLongToken(threshold: 512)
                                        let isExpanded: Bool = expandedMessageIDs.contains(message.id)
                                        let prefixWidth: CGFloat = viewModel.prefixWidth(for: message, colorScheme: colorScheme)
                                        let fullText: AttributedString = {
                                            var s = AttributedString()
                                            s.append(viewModel.formatSenderPrefix(message, colorScheme: colorScheme))
                                            s.append(viewModel.formatMessageBody(message, colorScheme: colorScheme))
                                            return s
                                        }()

                                        ZStack(alignment: .topLeading) {
                                            // Full message ensures natural hanging indent
                                            Text(fullText)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .lineLimit(isLong && !isExpanded ? 30 : nil)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .multilineTextAlignment(.leading)
                                                // Use double-tap on body to prefill mention; single-tap reserved for links
                                                .onTapGesture(count: 2) {
                                                    if message.sender != "system" && message.sender != viewModel.nickname {
                                                        messageText = "@\(message.sender) "
                                                        isTextFieldFocused = true
                                                    }
                                                }

                                            // Invisible prefix (no measurement; width computed and cached)
                                            Text(viewModel.formatSenderPrefix(message, colorScheme: colorScheme))
                                                .fixedSize(horizontal: true, vertical: false)
                                                .opacity(0)

                                            // Transparent overlay only over the prefix to trigger the action sheet
                                            Color.clear
                                                .frame(width: prefixWidth)
                                                .contentShape(Rectangle())
                                                .onTapGesture {
                                                    if message.sender != "system" && message.sender != viewModel.nickname {
                                                        selectedMessageSender = message.sender
                                                        selectedMessageSenderID = message.senderPeerID
                                                        showMessageActions = true
                                                    }
                                                }
                                        }
                                        // No onPreferenceChange; width computed and cached in ViewModel

                                        // Delivery status indicator for private messages
                                        if message.isPrivate && message.sender == viewModel.nickname,
                                           let status = message.deliveryStatus {
                                            DeliveryStatusView(status: status, colorScheme: colorScheme)
                                                .padding(.leading, 4)
                                        }
                                    }
                                    
                                    // Link previews removed for performance; URLs remain tappable in-text

                                    // Render payment chips (Lightning / Cashu) with rounded background
                                    let lightningLinks: [String] = Array(message.content.extractLightningLinks(max: 3))
                                    let cashuTokens: [String] = Array(message.content.extractCashuTokens(max: 3))
                                    if !lightningLinks.isEmpty || !cashuTokens.isEmpty {
                                        HStack(spacing: 8) {
                                            ForEach(Array(lightningLinks.prefix(3)).indices, id: \.self) { i in
                                                let link = lightningLinks[i]
                                                PaymentChipView(
                                                    emoji: "⚡",
                                                    label: "pay via lightning",
                                                    colorScheme: colorScheme
                                                ) {
                                                    #if os(iOS)
                                                    if let url = URL(string: link) { UIApplication.shared.open(url) }
                                                    #else
                                                    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                                                    #endif
                                                }
                                            }
                                            ForEach(Array(cashuTokens.prefix(3)).indices, id: \.self) { i in
                                                let token = cashuTokens[i]
                                                let enc = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? token
                                                let urlStr = "cashu:\(enc)"
                                                PaymentChipView(
                                                    emoji: "🥜",
                                                    label: "pay via cashu",
                                                    colorScheme: colorScheme
                                                ) {
                                                    #if os(iOS)
                                                    if let url = URL(string: urlStr) { UIApplication.shared.open(url) }
                                                    #else
                                                    if let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
                                                    #endif
                                                }
                                            }
                                        }
                                        .padding(.top, 6)
                                        .padding(.leading, 2)
                                    }

                                    // Expand/Collapse for very long messages (placed after chips)
                                    let isVeryLong: Bool = message.content.count > 2000 || message.content.hasVeryLongToken(threshold: 512)
                                    if isVeryLong {
                                        let isExpanded: Bool = expandedMessageIDs.contains(message.id)
                                        Button(isExpanded ? "Show less" : "Show more") {
                                            if isExpanded { expandedMessageIDs.remove(message.id) }
                                            else { expandedMessageIDs.insert(message.id) }
                                        }
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color.blue)
                                        .padding(.top, 4)
                                    }
                                }
                            }
                        }
                        .id(item.uiID)
                        .onAppear {
                            let idPrefix: String = {
                                if let peer = privatePeer { return "dm:\(peer)" }
                                #if os(iOS)
                                switch locationManager.selectedChannel {
                                case .mesh: return "mesh"
                                case .location(let ch): return "geo:\(ch.geohash)"
                                }
                                #else
                                return "mesh"
                                #endif
                            }()
                            handleRowAppear(messageID: message.id,
                                            privatePeer: privatePeer,
                                            messages: Array(localMessages),
                                            windowedMessages: windowed,
                                            isAtBottom: isAtBottom,
                                            proxy: proxy,
                                            idPrefix: idPrefix)
                        }
                        .onDisappear {
                            if message.id == windowed.last?.id {
                                isAtBottom.wrappedValue = false
                            }
                        }
                        // Tap targets handled on specific subviews above (username/body)
                        .contextMenu {
                            Button("Copy message") {
                                #if os(iOS)
                                UIPasteboard.general.string = message.content
                                #else
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(message.content, forType: .string)
                                #endif
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
            #if os(iOS)
            // Sync scroll to bottom with keyboard frame animations when already at bottom
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notif in
                guard isAtBottom.wrappedValue else { return }
                let targetID: String? = {
                    if let peer = privatePeer,
                       let last = viewModel.getPrivateChatMessages(for: peer).suffix(300).last?.id {
                        return "dm:\(peer)|\(last)"
                    }
                    #if os(iOS)
                    let idPrefix: String = {
                        switch locationManager.selectedChannel {
                        case .mesh: return "mesh"
                        case .location(let ch): return "geo:\(ch.geohash)"
                        }
                    }()
                    #else
                    let idPrefix: String = "mesh"
                    #endif
                    if let last = viewModel.messages.suffix(300).last?.id { return "\(idPrefix)|\(last)" }
                    return nil
                }()
                guard let target = targetID else { return }
                let duration = (notif.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
                let curveRaw = (notif.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? 2
                let anim: Animation = {
                    switch curveRaw {
                    case 0: return .easeInOut(duration: duration)
                    case 1: return .easeIn(duration: duration)
                    case 2: return .easeOut(duration: duration)
                    case 3: return .linear(duration: duration)
                    default: return .easeOut(duration: duration)
                    }
                }()
                DispatchQueue.main.async {
                    withAnimation(anim) {
                        proxy.scrollTo(target, anchor: .bottom)
                    }
                }
                // Final correction without animation to eliminate any end-of-animation jitter
                DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) {
                    var txn = Transaction()
                    txn.disablesAnimations = true
                    withTransaction(txn) {
                        proxy.scrollTo(target, anchor: .bottom)
                    }
                }
            }
            #endif
            .onAppear {
                // Dynamically size initial window to roughly 2× screenful for smoother initial load
                #if os(iOS)
                let screenH = UIScreen.main.bounds.height
                let rowEstimate: CGFloat = 22 // approx monospaced row height including spacing
                let initialRows = max(80, Int((screenH / rowEstimate).rounded()) * 2)
                if let peer = privatePeer {
                    let current = windowCountPrivate[peer] ?? 300
                    let total = viewModel.getPrivateChatMessages(for: peer).count
                    let desired = min(total, initialRows)
                    if current > desired { windowCountPrivate[peer] = desired }
                } else {
                    let current = windowCountPublic
                    let total = viewModel.messages.count
                    let desired = min(total, initialRows)
                    if current > desired { windowCountPublic = desired }
                }
                #endif
                // Force scroll to bottom when opening a chat view
                let targetID: String? = {
                    if let peer = privatePeer,
                       let last = viewModel.getPrivateChatMessages(for: peer).suffix(300).last?.id {
                        return "dm:\(peer)|\(last)"
                    }
                    #if os(iOS)
                    let idPrefix: String = {
                        switch locationManager.selectedChannel {
                        case .mesh: return "mesh"
                        case .location(let ch): return "geo:\(ch.geohash)"
                        }
                    }()
                    #else
                    let idPrefix: String = "mesh"
                    #endif
                    if let last = viewModel.messages.suffix(300).last?.id { return "\(idPrefix)|\(last)" }
                    return nil
                }()
                isAtBottom.wrappedValue = true
                DispatchQueue.main.async {
                    if let target = targetID { proxy.scrollTo(target, anchor: .bottom) }
                }
                // Second pass after a brief delay to handle late layout
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    let targetID2: String? = {
                        if let peer = privatePeer,
                           let last = viewModel.getPrivateChatMessages(for: peer).suffix(300).last?.id {
                            return "dm:\(peer)|\(last)"
                        }
                        #if os(iOS)
                        let idPrefix: String = {
                            switch locationManager.selectedChannel {
                            case .mesh: return "mesh"
                            case .location(let ch): return "geo:\(ch.geohash)"
                            }
                        }()
                        #else
                        let idPrefix: String = "mesh"
                        #endif
                        if let last = viewModel.messages.suffix(300).last?.id { return "\(idPrefix)|\(last)" }
                        return nil
                    }()
                    if let t2 = targetID2 { proxy.scrollTo(t2, anchor: .bottom) }
                }
            }
            .onChange(of: privatePeer) { _ in
                // When switching to a different private chat, jump to bottom
                let targetID: String? = {
                    if let peer = privatePeer,
                       let last = viewModel.getPrivateChatMessages(for: peer).suffix(300).last?.id {
                        return "dm:\(peer)|\(last)"
                    }
                    #if os(iOS)
                    let idPrefix: String = {
                        switch locationManager.selectedChannel {
                        case .mesh: return "mesh"
                        case .location(let ch): return "geo:\(ch.geohash)"
                        }
                    }()
                    #else
                    let idPrefix: String = "mesh"
                    #endif
                    if let last = viewModel.messages.suffix(300).last?.id { return "\(idPrefix)|\(last)" }
                    return nil
                }()
                isAtBottom.wrappedValue = true
                DispatchQueue.main.async {
                    if let target = targetID { proxy.scrollTo(target, anchor: .bottom) }
                }
            }
            .onChange(of: viewModel.messages.count) { _ in
                if privatePeer == nil && !viewModel.messages.isEmpty {
                    // If the newest message is from me, always scroll to bottom
                    let lastMsg = viewModel.messages.last!
                    let isFromSelf = (lastMsg.sender == viewModel.nickname) || lastMsg.sender.hasPrefix(viewModel.nickname + "#")
                    if !isFromSelf {
                        // Only autoscroll when user is at/near bottom
                        guard isAtBottom.wrappedValue else { return }
                    } else {
                        // Ensure we consider ourselves at bottom for subsequent messages
                        isAtBottom.wrappedValue = true
                    }
                    // Throttle scroll animations to prevent excessive UI updates
                    let now = Date()
                    if now.timeIntervalSince(lastScrollTime) > 0.5 {
                        // Immediate scroll if enough time has passed
                        lastScrollTime = now
                        #if os(iOS)
                        let idPrefix: String = {
                            switch locationManager.selectedChannel {
                            case .mesh: return "mesh"
                            case .location(let ch): return "geo:\(ch.geohash)"
                            }
                        }()
                        #else
                        let idPrefix: String = "mesh"
                        #endif
                        let count = windowCountPublic
                        let target = viewModel.messages.suffix(count).last.map { "\(idPrefix)|\($0.id)" }
                        DispatchQueue.main.async {
                            if let target = target { proxy.scrollTo(target, anchor: .bottom) }
                        }
                    } else {
                        // Schedule a delayed scroll
                        scrollThrottleTimer?.invalidate()
                        scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                            lastScrollTime = Date()
                            #if os(iOS)
                            let idPrefix: String = {
                                switch locationManager.selectedChannel {
                                case .mesh: return "mesh"
                                case .location(let ch): return "geo:\(ch.geohash)"
                                }
                            }()
                            #else
                            let idPrefix: String = "mesh"
                            #endif
                            let count = windowCountPublic
                            let target = viewModel.messages.suffix(count).last.map { "\(idPrefix)|\($0.id)" }
                            DispatchQueue.main.async {
                                if let target = target { proxy.scrollTo(target, anchor: .bottom) }
                            }
                        }
                    }
                }
            }
            .onChange(of: viewModel.privateChats) { _ in
                if let peerID = privatePeer,
                   let messages = viewModel.privateChats[peerID],
                   !messages.isEmpty {
                    // If the newest private message is from me, always scroll
                    let lastMsg = messages.last!
                    let isFromSelf = (lastMsg.sender == viewModel.nickname) || lastMsg.sender.hasPrefix(viewModel.nickname + "#")
                    if !isFromSelf {
                        // Only autoscroll when user is at/near bottom
                        guard isAtBottom.wrappedValue else { return }
                    } else {
                        isAtBottom.wrappedValue = true
                    }
                    // Same throttling for private chats
                    let now = Date()
                    if now.timeIntervalSince(lastScrollTime) > 0.5 {
                        lastScrollTime = now
                        let contextKey = "dm:\(peerID)"
                        let count = windowCountPrivate[peerID] ?? 300
                        let target = messages.suffix(count).last.map { "\(contextKey)|\($0.id)" }
                        DispatchQueue.main.async {
                            if let target = target { proxy.scrollTo(target, anchor: .bottom) }
                        }
                    } else {
                        scrollThrottleTimer?.invalidate()
                        scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                            lastScrollTime = Date()
                            let contextKey = "dm:\(peerID)"
                            let count = windowCountPrivate[peerID] ?? 300
                            let target = messages.suffix(count).last.map { "\(contextKey)|\($0.id)" }
                            DispatchQueue.main.async {
                                if let target = target { proxy.scrollTo(target, anchor: .bottom) }
                            }
                        }
                    }
                }
            }
            #if os(iOS)
            .onChange(of: locationManager.selectedChannel) { newChannel in
                // When switching to a new geohash channel, scroll to the bottom
                guard privatePeer == nil else { return }
                switch newChannel {
                case .mesh:
                    break
                case .location(let ch):
                    // Reset window size
                    windowCountPublic = 300
                    let idPrefix = "geo:\(ch.geohash)"
                    let last = viewModel.messages.suffix(windowCountPublic).last?.id
                    let target = last.map { "\(idPrefix)|\($0)" }
                    isAtBottom.wrappedValue = true
                    DispatchQueue.main.async {
                        if let target = target { proxy.scrollTo(target, anchor: .bottom) }
                    }
                }
            }
            #endif
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
        .environment(\.openURL, OpenURLAction { url in
            // Intercept custom cashu: links created in attributed text
            if let scheme = url.scheme?.lowercased(), scheme == "cashu" || scheme == "lightning" {
                #if os(iOS)
                UIApplication.shared.open(url)
                return .handled
                #else
                // On non-iOS platforms, let the system handle or ignore
                return .systemAction
                #endif
            }
            return .systemAction
        })
    }

    // MARK: - Helpers
    private func handleRowAppear(messageID: String,
                                 privatePeer: String?,
                                 messages: [BitchatMessage],
                                 windowedMessages: ArraySlice<BitchatMessage>,
                                 isAtBottom: Binding<Bool>,
                                 proxy: ScrollViewProxy,
                                 idPrefix: String) {
        // Track if last item is visible to enable auto-scroll only when near bottom
        if messageID == windowedMessages.last?.id {
            isAtBottom.wrappedValue = true
        }
        // Infinite scroll up: when top row appears, increase window and preserve anchor
        if messageID == windowedMessages.first?.id, messages.count > windowedMessages.count {
            let step = 120
            let preserveID = "\(idPrefix)|\(messageID)"
            if let peer = privatePeer {
                let current = windowCountPrivate[peer] ?? 300
                let newCount = min(messages.count, current + step)
                if newCount != current {
                    windowCountPrivate[peer] = newCount
                    DispatchQueue.main.async {
                        proxy.scrollTo(preserveID, anchor: .top)
                    }
                }
            } else {
                let current = windowCountPublic
                let newCount = min(messages.count, current + step)
                if newCount != current {
                    windowCountPublic = newCount
                    DispatchQueue.main.async {
                        proxy.scrollTo(preserveID, anchor: .top)
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
                                Text(suggestion)
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
                        (["/fav"], "<nickname>", "add to favorites"),
                        (["/help"], nil, "show this help"),
                        (["/hug"], "<nickname>", "send someone a warm hug"),
                        (["/m", "/msg"], "<nickname> [message]", "send private message"),
                        (["/slap"], "<nickname>", "slap someone with a trout"),
                        (["/unblock"], "<nickname>", "unblock a peer"),
                        (["/unfav"], "<nickname>", "remove from favorites"),
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
                // iOS keyboard autocomplete and capitalization enabled by default
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
                        var commandDescriptions = [
                            ("/block", "block or list blocked peers"),
                            ("/clear", "clear chat messages"),
                            ("/fav", "add to favorites"),
                            ("/help", "show this help"),
                            ("/hug", "send someone a warm hug"),
                            ("/m", "send private message"),
                            ("/slap", "slap someone with a trout"),
                            ("/unblock", "unblock a peer"),
                            ("/unfav", "remove from favorites"),
                            ("/w", "see who's online")
                        ]
                        #if os(iOS)
                        if case .location = locationManager.selectedChannel {
                            // Hide favorites in geohash chats; tweak descriptions
                            commandDescriptions.removeAll { $0.0 == "/fav" || $0.0 == "/unfav" }
                            commandDescriptions = commandDescriptions.map { pair in
                                if pair.0 == "/m" { return (pair.0, "send direct message") }
                                if pair.0 == "/w" { return (pair.0, "see who's here") }
                                return pair
                            }
                        }
                        #endif
                        
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
                    Text("PEOPLE")
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
                        #if os(iOS)
                        if case .location = locationManager.selectedChannel {
                            GeohashPeopleList(viewModel: viewModel,
                                              textColor: textColor,
                                              secondaryTextColor: secondaryTextColor,
                                              onTapPerson: {
                                                  withAnimation(.easeInOut(duration: 0.2)) {
                                                      showSidebar = false
                                                      sidebarDragOffset = 0
                                                  }
                                              })
                        } else {
                            MeshPeerList(viewModel: viewModel,
                                         textColor: textColor,
                                         secondaryTextColor: secondaryTextColor,
                                         onTapPeer: { peerID in
                                             viewModel.startPrivateChat(with: peerID)
                                             withAnimation(.easeInOut(duration: 0.2)) {
                                                 showSidebar = false
                                                 sidebarDragOffset = 0
                                             }
                                         },
                                         onToggleFavorite: { peerID in
                                             viewModel.toggleFavorite(peerID: peerID)
                                         },
                                         onShowFingerprint: { peerID in
                                             viewModel.showFingerprint(for: peerID)
                                         })
                        }
                        #else
                        MeshPeerList(viewModel: viewModel,
                                     textColor: textColor,
                                     secondaryTextColor: secondaryTextColor,
                                     onTapPeer: { peerID in
                                         viewModel.startPrivateChat(with: peerID)
                                         withAnimation(.easeInOut(duration: 0.2)) {
                                             showSidebar = false
                                             sidebarDragOffset = 0
                                         }
                                     },
                                     onToggleFavorite: { peerID in
                                         viewModel.toggleFavorite(peerID: peerID)
                                     },
                                     onShowFingerprint: { peerID in
                                         viewModel.showFingerprint(for: peerID)
                                     })
                        #endif
                    }
                }
                // Avoid forcing full remounts; rely on SwiftUI diffing for peer updates
            }
            
            Spacer()
        }
        .background(backgroundColor)
        }
    }
    
    // MARK: - View Components
    
    private var mainChatView: some View {
        Group {
            #if os(iOS)
            VStack(spacing: 0) {
                mainHeaderView
                Divider()
            messagesView(privatePeer: nil, isAtBottom: $isAtBottomPublic)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    inputView
                }
                .background(backgroundColor)
            }
            #else
            VStack(spacing: 0) {
                mainHeaderView
                Divider()
                messagesView(privatePeer: nil, isAtBottom: $isAtBottomPublic)
                Divider()
                inputView
            }
            #endif
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
            
            Group {
                #if os(iOS)
                VStack(spacing: 0) {
                    privateHeaderView
                    Divider()
                messagesView(privatePeer: viewModel.selectedPrivateChatPeer, isAtBottom: $isAtBottomPrivate)
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        Divider()
                        inputView
                    }
                    .background(backgroundColor)
                }
                #else
                VStack(spacing: 0) {
                    privateHeaderView
                    Divider()
                    messagesView(privatePeer: viewModel.selectedPrivateChatPeer, isAtBottom: $isAtBottomPrivate)
                    Divider()
                    inputView
                }
                #endif
            }
            .background(backgroundColor)
            .foregroundColor(textColor)
        }
    }

    // Split a name into base and a '#abcd' suffix if present
    private func splitNameSuffix(_ name: String) -> (base: String, suffix: String) {
        guard name.count >= 5 else { return (name, "") }
        let suffix = String(name.suffix(5))
        if suffix.first == "#", suffix.dropFirst().allSatisfy({ c in
            ("0"..."9").contains(String(c)) || ("a"..."f").contains(String(c)) || ("A"..."F").contains(String(c))
        }) {
            let base = String(name.dropLast(5))
            return (base, suffix)
        }
        return (name, "")
    }
    
    #if os(iOS)
    // Compute channel-aware people count and color for toolbar
    private func channelPeopleCountAndColor() -> (Int, Color) {
        switch locationManager.selectedChannel {
        case .location:
            let n = viewModel.geohashPeople.count
            // Use standard green (dark: system green; light: custom darker green)
            let standardGreen = (colorScheme == .dark) ? Color.green : Color(red: 0, green: 0.5, blue: 0)
            return (n, n > 0 ? standardGreen : Color.secondary)
        case .mesh:
            let counts = viewModel.allPeers.reduce(into: (others: 0, mesh: 0)) { counts, peer in
                guard peer.id != viewModel.meshService.myPeerID else { return }
                let isMeshConnected = peer.isConnected
                if isMeshConnected { counts.mesh += 1; counts.others += 1 }
                else if peer.isMutualFavorite { counts.others += 1 }
            }
            // Darker, more neutral blue (less purple hue)
            let meshBlue = Color(hue: 0.60, saturation: 0.85, brightness: 0.82)
            let color: Color = counts.mesh > 0 ? meshBlue : Color.secondary
            return (counts.others, color)
        }
    }
    #endif

    
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
            
            // Channel badge + dynamic spacing + people counter
            // Precompute header count and color outside the ViewBuilder expressions
            #if os(iOS)
            let cc = channelPeopleCountAndColor()
            let headerCountColor: Color = cc.1
            let headerOtherPeersCount: Int = {
                if case .location = locationManager.selectedChannel {
                    return viewModel.visibleGeohashPeople().count
                }
                return cc.0
            }()
            #else
            let peerCounts = viewModel.allPeers.reduce(into: (others: 0, mesh: 0)) { counts, peer in
                guard peer.id != viewModel.meshService.myPeerID else { return }
                let isMeshConnected = peer.isConnected
                if isMeshConnected { counts.mesh += 1; counts.others += 1 }
                else if peer.isMutualFavorite { counts.others += 1 }
            }
            let headerOtherPeersCount = peerCounts.others
            // Darker, more neutral blue (less purple hue)
            let meshBlue = Color(hue: 0.60, saturation: 0.85, brightness: 0.82)
            let headerCountColor: Color = (peerCounts.mesh > 0) ? meshBlue : Color.secondary
            #endif

            HStack(spacing: 10) {
                // Unread icon immediately to the left of the channel badge (independent from channel button)
                
                // Unread indicator
                #if os(iOS)
                if viewModel.hasAnyUnreadMessages {
                    Button(action: { viewModel.openMostRelevantPrivateChat() }) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open unread private chat")
                }
                // Location channels button '#'
                Button(action: { showLocationChannelsSheet = true }) {
                    let badgeText: String = {
                        switch locationManager.selectedChannel {
                        case .mesh: return "#mesh"
                        case .location(let ch): return "#\(ch.geohash)"
                        }
                    }()
                    let badgeColor: Color = {
                        switch locationManager.selectedChannel {
                        case .mesh:
                            return Color(hue: 0.60, saturation: 0.85, brightness: 0.82)
                        case .location:
                            return (colorScheme == .dark) ? Color.green : Color(red: 0, green: 0.5, blue: 0)
                        }
                    }()
                    Text(badgeText)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(badgeColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .accessibilityLabel("location channels")
                }
                .buttonStyle(.plain)
                #endif

                HStack(spacing: 4) {
                    // People icon with count
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11))
                        .accessibilityLabel("\(headerOtherPeersCount) people")
                    Text("\(headerOtherPeersCount)")
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityHidden(true)
                }
                .foregroundColor(headerCountColor)
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
        #if os(iOS)
        .sheet(isPresented: $showLocationChannelsSheet) {
            LocationChannelsSheet(isPresented: $showLocationChannelsSheet)
        }
        #endif
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
        // Prefer short (mesh) ID when mesh-connected (radio). Only use full Noise key when not connected (globe).
        let headerPeerID: String = {
            if privatePeerID.count == 16 {
                let isMeshConnected = viewModel.meshService.isPeerConnected(privatePeerID) || viewModel.connectedPeers.contains(privatePeerID)
                if !isMeshConnected, let stable = viewModel.getNoiseKeyForShortID(privatePeerID) {
                    return stable
                }
            } else if privatePeerID.count == 64 {
                // If we have a full Noise key and a corresponding short ID is currently mesh-connected, prefer short ID
                if let short = viewModel.getShortIDForNoiseKey(privatePeerID) {
                    if viewModel.meshService.isPeerConnected(short) || viewModel.connectedPeers.contains(short) {
                        return short
                    }
                }
            }
            return privatePeerID
        }()
        
        // Resolve peer object for header context (may be offline favorite)
        let peer = viewModel.getPeer(byID: headerPeerID)
        let privatePeerNick: String = {
            if privatePeerID.hasPrefix("nostr_") {
                #if os(iOS)
                // Build geohash DM header: "#<ghash>/@name#abcd"
                if case .location(let ch) = locationManager.selectedChannel {
                    let disp = viewModel.geohashDisplayName(for: privatePeerID)
                    return "#\(ch.geohash)/@\(disp)"
                }
                #endif
            }
            return peer?.displayName ?? 
                   viewModel.meshService.peerNickname(peerID: headerPeerID) ??
                   FavoritesPersistenceService.shared.getFavoriteStatus(for: Data(hexString: headerPeerID) ?? Data())?.peerNickname ?? 
                   "Unknown"
        }()
        let isNostrAvailable: Bool = {
            guard let connectionState = peer?.connectionState else { 
                // Check if we can reach this peer via Nostr even if not in allPeers
                if let noiseKey = Data(hexString: headerPeerID),
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
                        viewModel.showFingerprint(for: headerPeerID)
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
                            } else if viewModel.meshService.isPeerConnected(headerPeerID) || viewModel.connectedPeers.contains(headerPeerID) {
                                // Fallback: if peer lookup is missing but mesh reports connected, show radio
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 14))
                                    .foregroundColor(textColor)
                                    .accessibilityLabel("Connected via mesh")
                            }
                            
                            Text("\(privatePeerNick)")
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundColor(textColor)                            // Dynamic encryption status icon (hide for geohash DMs)
                            if !privatePeerID.hasPrefix("nostr_") {
                                let encryptionStatus = viewModel.getEncryptionStatus(for: headerPeerID)
                                if let icon = encryptionStatus.icon {
                                    Image(systemName: icon)
                                        .font(.system(size: 14))
                                        .foregroundColor(encryptionStatus == .noiseVerified ? textColor : 
                                                       encryptionStatus == .noiseSecured ? textColor :
                                                       Color.red)
                                        .accessibilityLabel("Encryption status: \(encryptionStatus == .noiseVerified ? "verified" : encryptionStatus == .noiseSecured ? "secured" : "not encrypted")")
                                }
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
                        
                        // Favorite button (hidden for geohash DMs)
                        if !(privatePeerID.hasPrefix("nostr_")) {
                            Button(action: {
                                viewModel.toggleFavorite(peerID: headerPeerID)
                            }) {
                                Image(systemName: viewModel.isFavorite(peerID: headerPeerID) ? "star.fill" : "star")
                                    .font(.system(size: 16))
                                    .foregroundColor(viewModel.isFavorite(peerID: headerPeerID) ? Color.yellow : textColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(viewModel.isFavorite(peerID: privatePeerID) ? "Remove from favorites" : "Add to favorites")
                            .accessibilityHint("Double tap to toggle favorite status")
                        }
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 12)
                .background(backgroundColor.opacity(0.95))
    }
    
}

// MARK: - Helper Views

// Rounded payment chip button
private struct PaymentChipView: View {
    let emoji: String
    let label: String
    let colorScheme: ColorScheme
    let action: () -> Void
    
    private var fgColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    private var bgColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.18) : Color.gray.opacity(0.12)
    }
    private var border: Color { fgColor.opacity(0.25) }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(emoji)
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(bgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(border, lineWidth: 1)
            )
            .foregroundColor(fgColor)
        }
        .buttonStyle(.plain)
    }
}

// Helper view for rendering message content (plain, no hashtag/mention formatting)
struct MessageContentView: View {
    let message: BitchatMessage
    let viewModel: ChatViewModel
    let colorScheme: ColorScheme
    let isMentioned: Bool
    
    var body: some View {
        Text(message.content)
            .font(.system(size: 14, design: .monospaced))
            .fontWeight(isMentioned ? .bold : .regular)
    }
    
    // MARK: - Helper Methods
    
    // buildTextSegments removed: content is rendered plain.
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

// Preference key to measure the width of the sender prefix for hanging indent
private struct PrefixWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
