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
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @ObservedObject private var nearbyNotes = NearbyNotesCounter.shared

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var theme

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
    @State private var showClearConfirmation = false
    @State private var lastScrollTime: Date = .distantPast
    @State private var scrollThrottleTimer: Timer?
    @State private var unseenCount = 0
    @State private var lastSeenMessageCount = 0
    /// Context key the unseen counters were baselined against. Channel
    /// switches swap the timeline wholesale, so a count delta is only a
    /// "new messages" signal while the context is unchanged.
    @State private var unseenBaselineKey = ""
    /// Whether this instance holds the nearby-notes counter active (mesh
    /// public timeline only); balanced against activate/deactivate.
    @State private var holdsNotesCounter = false

    @ThemedPalette private var palette

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

        VStack(spacing: 0) {
        // Notes pinned to this place stay visible while chatting — a
        // conversation starting must not hide what's left here.
        if privatePeer == nil,
           case .mesh = locationChannelsModel.selectedChannel,
           nearbyNotes.noteCount > 0 {
            notesHereStrip
        }
        GeometryReader { geometry in
        ScrollViewReader { proxy in
            ScrollView {
                if messageItems.isEmpty && privatePeer == nil {
                    publicEmptyState(fillHeight: geometry.size.height)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(messageItems) { item in
                        let message = item.message
                        messageRow(for: message)
                            .onAppear {
                                if message.id == windowedMessages.last?.id {
                                    isAtBottom = true
                                    unseenCount = 0
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
                            .contextMenu {
                                let showsUserActions = message.sender != "system" && !conversationUIModel.isSentByCurrentUser(message)
                                if showsUserActions {
                                    // Mention and DM are redundant inside a 1:1 conversation:
                                    // mentioning the only other participant is noise, and "DM"
                                    // would just reopen the conversation that is already open.
                                    if privatePeer == nil {
                                        Button("content.actions.mention") {
                                            insertMention(message.sender)
                                        }
                                        if let peerID = message.senderPeerID {
                                            Button("content.actions.direct_message") {
                                                privateConversationModel.openConversation(for: peerID)
                                                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                                                    showSidebar = true
                                                }
                                            }
                                        }
                                    }
                                    Button("content.actions.hug") {
                                        conversationUIModel.sendHug(to: message.sender)
                                    }
                                    Button("content.actions.slap") {
                                        conversationUIModel.sendSlap(to: message.sender)
                                    }
                                }
                                Button("content.message.copy") {
                                    #if os(iOS)
                                    UIPasteboard.general.string = message.content
                                    #else
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(message.content, forType: .string)
                                    #endif
                                }
                                if isResendableFailedMessage(message) {
                                    Button("content.actions.resend") {
                                        conversationUIModel.resendFailedPrivateMessage(message)
                                    }
                                }
                                if showsUserActions {
                                    Button("content.actions.block", role: .destructive) {
                                        conversationUIModel.block(peerID: message.senderPeerID, displayName: message.sender)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                            // Archived echoes read as one tinted block, not
                            // just faded rows.
                            .background(message.isArchivedEcho ? palette.secondary.opacity(0.08) : Color.clear)
                    }
                }
                .transaction { tx in if conversationUIModel.isBatchingPublic { tx.disablesAnimations = true } }
                .padding(.vertical, 2)

                // Only carried history on screen: the ambient layer (radar,
                // sightings, live hints) stays visible below it instead of
                // vanishing the moment echoes exist.
                if privatePeer == nil, showsAmbientFooter(messageItems: messageItems) {
                    MeshEmptyStateView(compact: true)
                        .padding(.horizontal, 12)
                        .padding(.top, 20)
                        .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom && !messageItems.isEmpty {
                    jumpToLatestPill(proxy: proxy)
                }
            }
            .onOpenURL(perform: handleOpenURL)
            .onTapGesture(count: 3) {
                showClearConfirmation = true
            }
            .confirmationDialog(
                "content.clear.confirm_title",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("content.clear.confirm_action", role: .destructive) {
                    conversationUIModel.clearCurrentConversation()
                }
                Button("common.cancel", role: .cancel) {}
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
                        insertMention(sender)
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
        }
        }
        .onAppear { updateNotesCounterHold() }
        .onDisappear { releaseNotesCounterHold() }
        .onChange(of: locationChannelsModel.selectedChannel) { _ in updateNotesCounterHold() }
        .onChange(of: privatePeer) { _ in updateNotesCounterHold() }
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
    var currentContextKey: String {
        if let peer = privatePeer {
            return "dm:\(peer)"
        }
        return locationChannelsModel.selectedChannel.contextKey
    }

    /// Tappable strip above the mesh timeline while notes are pinned at this
    /// place: opens the notices sheet on the geo tab.
    var notesHereStrip: some View {
        let text: String = nearbyNotes.noteCount == 1
            ? String(localized: "content.empty.notes_one", comment: "Hint when exactly one note was left at this place")
            : String(
                format: String(localized: "content.empty.notes_many", comment: "Hint counting notes left at this place"),
                locale: .current,
                nearbyNotes.noteCount
            )

        return Button {
            appChromeModel.presentNotices(geoTab: true)
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: "📍 \(text)")
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.bitchatSystem(size: 10))
                    .foregroundColor(palette.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(palette.secondary.opacity(0.08))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The nearby-notes counter is held whenever the mesh public timeline is
    /// showing — the strip needs a live count before it can decide to exist.
    /// Holding is not subscribing: nothing hits the relays until an explicit
    /// act reveals the counter (tap-to-reveal).
    func updateNotesCounterHold() {
        let shouldHold = privatePeer == nil && locationChannelsModel.selectedChannel.isMesh
        guard shouldHold != holdsNotesCounter else { return }
        holdsNotesCounter = shouldHold
        if shouldHold {
            NearbyNotesCounter.shared.activate()
        } else {
            NearbyNotesCounter.shared.deactivate()
        }
    }

    func releaseNotesCounterHold() {
        guard holdsNotesCounter else { return }
        holdsNotesCounter = false
        NearbyNotesCounter.shared.deactivate()
    }

    /// True when the mesh timeline holds nothing but archived echoes and
    /// system lines — no live conversation yet, so the ambient layer still
    /// applies.
    private func showsAmbientFooter(messageItems: [MessageDisplayItem]) -> Bool {
        guard case .mesh = locationChannelsModel.selectedChannel,
              !messageItems.isEmpty else { return false }
        return messageItems.allSatisfy { $0.message.isArchivedEcho || $0.message.sender == "system" }
    }

    /// Terminal-styled narration for an empty public timeline: says which
    /// channel this is, that the app is waiting for peers, and where to go
    /// next. Rendered inside the ScrollView; disappears with the first row.
    /// The mesh case fills the visible chat height so its radar can center
    /// in the space below the text.
    func publicEmptyState(fillHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch locationChannelsModel.selectedChannel {
            case .mesh:
                MeshEmptyStateView(fillHeight: max(0, fillHeight - 24))
            case .location(let channel):
                emptyStateLine(
                    String(
                        format: String(localized: "content.empty.location_intro", comment: "First line of an empty geohash timeline naming the channel"),
                        locale: .current,
                        channel.geohash
                    )
                )
                emptyStateLine(String(localized: "content.empty.switch_hint", comment: "Empty timeline hint pointing at the channel switcher and the help screen"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func emptyStateLine(_ text: String) -> some View {
        // Non-breaking space before the closing asterisk so a tight wrap
        // can't orphan a lone "*" onto its own line.
        Text(verbatim: "* \(text)\u{00A0}*")
            .bitchatFont(size: 13)
            .foregroundColor(palette.secondary.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Messages the unseen counters may book as "new": rows that render as
    /// human messages. System lines render as narration and whitespace-only
    /// content never renders at all, so neither belongs in the pill count.
    func unseenEligibleCount(in messages: [BitchatMessage]) -> Int {
        messages.filter { $0.sender != "system" && !$0.content.trimmed.isEmpty }.count
    }

    /// Updates the unseen-count baseline for the current context and returns
    /// how many messages were appended since the last observation. A context
    /// change (timeline swapped wholesale) re-baselines and reports zero, so
    /// cross-channel count differences are never booked as "new" messages.
    func rebaselinedAppendedCount(newCount: Int) -> Int {
        let key = currentContextKey
        if unseenBaselineKey != key {
            unseenBaselineKey = key
            unseenCount = 0
            lastSeenMessageCount = newCount
            return 0
        }
        let appended = max(0, newCount - lastSeenMessageCount)
        lastSeenMessageCount = newCount
        return appended
    }

    /// A failed private text message of our own can be resent through the
    /// normal send path (the context menu removes the failed original and
    /// re-submits its content).
    func isResendableFailedMessage(_ message: BitchatMessage) -> Bool {
        guard message.isPrivate,
              conversationUIModel.isSentByCurrentUser(message),
              conversationUIModel.mediaAttachment(for: message) == nil,
              case .some(.failed) = message.deliveryStatus
        else { return false }
        return true
    }

    /// Appends an @mention to the composer draft (never overwrites what the
    /// user has already typed) and focuses the input field.
    func insertMention(_ sender: String) {
        let mention = "@\(sender) "
        if messageText.isEmpty {
            messageText = mention
        } else if messageText.hasSuffix(" ") {
            messageText += mention
        } else {
            messageText += " " + mention
        }
        isTextFieldFocused.wrappedValue = true
    }

    /// Floating pill shown while scrolled up: re-presents the isAtBottom /
    /// unseenCount state the view already tracks, and jumps to the newest
    /// message via the existing scrollToBottom helper.
    func jumpToLatestPill(proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(on: proxy)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.bitchatSystem(size: 11, weight: .semibold))
                if unseenCount > 0 {
                    Text(
                        String(
                            format: String(localized: "content.jump.new_count", comment: "Count of messages that arrived while scrolled up, shown in the jump-to-latest pill"),
                            locale: .current,
                            unseenCount
                        )
                    )
                    .bitchatFont(size: 12, weight: .medium)
                }
            }
            .foregroundColor(palette.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedOverlayPanel()
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .accessibilityLabel(jumpToLatestAccessibilityLabel)
    }

    var jumpToLatestAccessibilityLabel: String {
        let base = String(localized: "content.accessibility.jump_to_latest", comment: "Accessibility label for the jump to latest messages button")
        guard unseenCount > 0 else { return base }
        let count = String(
            format: String(localized: "content.jump.new_count", comment: "Count of messages that arrived while scrolled up, shown in the jump-to-latest pill"),
            locale: .current,
            unseenCount
        )
        return "\(base), \(count)"
    }

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
        // Archived echoes ("heard here earlier") render dimmed: real history,
        // visually distinct from the live conversation.
        .opacity(message.isArchivedEcho ? 0.55 : 1)
    }

    @ViewBuilder
    func systemMessageRow(_ message: BitchatMessage) -> some View {
        Text(conversationUIModel.formatMessage(message, colorScheme: colorScheme, theme: theme))
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
        unseenCount = 0
        lastSeenMessageCount = unseenEligibleCount(in: conversationMessages(for: privatePeer))
        unseenBaselineKey = currentContextKey
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
           let last = privateInboxModel.messages(for: peer).last?.id {
            return "dm:\(peer)|\(last)"
        }
        if let last = publicChatModel.messages.last?.id {
            return "\(locationChannelsModel.selectedChannel.contextKey)|\(last)"
        }
        return nil
    }

    func onMessagesChange(proxy: ScrollViewProxy) {
        guard privatePeer == nil else { return }
        let messages = publicChatModel.messages
        let appendedCount = rebaselinedAppendedCount(newCount: unseenEligibleCount(in: messages))
        guard let lastMsg = messages.last else {
            // Timeline emptied (e.g. /clear): nothing below to jump to.
            unseenCount = 0
            return
        }

        // If the newest message is from me, always scroll to bottom
        let isFromSelf = conversationUIModel.isSentByCurrentUser(lastMsg)
        if !isFromSelf && !isAtBottom { // Only autoscroll when user is at/near bottom
            unseenCount += appendedCount
            return
        } else { // Ensure we consider ourselves at bottom for subsequent messages
            isAtBottom = true
            unseenCount = 0
        }

        func scrollIfNeeded(date: Date) {
            lastScrollTime = date
            let contextKey = locationChannelsModel.selectedChannel.contextKey
            if let target = messages.last.map({ "\(contextKey)|\($0.id)" }) {
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
        guard let peerID = privatePeer else { return }
        let messages = privateInboxModel.messages(for: peerID)
        let appendedCount = rebaselinedAppendedCount(newCount: unseenEligibleCount(in: messages))
        guard let lastMsg = messages.last else {
            // Timeline emptied (e.g. /clear): nothing below to jump to.
            unseenCount = 0
            return
        }

        // If the newest private message is from me, always scroll
        let isFromSelf = conversationUIModel.isSentByCurrentUser(lastMsg)
        if !isFromSelf && !isAtBottom { // Only autoscroll when user is at/near bottom
            unseenCount += appendedCount
            return
        } else {
            isAtBottom = true
            unseenCount = 0
        }

        func scrollIfNeeded(date: Date) {
            lastScrollTime = date
            let contextKey = "dm:\(peerID)"
            if let target = messages.last.map({ "\(contextKey)|\($0.id)" }) {
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
        // Invalidate the unseen baseline: the timeline is about to swap (or
        // already has — the ordering of this onChange vs the count onChange
        // is not guaranteed), so the next count observation re-baselines
        // instead of booking the cross-channel difference as "new".
        unseenCount = 0
        unseenBaselineKey = ""
        // Entering any public channel shows its latest messages: a channel
        // switch swaps the timeline wholesale, so the prior scroll offset is
        // meaningless. Landing at the bottom keeps isAtBottom honest (no
        // stale jump-to-latest pill) and matches standard chat behavior.
        isAtBottom = true
        windowCountPublic = TransportConfig.uiWindowInitialCountPublic
        let contextKey: String
        switch channel {
        case .mesh:
            contextKey = "mesh"
        case .location(let ch):
            contextKey = "geo:\(ch.geohash)"
        }
        if let target = publicChatModel.messages.last?.id.map({ "\(contextKey)|\($0)" }) {
            proxy.scrollTo(target, anchor: .bottom)
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

// #Preview {
//    MessageListView()
// }
