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

//

//

// MARK: - Main Content View

struct ContentView: View {
    // MARK: - Properties
    
    @EnvironmentObject var viewModel: ChatViewModel
    @ObservedObject private var locationManager = LocationChannelManager.shared
    @ObservedObject private var bookmarks = GeohashBookmarksStore.shared
    @ObservedObject private var notesCounter = LocationNotesCounter.shared
    @State private var messageText = ""
    @State private var textFieldSelection: NSRange? = nil
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showPeerList = false
    @State private var showSidebar = false
    @State private var showAppInfo = false
    @State private var showCommandSuggestions = false
    @State private var commandSuggestions: [String] = []
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
    @State private var showVerifySheet = false
    @State private var expandedMessageIDs: Set<String> = []
    @State private var showLocationNotes = false
    @State private var notesGeohash: String? = nil
    @State private var sheetNotesCount: Int = 0
    @ScaledMetric(relativeTo: .body) private var headerHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var headerPeerIconSize: CGFloat = 11
    @ScaledMetric(relativeTo: .subheadline) private var headerPeerCountFontSize: CGFloat = 12
    // Timer-based refresh removed; use LocationChannelManager live updates instead
    // Window sizes for rendering (infinite scroll up)
    @State private var windowCountPublic: Int = 300
    @State private var windowCountPrivate: [String: Int] = [:]
    
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

    private var headerLineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? 2 : 1
    }

    private var peopleSheetTitle: String {
        String(localized: "content.header.people", comment: "Title for the people list sheet").lowercased()
    }

    private var peopleSheetSubtitle: String? {
        switch locationManager.selectedChannel {
        case .mesh:
            return "#mesh"
        case .location(let channel):
            return "#\(channel.geohash.lowercased())"
        }
    }

    private var peopleSheetActiveCount: Int {
        switch locationManager.selectedChannel {
        case .mesh:
            return viewModel.allPeers.filter { $0.peerID != viewModel.meshService.myPeerID }.count
        case .location:
            return viewModel.visibleGeohashPeople().count
        }
    }
    
    
    private struct PrivateHeaderContext {
        let headerPeerID: String
        let peer: BitchatPeer?
        let displayName: String
        let isNostrAvailable: Bool
    }

// MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            mainHeaderView
                .onAppear { viewModel.currentColorScheme = colorScheme }
                .onChange(of: colorScheme) { newValue in
                    viewModel.currentColorScheme = newValue
                }

            Divider()

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    messagesView(privatePeer: nil, isAtBottom: $isAtBottomPublic)
                        .background(backgroundColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            Divider()

            if viewModel.selectedPrivateChatPeer == nil {
                inputView
            }
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
        .onChange(of: viewModel.selectedPrivateChatPeer) { newValue in
            if newValue != nil {
                showSidebar = true
            }
        }
        .sheet(
            isPresented: Binding(
                get: { showSidebar || viewModel.selectedPrivateChatPeer != nil },
                set: { isPresented in
                    if !isPresented {
                        showSidebar = false
                        viewModel.endPrivateChat()
                    }
                }
            )
        ) {
            peopleSheetView
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
        }
        .sheet(isPresented: $showAppInfo) {
            AppInfoView()
                .onAppear { viewModel.isAppInfoPresented = true }
                .onDisappear { viewModel.isAppInfoPresented = false }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showingFingerprintFor != nil },
            set: { _ in viewModel.showingFingerprintFor = nil }
        )) {
            if let peerID = viewModel.showingFingerprintFor {
                FingerprintView(viewModel: viewModel, peerID: peerID.id)
            }
        }
        .confirmationDialog(
            selectedMessageSender.map { "@\($0)" } ?? String(localized: "content.actions.title", comment: "Fallback title for the message action sheet"),
            isPresented: $showMessageActions,
            titleVisibility: .visible
        ) {
            Button("content.actions.mention") {
                if let sender = selectedMessageSender {
                    // Pre-fill the input with an @mention and focus the field
                    messageText = "@\(sender) "
                    isTextFieldFocused = true
                }
            }

            Button("content.actions.direct_message") {
                if let peerID = selectedMessageSenderID {
                    if peerID.hasPrefix("nostr:") {
                        if let full = viewModel.fullNostrHex(forSenderPeerID: PeerID(str: peerID)) {
                            viewModel.startGeohashDM(withPubkeyHex: full)
                        }
                    } else {
                        viewModel.startPrivateChat(with: PeerID(str: peerID))
                    }
                    withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                        showSidebar = true
                    }
                }
            }

            Button("content.actions.hug") {
                if let sender = selectedMessageSender {
                    viewModel.sendMessage("/hug @\(sender)")
                }
            }

            Button("content.actions.slap") {
                if let sender = selectedMessageSender {
                    viewModel.sendMessage("/slap @\(sender)")
                }
            }

            Button("content.actions.block", role: .destructive) {
                // Prefer direct geohash block when we have a Nostr sender ID
                if let peerID = selectedMessageSenderID, peerID.hasPrefix("nostr:"),
                   let full = viewModel.fullNostrHex(forSenderPeerID: PeerID(str: peerID)),
                   let sender = selectedMessageSender {
                    viewModel.blockGeohashUser(pubkeyHexLowercased: full, displayName: sender)
                } else if let sender = selectedMessageSender {
                    viewModel.sendMessage("/block \(sender)")
                }
            }

            Button("common.cancel", role: .cancel) {}
        }
        .alert("content.alert.bluetooth_required.title", isPresented: $viewModel.showBluetoothAlert) {
            Button("content.alert.bluetooth_required.settings") {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #endif
            }
            Button("common.ok", role: .cancel) {}
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Extract messages based on context (private or public chat)
                    let messages: [BitchatMessage] = {
                        if let privatePeer {
                            let msgs = viewModel.getPrivateChatMessages(for: PeerID(str: privatePeer))
                            return msgs
                        } else {
                            return viewModel.messages
                        }
                    }()
                    
                    // Implement windowing with adjustable window count per chat
                    let currentWindowCount: Int = {
                        if let peer = privatePeer { return windowCountPrivate[peer] ?? TransportConfig.uiWindowInitialCountPrivate }
                        return windowCountPublic
                    }()
                    let windowedMessages = messages.suffix(currentWindowCount)

                    // Build stable UI IDs with a context key to avoid ID collisions when switching channels
                    let contextKey: String = {
                        if let peer = privatePeer { return "dm:\(peer)" }
                        switch locationManager.selectedChannel {
                        case .mesh: return "mesh"
                        case .location(let ch): return "geo:\(ch.geohash)"
                        }
                    }()
                    let items = windowedMessages.map { (uiID: "\(contextKey)|\($0.id)", message: $0) }
                    // Filter out empty/whitespace-only messages to avoid blank rows
                    let filteredItems = items.filter { !$0.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

                    ForEach(filteredItems, id: \.uiID) { item in
                        let message = item.message
                        VStack(alignment: .leading, spacing: 0) {
                            // Check if current user is mentioned
                            
                            if message.sender == "system" {
                                // System messages
                                Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                TextMessageView(message: message, expandedMessageIDs: $expandedMessageIDs)
                            }
                        }
                        .id(item.uiID)
                        .onAppear {
                            // Track if last item is visible to enable auto-scroll only when near bottom
                            if message.id == windowedMessages.last?.id {
                                isAtBottom.wrappedValue = true
                            }
                            // Infinite scroll up: when top row appears, increase window and preserve anchor
                            if message.id == windowedMessages.first?.id, messages.count > windowedMessages.count {
                                let step = TransportConfig.uiWindowStepCount
                                let contextKey: String = {
                                    if let peer = privatePeer { return "dm:\(peer)" }
                                    switch locationManager.selectedChannel {
                                    case .mesh: return "mesh"
                                    case .location(let ch): return "geo:\(ch.geohash)"
                                    }
                                }()
                                let preserveID = "\(contextKey)|\(message.id)"
                                if let peer = privatePeer {
                                    let current = windowCountPrivate[peer] ?? TransportConfig.uiWindowInitialCountPrivate
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
                        .onDisappear {
                            if message.id == windowedMessages.last?.id {
                                isAtBottom.wrappedValue = false
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Tap on message body: insert @mention for this sender
                            if message.sender != "system" {
                                let name = message.sender
                                messageText = "@\(name) "
                                isTextFieldFocused = true
                            }
                        }
                        .contextMenu {
                            Button("content.message.copy") {
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
                .transaction { tx in if viewModel.isBatchingPublic { tx.disablesAnimations = true } }
                .padding(.vertical, 4)
            }
            .background(backgroundColor)
            .onOpenURL { url in
                guard url.scheme == "bitchat", url.host == "user" else { return }
                let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let peerID = PeerID(str: id.removingPercentEncoding ?? id)
                selectedMessageSenderID = peerID.id
                // Derive a stable display name from the peerID instead of peeking at the last message,
                // which may be a transformed system action (sender == "system").
                if peerID.isGeoDM || peerID.isGeoChat {
                    // For geohash senders, resolve display name via mapping (works for "nostr:" and "nostr_" keys)
                    selectedMessageSender = viewModel.geohashDisplayName(for: peerID)
                } else {
                    // Mesh sender: use current mesh nickname if available; otherwise fall back to last non-system message
                    if let name = viewModel.meshService.peerNickname(peerID: peerID) {
                        selectedMessageSender = name
                    } else {
                        selectedMessageSender = viewModel.messages.last(where: { $0.senderPeerID == peerID && $0.sender != "system" })?.sender
                    }
                }
                if viewModel.isSelfSender(peerID: peerID, displayName: selectedMessageSender) {
                    selectedMessageSender = nil
                    selectedMessageSenderID = nil
                } else {
                    showMessageActions = true
                }
            }
            .onOpenURL { url in
                guard url.scheme == "bitchat", url.host == "geohash" else { return }
                let gh = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
                guard (2...12).contains(gh.count), gh.allSatisfy({ allowed.contains($0) }) else { return }
                func levelForLength(_ len: Int) -> GeohashChannelLevel {
                    switch len {
                        case 0...2: return .region
                        case 3...4: return .province
                        case 5: return .city
                        case 6: return .neighborhood
                    case 7: return .block
                    default: return .block
                        }
                    }
                let level = levelForLength(gh.count)
                let ch = GeohashChannel(level: level, geohash: gh)
                // Do not mark teleported when opening a geohash that is in our regional set.
                // If availableChannels is empty (e.g., cold start), defer marking and let
                // LocationChannelManager compute teleported based on actual location.
                let inRegional = LocationChannelManager.shared.availableChannels.contains { $0.geohash == gh }
                if !inRegional && !LocationChannelManager.shared.availableChannels.isEmpty {
                    LocationChannelManager.shared.markTeleported(for: gh, true)
                }
                LocationChannelManager.shared.select(ChannelID.location(ch))
            }
            .onTapGesture(count: 3) {
                // Triple-tap to clear current chat
                viewModel.sendMessage("/clear")
            }
            .onAppear {
                // Force scroll to bottom when opening a chat view
                let targetID: String? = {
                    if let peer = privatePeer,
                       let last = viewModel.getPrivateChatMessages(for: PeerID(str: peer)).suffix(300).last?.id {
                        return "dm:\(peer)|\(last)"
                    }
                    let contextKey: String = {
                        switch locationManager.selectedChannel {
                        case .mesh: return "mesh"
                        case .location(let ch): return "geo:\(ch.geohash)"
                        }
                    }()
                    if let last = viewModel.messages.suffix(300).last?.id { return "\(contextKey)|\(last)" }
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
                           let last = viewModel.getPrivateChatMessages(for: PeerID(str: peer)).suffix(300).last?.id {
                            return "dm:\(peer)|\(last)"
                        }
                        let contextKey: String = {
                            switch locationManager.selectedChannel {
                            case .mesh: return "mesh"
                            case .location(let ch): return "geo:\(ch.geohash)"
                            }
                        }()
                        if let last = viewModel.messages.suffix(300).last?.id { return "\(contextKey)|\(last)" }
                        return nil
                    }()
                    if let t2 = targetID2 { proxy.scrollTo(t2, anchor: .bottom) }
                }
            }
            .onChange(of: privatePeer) { _ in
                // When switching to a different private chat, jump to bottom
                let targetID: String? = {
                    if let peer = privatePeer,
                       let last = viewModel.getPrivateChatMessages(for: PeerID(str: peer)).suffix(300).last?.id {
                        return "dm:\(peer)|\(last)"
                    }
                    let contextKey: String = {
                        switch locationManager.selectedChannel {
                        case .mesh: return "mesh"
                        case .location(let ch): return "geo:\(ch.geohash)"
                        }
                    }()
                    if let last = viewModel.messages.suffix(300).last?.id { return "\(contextKey)|\(last)" }
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
                    if now.timeIntervalSince(lastScrollTime) > TransportConfig.uiScrollThrottleSeconds {
                        // Immediate scroll if enough time has passed
                        lastScrollTime = now
                        let contextKey: String = {
                            switch locationManager.selectedChannel {
                            case .mesh: return "mesh"
                            case .location(let ch): return "geo:\(ch.geohash)"
                            }
                        }()
                        let count = windowCountPublic
                        let target = viewModel.messages.suffix(count).last.map { "\(contextKey)|\($0.id)" }
                        DispatchQueue.main.async {
                            if let target = target { proxy.scrollTo(target, anchor: .bottom) }
                        }
                    } else {
                        // Schedule a delayed scroll
                        scrollThrottleTimer?.invalidate()
                        scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: TransportConfig.uiScrollThrottleSeconds, repeats: false) { _ in
                            lastScrollTime = Date()
                        let contextKey: String = {
                            switch locationManager.selectedChannel {
                            case .mesh: return "mesh"
                            case .location(let ch): return "geo:\(ch.geohash)"
                            }
                        }()
                            let count = windowCountPublic
                            let target = viewModel.messages.suffix(count).last.map { "\(contextKey)|\($0.id)" }
                            DispatchQueue.main.async {
                                if let target = target { proxy.scrollTo(target, anchor: .bottom) }
                            }
                        }
                    }
                }
            }
            .onChange(of: viewModel.privateChats) { _ in
                if let peerID = privatePeer,
                   let messages = viewModel.privateChats[PeerID(str: peerID)],
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
                    if now.timeIntervalSince(lastScrollTime) > TransportConfig.uiScrollThrottleSeconds {
                        lastScrollTime = now
                        let contextKey = "dm:\(peerID)"
                        let count = windowCountPrivate[peerID] ?? 300
                        let target = messages.suffix(count).last.map { "\(contextKey)|\($0.id)" }
                        DispatchQueue.main.async {
                            if let target = target { proxy.scrollTo(target, anchor: .bottom) }
                        }
                    } else {
                        scrollThrottleTimer?.invalidate()
                        scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: TransportConfig.uiScrollThrottleSeconds, repeats: false) { _ in
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
            .onChange(of: locationManager.selectedChannel) { newChannel in
                // When switching to a new geohash channel, scroll to the bottom
                guard privatePeer == nil else { return }
                switch newChannel {
                case .mesh:
                    break
                case .location(let ch):
                    // Reset window size
                    windowCountPublic = TransportConfig.uiWindowInitialCountPublic
                    let contextKey = "geo:\(ch.geohash)"
                    let last = viewModel.messages.suffix(windowCountPublic).last?.id
                    let target = last.map { "\(contextKey)|\($0)" }
                    isAtBottom.wrappedValue = true
                    DispatchQueue.main.async {
                        if let target = target { proxy.scrollTo(target, anchor: .bottom) }
                    }
                }
            }
            .onAppear {
                // Also check when view appears
                if let peerID = PeerID(str: privatePeer) {
                    // Try multiple times to ensure read receipts are sent
                    viewModel.markPrivateMessagesAsRead(from: peerID)
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiReadReceiptRetryShortSeconds) {
                        viewModel.markPrivateMessagesAsRead(from: peerID)
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiReadReceiptRetryLongSeconds) {
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
                                    .font(.bitchatSystem(size: 11, design: .monospaced))
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
                    let baseInfo: [(commands: [String], syntax: String?, description: String)] = [
                        (["/block"], "[nickname]", "block or list blocked peers"),
                        (["/clear"], nil, "clear chat messages"),
                        (["/hug"], "<nickname>", "send someone a warm hug"),
                        (["/m", "/msg"], "<nickname> [message]", "send private message"),
                        (["/slap"], "<nickname>", "slap someone with a trout"),
                        (["/unblock"], "<nickname>", "unblock a peer"),
                        (["/w"], nil, "see who's online")
                    ]
                    let isGeoPublic: Bool = { if case .location = locationManager.selectedChannel { return true }; return false }()
                    let isGeoDM = viewModel.selectedPrivateChatPeer?.isGeoDM == true
                    let favInfo: [(commands: [String], syntax: String?, description: String)] = [
                        (["/fav"], "<nickname>", "add to favorites"),
                        (["/unfav"], "<nickname>", "remove from favorites")
                    ]
                    let commandInfo = baseInfo + ((isGeoPublic || isGeoDM) ? [] : favInfo)
                    
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
                                        .font(.bitchatSystem(size: 11, design: .monospaced))
                                        .foregroundColor(textColor)
                                        .fontWeight(.medium)
                                    
                                    // Show syntax if any
                                    if let syntax = info.syntax {
                                        Text(syntax)
                                            .font(.bitchatSystem(size: 10, design: .monospaced))
                                            .foregroundColor(secondaryTextColor.opacity(0.8))
                                    }
                                    
                                    Spacer()
                                    
                                    // Show description
                                    Text(info.description)
                                        .font(.bitchatSystem(size: 10, design: .monospaced))
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
        TextField("content.input.message_placeholder", text: $messageText)
                .textFieldStyle(.plain)
                .font(.bitchatSystem(size: 14, design: .monospaced))
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
                        let isGeoPublic: Bool = {
                            if case .location = locationManager.selectedChannel { return true }
                            return false
                        }()
                        let isGeoDM = viewModel.selectedPrivateChatPeer?.isGeoDM == true
                        var commandDescriptions = [
                            ("/block", String(localized: "content.commands.block", comment: "Description for /block command")),
                            ("/clear", String(localized: "content.commands.clear", comment: "Description for /clear command")),
                            ("/hug", String(localized: "content.commands.hug", comment: "Description for /hug command")),
                            ("/m", String(localized: "content.commands.message", comment: "Description for /m command")),
                            ("/slap", String(localized: "content.commands.slap", comment: "Description for /slap command")),
                            ("/unblock", String(localized: "content.commands.unblock", comment: "Description for /unblock command")),
                            ("/w", String(localized: "content.commands.who", comment: "Description for /w command"))
                        ]
                        // Only show favorites commands when not in geohash context
                        if !(isGeoPublic || isGeoDM) {
                            commandDescriptions.append(("/fav", String(localized: "content.commands.favorite", comment: "Description for /fav command")))
                            commandDescriptions.append(("/unfav", String(localized: "content.commands.unfavorite", comment: "Description for /unfav command")))
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
                    .font(.bitchatSystem(size: 20))
                    .foregroundColor(messageText.isEmpty ? Color.gray :
                                            viewModel.selectedPrivateChatPeer != nil
                                             ? Color.orange : textColor)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .accessibilityLabel(
                String(localized: "content.accessibility.send_message", comment: "Accessibility label for the send message button")
            )
            .accessibilityHint(
                messageText.isEmpty
                ? String(localized: "content.accessibility.send_hint_empty", comment: "Hint prompting the user to enter a message")
                : String(localized: "content.accessibility.send_hint_ready", comment: "Hint prompting the user to send the message")
            )
            }
            .padding(.vertical, 8)
            .background(backgroundColor.opacity(0.95))
        }
        .onAppear {
            // Delay keyboard focus to avoid iOS constraint warnings
            DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiReadReceiptRetryShortSeconds) {
                isTextFieldFocused = true
            }
        }
    }
    
    // MARK: - Actions
    
    private func sendMessage() {
        viewModel.sendMessage(messageText)
        messageText = ""
    }
    
    // MARK: - Sheet Content
    
    private var peopleSheetView: some View {
        Group {
            if viewModel.selectedPrivateChatPeer != nil {
                privateChatSheetView
            } else {
                peopleListSheetView
            }
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }
    
    // MARK: - People Sheet Views
    
    private var peopleListSheetView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(peopleSheetTitle)
                        .font(.bitchatSystem(size: 18, design: .monospaced))
                        .foregroundColor(textColor)
                    Spacer()
                    if case .mesh = locationManager.selectedChannel {
                        Button(action: { showVerifySheet = true }) {
                            Image(systemName: "qrcode")
                                .font(.bitchatSystem(size: 14))
                        }
                        .buttonStyle(.plain)
                        .help(
                            String(localized: "content.help.verification", comment: "Help text for verification button")
                        )
                    }
                    Button(action: {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            dismiss()
                            showSidebar = false
                            showVerifySheet = false
                            viewModel.endPrivateChat()
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                let activeText = String.localizedStringWithFormat(
                    String(localized: "%@ active", comment: "Count of active users in the people sheet"),
                    "\(peopleSheetActiveCount)"
                )

                if let subtitle = peopleSheetSubtitle {
                    let subtitleColor: Color = {
                        switch locationManager.selectedChannel {
                        case .mesh:
                            return Color.blue
                        case .location:
                            return Color.green
                        }
                    }()
                    HStack(spacing: 6) {
                        Text(subtitle)
                            .foregroundColor(subtitleColor)
                        Text(activeText)
                            .foregroundColor(.secondary)
                    }
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                } else {
                    Text(activeText)
                        .font(.bitchatSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .background(backgroundColor)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if case .location = locationManager.selectedChannel {
                        GeohashPeopleList(
                            viewModel: viewModel,
                            textColor: textColor,
                            secondaryTextColor: secondaryTextColor,
                            onTapPerson: {
                                showSidebar = true
                            }
                        )
                    } else {
                        MeshPeerList(
                            viewModel: viewModel,
                            textColor: textColor,
                            secondaryTextColor: secondaryTextColor,
                            onTapPeer: { peerID in
                                viewModel.startPrivateChat(with: PeerID(str: peerID))
                                showSidebar = true
                            },
                            onToggleFavorite: { peerID in
                                viewModel.toggleFavorite(peerID: PeerID(str: peerID))
                            },
                            onShowFingerprint: { peerID in
                                viewModel.showFingerprint(for: PeerID(str: peerID))
                            }
                        )
                    }
                }
                .padding(.top, 4)
                .id(viewModel.allPeers.map { "\($0.peerID)-\($0.isConnected)" }.joined())
            }
        }
    }
    
    // MARK: - View Components

    private var privateChatSheetView: some View {
        VStack(spacing: 0) {
            if let privatePeerID = viewModel.selectedPrivateChatPeer?.id {
                let headerContext = makePrivateHeaderContext(for: privatePeerID)

                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            viewModel.endPrivateChat()
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(textColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.back_to_main_chat", comment: "Accessibility label for returning to main chat")
                    )

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        privateHeaderInfo(context: headerContext, privatePeerID: privatePeerID)
                        let peerID = PeerID(str: headerContext.headerPeerID)
                        let isFavorite = viewModel.isFavorite(peerID: peerID)

                        if !privatePeerID.hasPrefix("nostr_") {
                            Button(action: {
                                viewModel.toggleFavorite(peerID: peerID)
                            }) {
                                Image(systemName: isFavorite ? "star.fill" : "star")
                                    .font(.bitchatSystem(size: 14))
                                    .foregroundColor(isFavorite ? Color.yellow : textColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                isFavorite
                                ? String(localized: "content.accessibility.remove_favorite", comment: "Accessibility label to remove a favorite")
                                : String(localized: "content.accessibility.add_favorite", comment: "Accessibility label to add a favorite")
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Spacer(minLength: 0)

                    Button(action: {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            viewModel.endPrivateChat()
                            showSidebar = true
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 32, height: 32)
                    }
                
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .frame(height: headerHeight)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(backgroundColor)
            }

            messagesView(privatePeer: viewModel.selectedPrivateChatPeer?.id, isAtBottom: $isAtBottomPrivate)
                .background(backgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inputView
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        .highPriorityGesture(
            DragGesture(minimumDistance: 25, coordinateSpace: .local)
                .onEnded { value in
                    let horizontal = value.translation.width
                    let vertical = abs(value.translation.height)
                    guard horizontal > 80, vertical < 60 else { return }
                    withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                        showSidebar = true
                        viewModel.endPrivateChat()
                    }
                }
        )
    }

    private func privateHeaderInfo(context: PrivateHeaderContext, privatePeerID: String) -> some View {
        Button(action: {
            viewModel.showFingerprint(for: PeerID(str: context.headerPeerID))
        }) {
            HStack(spacing: 6) {
                if let connectionState = context.peer?.connectionState {
                    switch connectionState {
                    case .bluetoothConnected:
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(textColor)
                            .accessibilityLabel(String(localized: "content.accessibility.connected_mesh", comment: "Accessibility label for mesh-connected peer indicator"))
                    case .meshReachable:
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(textColor)
                            .accessibilityLabel(String(localized: "content.accessibility.reachable_mesh", comment: "Accessibility label for mesh-reachable peer indicator"))
                    case .nostrAvailable:
                        Image(systemName: "globe")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(.purple)
                            .accessibilityLabel(String(localized: "content.accessibility.available_nostr", comment: "Accessibility label for Nostr-available peer indicator"))
                    case .offline:
                        EmptyView()
                    }
                } else if viewModel.meshService.isPeerReachable(PeerID(str: context.headerPeerID)) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(textColor)
                        .accessibilityLabel(String(localized: "content.accessibility.reachable_mesh", comment: "Accessibility label for mesh-reachable peer indicator"))
                } else if context.isNostrAvailable {
                    Image(systemName: "globe")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(.purple)
                        .accessibilityLabel(String(localized: "content.accessibility.available_nostr", comment: "Accessibility label for Nostr-available peer indicator"))
                } else if viewModel.meshService.isPeerConnected(PeerID(str: context.headerPeerID)) || viewModel.connectedPeers.contains(PeerID(str: context.headerPeerID)) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(textColor)
                        .accessibilityLabel(String(localized: "content.accessibility.connected_mesh", comment: "Accessibility label for mesh-connected peer indicator"))
                }

                Text(context.displayName)
                    .font(.bitchatSystem(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)

                if !privatePeerID.hasPrefix("nostr_") {
                    let statusPeerID: String = {
                        if privatePeerID.count == 64, let short = viewModel.getShortIDForNoiseKey(privatePeerID) {
                            return short.id
                        }
                        return context.headerPeerID
                    }()
                    let encryptionStatus = viewModel.getEncryptionStatus(for: PeerID(str: statusPeerID))
                    if let icon = encryptionStatus.icon {
                        Image(systemName: icon)
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(encryptionStatus == .noiseVerified ? textColor :
                                             encryptionStatus == .noiseSecured ? textColor :
                                             Color.red)
                            .accessibilityLabel(
                                String(
                                    format: String(localized: "content.accessibility.encryption_status", comment: "Accessibility label announcing encryption status"),
                                    locale: .current,
                                    encryptionStatus.accessibilityDescription
                                )
                            )
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: String(localized: "content.accessibility.private_chat_header", comment: "Accessibility label describing the private chat header"),
                locale: .current,
                context.displayName
            )
        )
        .accessibilityHint(
            String(localized: "content.accessibility.view_fingerprint_hint", comment: "Accessibility hint for viewing encryption fingerprint")
        )
        .frame(height: headerHeight)
    }

    private func makePrivateHeaderContext(for privatePeerID: String) -> PrivateHeaderContext {
        let headerPeerID: String = {
            if privatePeerID.count == 64, let short = viewModel.getShortIDForNoiseKey(privatePeerID) {
                return short.id
            }
            return privatePeerID
        }()

        let peer = viewModel.getPeer(byID: PeerID(str: headerPeerID))

        let displayName: String = {
            if privatePeerID.hasPrefix("nostr_"), case .location(let ch) = locationManager.selectedChannel {
                let disp = viewModel.geohashDisplayName(for: PeerID(str: privatePeerID))
                return "#\(ch.geohash)/@\(disp)"
            }
            if let name = peer?.displayName { return name }
            if let name = viewModel.meshService.peerNickname(peerID: PeerID(str: headerPeerID)) { return name }
            if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: Data(hexString: headerPeerID) ?? Data()),
               !fav.peerNickname.isEmpty { return fav.peerNickname }
            if headerPeerID.count == 16 {
                let candidates = viewModel.identityManager.getCryptoIdentitiesByPeerIDPrefix(PeerID(str: headerPeerID))
                if let id = candidates.first,
                   let social = viewModel.identityManager.getSocialIdentity(for: id.fingerprint) {
                    if let pet = social.localPetname, !pet.isEmpty { return pet }
                    if !social.claimedNickname.isEmpty { return social.claimedNickname }
                }
            } else if headerPeerID.count == 64, let keyData = Data(hexString: headerPeerID) {
                let fp = keyData.sha256Fingerprint()
                if let social = viewModel.identityManager.getSocialIdentity(for: fp) {
                    if let pet = social.localPetname, !pet.isEmpty { return pet }
                    if !social.claimedNickname.isEmpty { return social.claimedNickname }
                }
            }
            return String(localized: "common.unknown", comment: "Fallback label for unknown peer")
        }()

        let isNostrAvailable: Bool = {
            guard let connectionState = peer?.connectionState else {
                if let noiseKey = Data(hexString: headerPeerID),
                   let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
                   favoriteStatus.isMutual {
                    return true
                }
                return false
            }
            return connectionState == .nostrAvailable
        }()

        return PrivateHeaderContext(
            headerPeerID: headerPeerID,
            peer: peer,
            displayName: displayName,
            isNostrAvailable: isNostrAvailable
        )
    }
    
    // Compute channel-aware people count and color for toolbar (cross-platform)
    private func channelPeopleCountAndColor() -> (Int, Color) {
        switch locationManager.selectedChannel {
        case .location:
            let n = viewModel.geohashPeople.count
            let standardGreen = (colorScheme == .dark) ? Color.green : Color(red: 0, green: 0.5, blue: 0)
            return (n, n > 0 ? standardGreen : Color.secondary)
        case .mesh:
            let counts = viewModel.allPeers.reduce(into: (others: 0, mesh: 0)) { counts, peer in
                guard peer.peerID != viewModel.meshService.myPeerID else { return }
                if peer.isConnected { counts.mesh += 1; counts.others += 1 }
                else if peer.isReachable { counts.others += 1 }
            }
            let meshBlue = Color(hue: 0.60, saturation: 0.85, brightness: 0.82)
            let color: Color = counts.mesh > 0 ? meshBlue : Color.secondary
            return (counts.others, color)
        }
    }

    
    private var mainHeaderView: some View {
        HStack(spacing: 0) {
            Text(verbatim: "bitchat/")
                .font(.bitchatSystem(size: 18, weight: .medium, design: .monospaced))
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
                Text(verbatim: "@")
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                
                TextField("content.input.nickname_placeholder", text: $viewModel.nickname)
                    .textFieldStyle(.plain)
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .frame(maxWidth: 80)
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
            let cc = channelPeopleCountAndColor()
            let headerCountColor: Color = cc.1
            let headerOtherPeersCount: Int = {
                if case .location = locationManager.selectedChannel {
                    return viewModel.visibleGeohashPeople().count
                }
                return cc.0
            }()

            HStack(spacing: 10) {
                // Unread icon immediately to the left of the channel badge (independent from channel button)
                
                // Unread indicator (now shown on iOS and macOS)
                if viewModel.hasAnyUnreadMessages {
                    Button(action: { viewModel.openMostRelevantPrivateChat() }) {
                        Image(systemName: "envelope.fill")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(Color.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.open_unread_private_chat", comment: "Accessibility label for the unread private chat button")
                    )
                }
                // Notes icon (mesh only and when location is authorized), to the left of #mesh
                if case .mesh = locationManager.selectedChannel, locationManager.permissionState == .authorized {
                    Button(action: {
                        // Kick a one-shot refresh and show the sheet immediately.
                        LocationChannelManager.shared.enableLocationChannels()
                        LocationChannelManager.shared.refreshChannels()
                        // If we already have a block geohash, pass it; otherwise wait in the sheet.
                        notesGeohash = LocationChannelManager.shared.availableChannels.first(where: { $0.level == .building })?.geohash
                        showLocationNotes = true
                    }) {
                        HStack(alignment: .center, spacing: 4) {
                            let hasNotes = (notesCounter.count ?? 0) > 0
                            Image(systemName: "long.text.page.and.pencil")
                                .font(.bitchatSystem(size: 12))
                                .foregroundColor(hasNotes ? textColor : Color.gray)
                                .padding(.top, 1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(localized: "content.accessibility.location_notes", comment: "Accessibility label for location notes button")
                    )
                }

                // Bookmark toggle (geochats): to the left of #geohash
                if case .location(let ch) = locationManager.selectedChannel {
                    Button(action: { GeohashBookmarksStore.shared.toggle(ch.geohash) }) {
                        Image(systemName: GeohashBookmarksStore.shared.isBookmarked(ch.geohash) ? "bookmark.fill" : "bookmark")
                            .font(.bitchatSystem(size: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(
                            format: String(localized: "content.accessibility.toggle_bookmark", comment: "Accessibility label for toggling a geohash bookmark"),
                            locale: .current,
                            ch.geohash
                        )
                    )
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
                        .font(.bitchatSystem(size: 14, design: .monospaced))
                        .foregroundColor(badgeColor)
                        .lineLimit(headerLineLimit)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .accessibilityLabel(
                            String(localized: "content.accessibility.location_channels", comment: "Accessibility label for the location channels button")
                        )
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .padding(.trailing, 2)

                HStack(spacing: 4) {
                    // People icon with count
                    Image(systemName: "person.2.fill")
                        .font(.system(size: headerPeerIconSize, weight: .regular))
                        .accessibilityLabel(
                            String(
                                format: String(localized: "content.accessibility.people_count", comment: "Accessibility label announcing number of people in header"),
                                locale: .current,
                                headerOtherPeersCount
                            )
                        )
                    Text("\(headerOtherPeersCount)")
                        .font(.system(size: headerPeerCountFontSize, weight: .regular, design: .monospaced))
                        .accessibilityHidden(true)
                }
                .foregroundColor(headerCountColor)
                .padding(.leading, 2)
                .lineLimit(headerLineLimit)
                .fixedSize(horizontal: true, vertical: false)

                // QR moved to the PEOPLE header in the sidebar when on mesh channel
            }
            .layoutPriority(3)
            .onTapGesture {
                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                    showSidebar.toggle()
                }
            }
            .sheet(isPresented: $showVerifySheet) {
                VerificationSheetView(isPresented: $showVerifySheet)
                    .environmentObject(viewModel)
            }
        }
        .frame(height: headerHeight)
        .padding(.horizontal, 12)
        .sheet(isPresented: $showLocationChannelsSheet) {
            LocationChannelsSheet(isPresented: $showLocationChannelsSheet)
                .onAppear { viewModel.isLocationChannelsSheetPresented = true }
                .onDisappear { viewModel.isLocationChannelsSheetPresented = false }
        }
        .sheet(isPresented: $showLocationNotes, onDismiss: {
            notesGeohash = nil
        }) {
            Group {
                if let gh = notesGeohash ?? LocationChannelManager.shared.availableChannels.first(where: { $0.level == .building })?.geohash {
                    LocationNotesView(geohash: gh, onNotesCountChanged: { cnt in sheetNotesCount = cnt })
                        .environmentObject(viewModel)
                } else {
                    VStack(spacing: 12) {
                        HStack {
                            Text("content.notes.title")
                                .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
                            Spacer()
                            Button(action: { showLocationNotes = false }) {
                                Image(systemName: "xmark")
                                    .font(.bitchatSystem(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundColor(textColor)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "common.close", comment: "Accessibility label for close buttons"))
                        }
                        .frame(height: headerHeight)
                        .padding(.horizontal, 12)
                        .background(backgroundColor.opacity(0.95))
                        Text("content.notes.location_unavailable")
                            .font(.bitchatSystem(size: 14, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        Button("content.location.enable") {
                            LocationChannelManager.shared.enableLocationChannels()
                            LocationChannelManager.shared.refreshChannels()
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .background(backgroundColor)
                    .foregroundColor(textColor)
                    // per-sheet global onChange added below
                }
            }
            .onAppear {
                // Ensure we are authorized and start live location updates (distance-filtered)
                LocationChannelManager.shared.enableLocationChannels()
                LocationChannelManager.shared.beginLiveRefresh()
            }
            .onDisappear {
                LocationChannelManager.shared.endLiveRefresh()
            }
            .onChange(of: locationManager.availableChannels) { channels in
                if let current = channels.first(where: { $0.level == .building })?.geohash,
                    notesGeohash != current {
                    notesGeohash = current
                    #if os(iOS)
                    // Light taptic when geohash changes while the sheet is open
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.prepare()
                    generator.impactOccurred()
                    #endif
                }
            }
        }
        .onAppear {
            updateNotesCounterSubscription()
            if case .mesh = locationManager.selectedChannel,
               locationManager.permissionState == .authorized,
               LocationChannelManager.shared.availableChannels.isEmpty {
                LocationChannelManager.shared.refreshChannels()
            }
        }
        .onChange(of: locationManager.selectedChannel) { _ in
            updateNotesCounterSubscription()
            if case .mesh = locationManager.selectedChannel,
               locationManager.permissionState == .authorized,
               LocationChannelManager.shared.availableChannels.isEmpty {
                LocationChannelManager.shared.refreshChannels()
            }
        }
        .onChange(of: locationManager.availableChannels) { _ in updateNotesCounterSubscription() }
        .onChange(of: locationManager.permissionState) { _ in
            updateNotesCounterSubscription()
            if case .mesh = locationManager.selectedChannel,
               locationManager.permissionState == .authorized,
               LocationChannelManager.shared.availableChannels.isEmpty {
                LocationChannelManager.shared.refreshChannels()
            }
        }
        .alert("content.alert.screenshot.title", isPresented: $viewModel.showScreenshotPrivacyWarning) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("content.alert.screenshot.message")
        }
        .background(backgroundColor.opacity(0.95))
    }

}

// MARK: - Notes Counter Subscription Helper
extension ContentView {
    private func updateNotesCounterSubscription() {
        switch locationManager.selectedChannel {
        case .mesh:
            // Ensure we have a fresh one-shot location fix so building geohash is current
            if locationManager.permissionState == .authorized {
                LocationChannelManager.shared.refreshChannels()
            }
            if locationManager.permissionState == .authorized {
                if let building = LocationChannelManager.shared.availableChannels.first(where: { $0.level == .building })?.geohash {
                    LocationNotesCounter.shared.subscribe(geohash: building)
                } else {
                    // Keep existing subscription if we had one to avoid flicker
                    // Only cancel if we have no known geohash
                    if LocationNotesCounter.shared.geohash == nil {
                        LocationNotesCounter.shared.cancel()
                    }
                }
            } else {
                LocationNotesCounter.shared.cancel()
            }
        case .location:
            LocationNotesCounter.shared.cancel()
        }
    }
}
