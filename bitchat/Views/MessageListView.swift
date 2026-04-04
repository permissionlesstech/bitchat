//
//  MessageListView.swift
//  bitchat
//
//  Created by Islam on 30/03/2026.
//

import BitFoundation
import SwiftUI

private struct MessageDisplayItem: Identifiable {
    let id: String
    let message: BitchatMessage
}

struct MessageListView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var locationManager = LocationChannelManager.shared

    @Environment(\.colorScheme) private var colorScheme

    let privatePeer: PeerID?
    @Binding var isAtBottom: Bool
    @Binding var messageText: String
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var showSidebar: Bool

    var isTextFieldFocused: FocusState<Bool>.Binding

    @State private var showMessageActions = false
    @State private var lastScrollTime: Date = .distantPast
    @State private var scrollThrottleTimer: Timer?

    var body: some View {
        let currentWindowCount: Int = {
            if let peer = privatePeer {
                return windowCountPrivate[peer] ?? TransportConfig.uiWindowInitialCountPrivate
            }
            return windowCountPublic
        }()

        let messages = viewModel.getMessages(for: privatePeer)
        let windowedMessages = Array(messages.suffix(currentWindowCount))

        let contextKey: String = {
            if let peer = privatePeer {
                "dm:\(peer)"
            } else {
                locationManager.selectedChannel.contextKey
            }
        }()

        let messageItems: [MessageDisplayItem] = windowedMessages.compactMap { message in
            guard !message.content.trimmed.isEmpty else { return nil }
            return MessageDisplayItem(id: "\(contextKey)|\(message.id)", message: message)
        }

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(messageItems) { item in
                        let message = item.message
                        messageRow(for: message)
                            .onAppear {
                                if message.id == windowedMessages.last?.id {
                                    isAtBottom = true
                                }
                                if message.id == windowedMessages.first?.id,
                                   messages.count > windowedMessages.count {
                                    expandWindow(
                                        ifNeededFor: message,
                                        allMessages: messages,
                                        privatePeer: privatePeer,
                                        proxy: proxy
                                    )
                                }
                            }
                            .onDisappear {
                                if message.id == windowedMessages.last?.id {
                                    isAtBottom = false
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if message.sender != "system" {
                                    messageText = "@\(message.sender) "
                                    isTextFieldFocused.wrappedValue = true
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
                            .padding(.vertical, 1)
                    }
                }
                .transaction { tx in if viewModel.isBatchingPublic { tx.disablesAnimations = true } }
                .padding(.vertical, 2)
            }
            .onOpenURL(perform: handleOpenURL)
            .onTapGesture(count: 3) {
                viewModel.sendMessage("/clear")
            }
            .onAppear {
                scrollToBottom(on: proxy)
            }
            .onChange(of: privatePeer) { _ in
                scrollToBottom(on: proxy)
            }
            .onChange(of: viewModel.messages.count) { _ in
                onMessagesChange(proxy: proxy)
            }
            .onChange(of: viewModel.privateChats) { _ in
                onPrivateChatsChange(proxy: proxy)
            }
            .onChange(of: locationManager.selectedChannel) { newChannel in
                onSelectedChannelChange(newChannel, proxy: proxy)
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
                        isTextFieldFocused.wrappedValue = true
                    }
                }

                Button("content.actions.direct_message") {
                    if let peerID = selectedMessageSenderID {
                        if peerID.isGeoChat {
                            if let full = viewModel.fullNostrHex(forSenderPeerID: peerID) {
                                viewModel.startGeohashDM(withPubkeyHex: full)
                            }
                        } else {
                            viewModel.startPrivateChat(with: peerID)
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
                    if let peerID = selectedMessageSenderID, peerID.isGeoChat,
                       let full = viewModel.fullNostrHex(forSenderPeerID: peerID),
                       let sender = selectedMessageSender {
                        viewModel.blockGeohashUser(pubkeyHexLowercased: full, displayName: sender)
                    } else if let sender = selectedMessageSender {
                        viewModel.sendMessage("/block \(sender)")
                    }
                }

                Button("common.cancel", role: .cancel) {}
            }
            .onAppear {
                // Also check when view appears
                if let peerID = privatePeer {
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
            .onDisappear {
                scrollThrottleTimer?.invalidate()
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
}

private extension MessageListView {
    @ViewBuilder
    func messageRow(for message: BitchatMessage) -> some View {
        Group {
            if message.sender == "system" {
                systemMessageRow(message)
            } else if let media = message.mediaAttachment(for: viewModel.nickname) {
                MediaMessageView(message: message, media: media, imagePreviewURL: $imagePreviewURL)
            } else {
                TextMessageView(message: message)
            }
        }
    }

    @ViewBuilder
    func systemMessageRow(_ message: BitchatMessage) -> some View {
        Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func expandWindow(ifNeededFor message: BitchatMessage,
                      allMessages: [BitchatMessage],
                      privatePeer: PeerID?,
                      proxy: ScrollViewProxy) {
        let step = TransportConfig.uiWindowStepCount
        let contextKey: String = {
            if let peer = privatePeer {
                "dm:\(peer)"
            } else {
                locationManager.selectedChannel.contextKey
            }
        }()
        let preserveID = "\(contextKey)|\(message.id)"

        if let peer = privatePeer {
            let current = windowCountPrivate[peer] ?? TransportConfig.uiWindowInitialCountPrivate
            let newCount = min(allMessages.count, current + step)
            guard newCount != current else { return }
            windowCountPrivate[peer] = newCount
            DispatchQueue.main.async {
                proxy.scrollTo(preserveID, anchor: .top)
            }
        } else {
            let current = windowCountPublic
            let newCount = min(allMessages.count, current + step)
            guard newCount != current else { return }
            windowCountPublic = newCount
            DispatchQueue.main.async {
                proxy.scrollTo(preserveID, anchor: .top)
            }
        }
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme == "bitchat" else { return }
        switch url.host {
        case "user":
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let peerID = PeerID(str: id.removingPercentEncoding ?? id)
            selectedMessageSenderID = peerID

            if peerID.isGeoDM || peerID.isGeoChat {
                selectedMessageSender = viewModel.geohashDisplayName(for: peerID)
            } else if let name = viewModel.meshService.peerNickname(peerID: peerID) {
                selectedMessageSender = name
            } else {
                selectedMessageSender = viewModel.messages.last(where: { $0.senderPeerID == peerID && $0.sender != "system" })?.sender
            }

            if viewModel.isSelfSender(peerID: peerID, displayName: selectedMessageSender) {
                selectedMessageSender = nil
                selectedMessageSenderID = nil
            } else {
                showMessageActions = true
            }

        case "geohash":
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
            let channel = GeohashChannel(level: level, geohash: gh)

            let inRegional = LocationChannelManager.shared.availableChannels.contains { $0.geohash == gh }
            if !inRegional && !LocationChannelManager.shared.availableChannels.isEmpty {
                LocationChannelManager.shared.markTeleported(for: gh, true)
            }
            LocationChannelManager.shared.select(ChannelID.location(channel))

        default:
            return
        }
    }

    func scrollToBottom(on proxy: ScrollViewProxy) {
        isAtBottom = true
        if let targetPeerID {
            proxy.scrollTo(targetPeerID, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let secondTarget = self.targetPeerID {
                proxy.scrollTo(secondTarget, anchor: .bottom)
            }
        }
    }

    var targetPeerID: String? {
        if let peer = privatePeer,
           let last = viewModel.getPrivateChatMessages(for: peer).suffix(300).last?.id {
            return "dm:\(peer)|\(last)"
        }
        if let last = viewModel.messages.suffix(300).last?.id {
            return "\(locationManager.selectedChannel.contextKey)|\(last)"
        }
        return nil
    }

    func onMessagesChange(proxy: ScrollViewProxy) {
        guard privatePeer == nil, let lastMsg = viewModel.messages.last else { return }

        // If the newest message is from me, always scroll to bottom
        let isFromSelf = (lastMsg.sender == viewModel.nickname) || lastMsg.sender.hasPrefix(viewModel.nickname + "#")
        if !isFromSelf && !isAtBottom { // Only autoscroll when user is at/near bottom
            return
        } else { // Ensure we consider ourselves at bottom for subsequent messages
            isAtBottom = true
        }

        func scrollIfNeeded(date: Date) {
            lastScrollTime = date
            let contextKey = locationManager.selectedChannel.contextKey
            if let target = viewModel.messages.suffix(windowCountPublic).last.map({ "\(contextKey)|\($0.id)" }) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }

        // Throttle scroll animations to prevent excessive UI updates
        let now = Date()
        if now.timeIntervalSince(lastScrollTime) > TransportConfig.uiScrollThrottleSeconds {
            // Immediate scroll if enough time has passed
            scrollIfNeeded(date: now)
        } else {
            // Schedule a delayed scroll
            scrollThrottleTimer?.invalidate()
            scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: TransportConfig.uiScrollThrottleSeconds, repeats: false) { _ in
                Task { @MainActor in
                    scrollIfNeeded(date: Date())
                }
            }
        }
    }

    func onPrivateChatsChange(proxy: ScrollViewProxy) {
        guard let peerID = privatePeer, let messages = viewModel.privateChats[peerID], let lastMsg = messages.last else {
            return
        }

        // If the newest private message is from me, always scroll
        let isFromSelf = (lastMsg.sender == viewModel.nickname) || lastMsg.sender.hasPrefix(viewModel.nickname + "#")
        if !isFromSelf && !isAtBottom { // Only autoscroll when user is at/near bottom
            return
        } else {
            isAtBottom = true
        }

        func scrollIfNeeded(date: Date) {
            lastScrollTime = date
            let contextKey = "dm:\(peerID)"
            let count = windowCountPrivate[peerID] ?? 300
            if let target = messages.suffix(count).last.map({ "\(contextKey)|\($0.id)" }){
                proxy.scrollTo(target, anchor: .bottom)
            }
        }

        // Same throttling for private chats
        let now = Date()
        if now.timeIntervalSince(lastScrollTime) > TransportConfig.uiScrollThrottleSeconds {
            scrollIfNeeded(date: now)
        } else {
            scrollThrottleTimer?.invalidate()
            scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: TransportConfig.uiScrollThrottleSeconds, repeats: false) { _ in
                Task { @MainActor in
                    scrollIfNeeded(date: Date())
                }
            }
        }
    }

    func onSelectedChannelChange(_ channel: ChannelID, proxy: ScrollViewProxy) {
        // When switching to a new geohash channel, scroll to the bottom
        guard privatePeer == nil else { return }
        switch channel {
        case .mesh:
            break
        case .location(let ch):
            // Reset window size
            isAtBottom = true
            windowCountPublic = TransportConfig.uiWindowInitialCountPublic
            let contextKey = "geo:\(ch.geohash)"
            if let target = viewModel.messages.suffix(windowCountPublic).last?.id.map({ "\(contextKey)|\($0)" }) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }
}

private extension ChannelID {
    var contextKey: String {
        switch self {
        case .mesh:             "mesh"
        case .location(let ch): "geo:\(ch.geohash)"
        }
    }
}

//#Preview {
//    MessageListView()
//}
