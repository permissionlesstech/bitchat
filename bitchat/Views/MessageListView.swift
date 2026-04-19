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
    @EnvironmentObject private var publicChatModel: PublicChatModel
    @EnvironmentObject private var privateInboxModel: PrivateInboxModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel

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

        let messages = conversationMessages(for: privatePeer)
        let windowedMessages = Array(messages.suffix(currentWindowCount))

        let contextKey: String = {
            if let peer = privatePeer {
                "dm:\(peer)"
            } else {
                locationChannelsModel.selectedChannel.contextKey
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
                .transaction { tx in if conversationUIModel.isBatchingPublic { tx.disablesAnimations = true } }
                .padding(.vertical, 2)
            }
            .onOpenURL(perform: handleOpenURL)
            .onTapGesture(count: 3) {
                conversationUIModel.clearCurrentConversation()
            }
            .onAppear {
                scrollToBottom(on: proxy)
            }
            .onChange(of: privatePeer) { _ in
                scrollToBottom(on: proxy)
            }
            .onChange(of: publicChatModel.messages.count) { _ in
                onMessagesChange(proxy: proxy)
            }
            .onChange(of: privateMessageCount(for: privatePeer)) { _ in
                onPrivateChatsChange(proxy: proxy)
            }
            .onChange(of: locationChannelsModel.selectedChannel) { newChannel in
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
                        privateConversationModel.openConversation(for: peerID)
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            showSidebar = true
                        }
                    }
                }

                Button("content.actions.hug") {
                    if let sender = selectedMessageSender {
                        conversationUIModel.sendHug(to: sender)
                    }
                }

                Button("content.actions.slap") {
                    if let sender = selectedMessageSender {
                        conversationUIModel.sendSlap(to: sender)
                    }
                }

                Button("content.actions.block", role: .destructive) {
                    conversationUIModel.block(peerID: selectedMessageSenderID, displayName: selectedMessageSender)
                }

                Button("common.cancel", role: .cancel) {}
            }
            .onAppear {
                // Also check when view appears
                if let peerID = privatePeer {
                    // Try multiple times to ensure read receipts are sent
                    privateConversationModel.markMessagesAsRead(from: peerID)

                    DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiReadReceiptRetryShortSeconds) {
                        privateConversationModel.markMessagesAsRead(from: peerID)
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiReadReceiptRetryLongSeconds) {
                        privateConversationModel.markMessagesAsRead(from: peerID)
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
            } else if let media = conversationUIModel.mediaAttachment(for: message) {
                MediaMessageView(message: message, media: media, imagePreviewURL: $imagePreviewURL)
            } else {
                TextMessageView(message: message)
            }
        }
    }

    @ViewBuilder
    func systemMessageRow(_ message: BitchatMessage) -> some View {
        Text(conversationUIModel.formatMessage(message, colorScheme: colorScheme))
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
                locationChannelsModel.selectedChannel.contextKey
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

            selectedMessageSender = conversationUIModel.senderDisplayName(
                for: peerID,
                fallbackMessages: conversationMessages(for: privatePeer)
            )

            if conversationUIModel.isSelfSender(peerID: peerID, displayName: selectedMessageSender) {
                selectedMessageSender = nil
                selectedMessageSenderID = nil
            } else {
                showMessageActions = true
            }

        case "geohash":
            let gh = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            let allowed = Set("0123456789bcdefghjkmnpqrstuvwxyz")
            guard (2...12).contains(gh.count), gh.allSatisfy({ allowed.contains($0) }) else { return }
            locationChannelsModel.openLocationChannel(for: gh)

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
           let last = privateInboxModel.messages(for: peer).suffix(300).last?.id {
            return "dm:\(peer)|\(last)"
        }
        if let last = publicChatModel.messages.suffix(300).last?.id {
            return "\(locationChannelsModel.selectedChannel.contextKey)|\(last)"
        }
        return nil
    }

    func onMessagesChange(proxy: ScrollViewProxy) {
        let messages = publicChatModel.messages
        guard privatePeer == nil, let lastMsg = messages.last else { return }

        // If the newest message is from me, always scroll to bottom
        let isFromSelf = conversationUIModel.isSentByCurrentUser(lastMsg)
        if !isFromSelf && !isAtBottom { // Only autoscroll when user is at/near bottom
            return
        } else { // Ensure we consider ourselves at bottom for subsequent messages
            isAtBottom = true
        }

        func scrollIfNeeded(date: Date) {
            lastScrollTime = date
            let contextKey = locationChannelsModel.selectedChannel.contextKey
            if let target = messages.suffix(windowCountPublic).last.map({ "\(contextKey)|\($0.id)" }) {
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
        guard let peerID = privatePeer,
              let lastMsg = privateInboxModel.messages(for: peerID).last else {
            return
        }
        let messages = privateInboxModel.messages(for: peerID)

        // If the newest private message is from me, always scroll
        let isFromSelf = conversationUIModel.isSentByCurrentUser(lastMsg)
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
            if let target = publicChatModel.messages.suffix(windowCountPublic).last?.id.map({ "\(contextKey)|\($0)" }) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    func conversationMessages(for privatePeer: PeerID?) -> [BitchatMessage] {
        if let privatePeer {
            return privateInboxModel.messages(for: privatePeer)
        }
        return publicChatModel.messages
    }

    func privateMessageCount(for privatePeer: PeerID?) -> Int {
        conversationMessages(for: privatePeer).count
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
