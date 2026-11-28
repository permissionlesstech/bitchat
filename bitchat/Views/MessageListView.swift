//
//  MessageListView.swift
//  bitchat
//
//  Created by Islam on 30/03/2026.
//

import BitFoundation
import CoreBluetooth
import SwiftUI

private struct MessageDisplayItem: Identifiable {
    let id: String
    let message: BitchatMessage
}

/// What the list's change detection keys on. The count alone stops moving
/// once the store's cap evicts the oldest message on every append, so the IDs
/// at both ends ride along, and the context key makes a switch to another
/// timeline one change even between two empty ones. The DM peer rides along
/// because the deprecated `onChange(of:perform:)` runs the closure from the
/// previous render, whose `privatePeer` is still the old one right after a
/// DM switch.
private struct TimelineSignature: Equatable {
    let privatePeer: PeerID?
    let contextKey: String
    // periphery:ignore - read only via the synthesized Equatable
    // conformance (onChange's comparison), which the indexer cannot
    // attribute.
    let count: Int
    // periphery:ignore - see `count`.
    let firstMessageID: String?
    // periphery:ignore - see `count`.
    let lastMessageID: String?

    init(privatePeer: PeerID?, contextKey: String, messages: [BitchatMessage]) {
        self.privatePeer = privatePeer
        self.contextKey = contextKey
        count = messages.count
        firstMessageID = messages.first?.id
        lastMessageID = messages.last?.id
    }
}

/// Public timeline host: observes only public-channel state so private DM
/// traffic never invalidates the public message list.
struct PublicMessageListView: View {
    @EnvironmentObject private var publicChatModel: PublicChatModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var appChromeModel: AppChromeModel

    @Binding var isAtBottom: Bool
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var showSidebar: Bool
    var isTextFieldFocused: FocusState<Bool>.Binding
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0

    /// Whether this instance holds the nearby-notes counter active (mesh
    /// public timeline only); balanced against activate/deactivate.
    @State private var holdsNotesCounter = false

    var body: some View {
        MessageListContentView(
            privatePeer: nil,
            messages: publicChatModel.messages,
            contextKey: publicChatModel.activeChannel.contextKey,
            selectedPublicChannel: locationChannelsModel.selectedChannel,
            bluetoothCanScan: bluetoothCanScan,
            topContentInset: topContentInset,
            bottomContentInset: bottomContentInset,
            liveMessages: { _ in publicChatModel.messages },
            liveContextKey: { _ in publicChatModel.activeChannel.contextKey },
            liveWindowCount: { _ in windowCountPublic },
            setWindowCount: { count, _ in windowCountPublic = count },
            isAtBottom: $isAtBottom,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            showSidebar: $showSidebar,
            isTextFieldFocused: isTextFieldFocused
        )
        .onAppear { updateNotesCounterHold() }
        .onDisappear { releaseNotesCounterHold() }
        .onChange(of: locationChannelsModel.selectedChannel) { _ in updateNotesCounterHold() }
    }

    /// Whether the radio could be scanning at all — the empty-state radar
    /// must not sweep over a switched-off or denied radio.
    private var bluetoothCanScan: Bool {
        switch appChromeModel.bluetoothState {
        case .poweredOff, .unauthorized, .unsupported: return false
        default: return true
        }
    }

    /// The nearby-notes counter is held whenever the mesh public timeline is
    /// showing — the strip needs a live count before it can decide to exist.
    /// Holding is not subscribing: nothing hits the relays until an explicit
    /// act reveals the counter (tap-to-reveal).
    private func updateNotesCounterHold() {
        let shouldHold = locationChannelsModel.selectedChannel.isMesh
        guard shouldHold != holdsNotesCounter else { return }
        holdsNotesCounter = shouldHold
        if shouldHold {
            NearbyNotesCounter.shared.activate()
        } else {
            NearbyNotesCounter.shared.deactivate()
        }
    }

    private func releaseNotesCounterHold() {
        guard holdsNotesCounter else { return }
        holdsNotesCounter = false
        NearbyNotesCounter.shared.deactivate()
    }
}

/// Tappable strip beneath the header while notes are pinned at this place
/// on the mesh channel: opens the notices sheet on the geo tab. Hosted
/// inside `ContentView.headerView` rather than a nested `.safeAreaInset`
/// so the header chrome contributes a single measured top inset.
struct NearbyNotesStripView: View {
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @ObservedObject private var nearbyNotes = NearbyNotesCounter.shared
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    var body: some View {
        if case .mesh = locationChannelsModel.selectedChannel,
           nearbyNotes.noteCount > 0 {
            let text: String = nearbyNotes.noteCount == 1
                ? String(localized: "content.empty.notes_one", comment: "Hint when exactly one note was left at this place")
                : String(
                    format: String(localized: "content.empty.notes_many", comment: "Hint counting notes left at this place"),
                    locale: .current,
                    nearbyNotes.noteCount
                )

            Button {
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
                .background(theme.usesGlassChrome ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(palette.background))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Private DM timeline host: observes only `PrivateInboxModel` so public
/// channel messages, location updates, and nearby-note counts never invalidate
/// an open direct-message timeline.
struct PrivateMessageListView: View {
    @EnvironmentObject private var privateInboxModel: PrivateInboxModel

    let privatePeer: PeerID?
    @Binding var isAtBottom: Bool
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var showSidebar: Bool
    var isTextFieldFocused: FocusState<Bool>.Binding

    var body: some View {
        MessageListContentView(
            privatePeer: privatePeer,
            messages: privateInboxModel.messages(for: privatePeer),
            contextKey: Self.contextKey(for: privatePeer),
            selectedPublicChannel: nil,
            bluetoothCanScan: false,
            topContentInset: 0,
            bottomContentInset: 0,
            liveMessages: { peer in privateInboxModel.messages(for: peer) },
            liveContextKey: { peer in Self.contextKey(for: peer) },
            liveWindowCount: { peer in
                if let peer {
                    return windowCountPrivate[peer] ?? TransportConfig.uiWindowInitialCountPrivate
                }
                return TransportConfig.uiWindowInitialCountPrivate
            },
            setWindowCount: { count, peer in
                if let peer {
                    windowCountPrivate[peer] = count
                }
            },
            isAtBottom: $isAtBottom,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            showSidebar: $showSidebar,
            isTextFieldFocused: isTextFieldFocused
        )
    }

    private static func contextKey(for peer: PeerID?) -> String {
        if let peer {
            return "dm:\(peer)"
        }
        return "dm:none"
    }
}

private struct MessageListContentView: View {
    private static let allowedGeohashChars = Set("0123456789bcdefghjkmnpqrstuvwxyz")

    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @Environment(\.appEnvironmentModels) private var appEnvironmentModels

    let privatePeer: PeerID?
    let messages: [BitchatMessage]
    let contextKey: String
    let selectedPublicChannel: ChannelID?
    let bluetoothCanScan: Bool
    let topContentInset: CGFloat
    let bottomContentInset: CGFloat
    let liveMessages: (PeerID?) -> [BitchatMessage]
    let liveContextKey: (PeerID?) -> String
    let liveWindowCount: (PeerID?) -> Int
    let setWindowCount: (Int, PeerID?) -> Void

    @Binding var isAtBottom: Bool
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var showSidebar: Bool

    var isTextFieldFocused: FocusState<Bool>.Binding

    @State private var showMessageActions = false
    @State private var showClearConfirmation = false
    @State private var lastScrollTime: Date = .distantPast
    @State private var scrollThrottleTimer: Timer?
    @State private var unseenCount = 0
    /// The timeline as of the last change this list observed: its newest
    /// message (the next change counts what landed after it) and the
    /// window's first row (kept in place while the reader is scrolled up).
    /// Marks are per context: channel switches swap the timeline wholesale,
    /// so a difference only means "new messages" within one context. Its
    /// context is the one the list has landed in; row callbacks from any
    /// other timeline are ignored.
    @State private var timelineMark: MessageListScrollPolicy.TimelineMark?
    /// Row whose appearance last put the list at the bottom, cleared when it
    /// leaves the screen. Its leaving means the reader scrolled up, even while
    /// a newer row that landed below it has not appeared yet.
    @State private var bottomRowID: String?
    /// Set while an expansion's position-restoring scroll is still queued.
    @State private var isRestoringExpansion = false
    /// Context whose newest row has appeared since the list appeared or
    /// landed in it, i.e. whose scroll to the bottom has landed. Window
    /// expansion waits for it.
    @State private var bottomSettledContextKey: String?
    /// Visible height of the scroll viewport, read non-structurally only while
    /// the empty mesh state needs it to center its radar. Keeping GeometryReader
    /// out from around ScrollView prevents double top safe-area insets under
    /// Liquid Glass's `.safeAreaInset` chrome.
    @State private var emptyStateViewportHeight: CGFloat = 0

    @ThemedPalette private var palette

    var body: some View {
        let currentWindowCount = liveWindowCount(privatePeer)

        // While the reader is scrolled up, messages landing below the
        // window's first row widen the window in this same render instead of
        // pushing that row out of the top, which would shift what they are
        // reading (onTimelineChange then records the wider window).
        let renderedWindowCount = isAtBottom
            ? currentWindowCount
            : MessageListScrollPolicy.windowCountKeepingFirstRow(
                current: currentWindowCount,
                mark: contextMark(for: contextKey),
                appendedCount: 0,
                in: messages
            )
        let windowedSlice = messages.suffix(renderedWindowCount)

        let messageItems: [MessageDisplayItem] = windowedSlice.compactMap { message in
            guard message.content.hasNonWhitespaceContent else { return nil }
            return MessageDisplayItem(id: "\(contextKey)|\(message.id)", message: message)
        }
        let hasEarlierMessages = messages.count > windowedSlice.count
        // Top edge of the rendered window (whitespace-only messages get no
        // row, so they could never report reaching it).
        let firstRowID = messageItems.first?.id
        let isEmptyPublic = messageItems.isEmpty && privatePeer == nil

        ScrollViewReader { proxy in
            ScrollView {
                if isEmptyPublic {
                    publicEmptyState(
                        fillHeight: max(0, emptyStateViewportHeight - topContentInset - bottomContentInset)
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(messageItems) { item in
                                let message = item.message
                                MessageRowView(
                                    message: message,
                                    deliveryStatus: message.deliveryStatus,
                                    privatePeer: privatePeer,
                                    imagePreviewURL: $imagePreviewURL,
                                    showSidebar: $showSidebar,
                                    onInsertMention: insertMention
                                )
                                .equatable()
                                .onAppear {
                                    // Callbacks lag a timeline switch: the new
                                    // rows appear before the old ones disappear,
                                    // each with its own render's view of which row
                                    // was last. Only rows of the timeline the list
                                    // has landed in may move its state, checked
                                    // against live state rather than the render's.
                                    guard isLandedRow(item.id) else { return }
                                    if item.id == newestRowID(for: privatePeer) {
                                        isAtBottom = true
                                        unseenCount = 0
                                        if bottomRowID != item.id {
                                            bottomRowID = item.id
                                        }
                                        if bottomSettledContextKey != contextKey {
                                            bottomSettledContextKey = contextKey
                                        }
                                        returnWindowToInitialSize(for: privatePeer, contextKey: contextKey, messages: messages)
                                    }
                                    if item.id == firstRowID, hasEarlierMessages {
                                        expandWindow(
                                            ifNeededFor: message,
                                            allMessages: messages,
                                            privatePeer: privatePeer,
                                            proxy: proxy
                                        )
                                    }
                                }
                                .onDisappear {
                                    // A row of the landed timeline shares this
                                    // closure's peer, so newestRowID is live here.
                                    guard isLandedRow(item.id) else { return }
                                    if item.id == newestRowID(for: privatePeer) || item.id == bottomRowID {
                                        isAtBottom = false
                                        bottomRowID = nil
                                        // Leaving the bottom drops a follow-scroll
                                        // still waiting on the throttle: it would
                                        // yank the reader back down.
                                        cancelFollowScroll()
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)

                        // Only carried history on screen: the ambient layer (radar,
                        // sightings, live hints) stays visible below it instead of
                        // vanishing the moment echoes exist.
                        if privatePeer == nil, showsAmbientFooter(messageItems: messageItems) {
                            MeshEmptyStateView(compact: true, bluetoothAvailable: bluetoothCanScan)
                                .padding(.horizontal, 12)
                                .padding(.top, 20)
                                .padding(.bottom, 8)
                        }
                    }
                }
            }
            .modifier(ScrollChromeInsetsModifier(top: topContentInset, bottom: bottomContentInset))
            .background {
                if isEmptyPublic {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear {
                                if emptyStateViewportHeight != geometry.size.height {
                                    emptyStateViewportHeight = geometry.size.height
                                }
                            }
                            .onChange(of: geometry.size.height) { newHeight in
                                if emptyStateViewportHeight != newHeight {
                                    emptyStateViewportHeight = newHeight
                                }
                            }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom && !messageItems.isEmpty {
                    jumpToLatestPill(proxy: proxy)
                        .padding(.bottom, bottomContentInset)
                }
            }
            .onOpenURL(perform: handleOpenURL)
            .onTapGesture(count: 3) {
                showClearConfirmation = true
            }
            .confirmationDialog(
                String(localized: "content.clear.confirm_title"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "content.clear.confirm_action"), role: .destructive) {
                    conversationUIModel.clearCurrentConversation()
                }
                Button(String(localized: "common.cancel"), role: .cancel) {}
            }
            .onAppear {
                // Runs before the rows' onAppear: lands the list (and sets the
                // mark the row callbacks are checked against) before any row
                // reports in. Expansion waits until the scroll below has
                // brought the newest row on screen.
                bottomRowID = nil
                bottomSettledContextKey = nil
                scrollToBottom(on: proxy, privatePeer: privatePeer)
            }
            // The one change handler: a channel or DM switch changes the
            // signature too, so landing in the new timeline happens here,
            // ahead of that update's row callbacks.
            .onChange(of: TimelineSignature(privatePeer: privatePeer, contextKey: contextKey, messages: messages)) { signature in
                onTimelineChange(signature, proxy: proxy)
            }
            .confirmationDialog(
                selectedMessageSender.map { "@\($0)" } ?? String(localized: "content.actions.title", comment: "Fallback title for the message action sheet"),
                isPresented: $showMessageActions,
                titleVisibility: .visible
            ) {
                Button(String(localized: "content.actions.mention")) {
                    if let sender = selectedMessageSender {
                        insertMention(sender)
                    }
                }

                Button(String(localized: "content.actions.direct_message")) {
                    if let peerID = selectedMessageSenderID {
                        appEnvironmentModels?.privateConversationModel.openConversation(for: peerID)
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            showSidebar = true
                        }
                    }
                }

                Button(String(localized: "content.actions.hug")) {
                    if let sender = selectedMessageSender {
                        conversationUIModel.sendHug(to: sender)
                    }
                }

                Button(String(localized: "content.actions.slap")) {
                    if let sender = selectedMessageSender {
                        conversationUIModel.sendSlap(to: sender)
                    }
                }

                Button(String(localized: "content.actions.block"), role: .destructive) {
                    conversationUIModel.block(peerID: selectedMessageSenderID, displayName: selectedMessageSender)
                }

                Button(String(localized: "common.cancel"), role: .cancel) {}
            }
            .onAppear {
                // Also check when view appears
                if let peerID = privatePeer,
                   let privateConversationModel = appEnvironmentModels?.privateConversationModel {
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
                cancelFollowScroll()
            }
        }
        // Reset UIScrollView state when switching channels or DMs so a deep
        // scroll offset from a populated room never carries over into a
        // shorter or empty timeline on iOS.
        .id(contextKey)
        .environment(\.openURL, OpenURLAction { url in
            guard MessageListExternalURLPolicy.isAllowed(url) else {
                return .discarded
            }
            // Intercept custom cashu:/lightning: links created in attributed text
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

enum MessageListExternalURLPolicy {
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https"
            || scheme == "http"
            || scheme == "cashu"
            || scheme == "lightning"
            || scheme == "bitchat"
    }
}

private extension MessageListContentView {
    /// Returns the window to its initial size once the reader is back at the
    /// bottom (the newest row has appeared): whatever it grew by while they
    /// were scrolled up, or expanded into history, need not stay rendered,
    /// and dropping rows above the bottom moves nothing on screen. Never in
    /// the same update as a scroll: rows changing above the viewport make
    /// SwiftUI hold its position, and a pending scrollTo never lands.
    func returnWindowToInitialSize(for privatePeer: PeerID?, contextKey: String, messages: [BitchatMessage]) {
        let initialCount = privatePeer == nil
            ? TransportConfig.uiWindowInitialCountPublic
            : TransportConfig.uiWindowInitialCountPrivate
        guard liveWindowCount(privatePeer) > initialCount else { return }
        setWindowCount(initialCount, privatePeer)
        timelineMark = contextMark(for: contextKey)?.withWindowCount(initialCount, in: messages)
    }

    /// The timeline mark, if it was taken in `contextKey`.
    func contextMark(for contextKey: String) -> MessageListScrollPolicy.TimelineMark? {
        guard let timelineMark, timelineMark.contextKey == contextKey else { return nil }
        return timelineMark
    }

    /// Whether a row belongs to the timeline the list has landed in (the
    /// mark's context: the change handler lands a switch before the rows of
    /// that update report in).
    func isLandedRow(_ rowID: String) -> Bool {
        guard let landedContextKey = timelineMark?.contextKey else { return false }
        return MessageListScrollPolicy.isRow(rowID, inContext: landedContextKey)
    }

    /// True when the mesh timeline holds nothing but archived echoes and
    /// system lines — no live conversation yet, so the ambient layer still
    /// applies.
    func showsAmbientFooter(messageItems: [MessageDisplayItem]) -> Bool {
        guard case .mesh = selectedPublicChannel,
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
            switch selectedPublicChannel {
            case .mesh, .none:
                MeshEmptyStateView(
                    fillHeight: max(0, fillHeight - 24),
                    bluetoothAvailable: bluetoothCanScan
                )
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

    /// Floating pill shown while scrolled up: re-presents the isAtBottom /
    /// unseenCount state the view already tracks, and jumps to the newest
    /// message via the existing scrollToBottom helper.
    func jumpToLatestPill(proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(on: proxy, privatePeer: privatePeer)
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

    /// Appends an @mention to the composer draft (never overwrites what the
    /// user has already typed) and focuses the input field.
    func insertMention(_ sender: String) {
        appEnvironmentModels?.composerDraftModel.insertMention(sender)
        isTextFieldFocused.wrappedValue = true
    }

    func expandWindow(ifNeededFor message: BitchatMessage,
                      allMessages: [BitchatMessage],
                      privatePeer: PeerID?,
                      proxy: ScrollViewProxy) {
        let contextKey = liveContextKey(privatePeer)
        guard MessageListScrollPolicy.canExpandWindow(
            isRestoringExpansion: isRestoringExpansion,
            bottomSettledContextKey: bottomSettledContextKey,
            contextKey: contextKey
        ) else { return }

        let current = liveWindowCount(privatePeer)
        let newCount = min(allMessages.count, current + TransportConfig.uiWindowStepCount)
        guard newCount != current else { return }
        setWindowCount(newCount, privatePeer)
        // The window's first row moved up with it: re-take the mark's window
        // so a scrolled-up reader keeps holding the new first row.
        timelineMark = contextMark(for: contextKey)?.withWindowCount(newCount, in: allMessages)

        // Until the restore below lands, the rows just inserted above leave a
        // new first row on screen; it must not expand the window again.
        let preserveID = "\(contextKey)|\(message.id)"
        isRestoringExpansion = true
        DispatchQueue.main.async {
            proxy.scrollTo(preserveID, anchor: .top)
            isRestoringExpansion = false
        }
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme == "bitchat" else { return }
        guard appEnvironmentModels?.appChromeModel.panicWipeBlocked != true else { return }
        switch url.host {
        case "user":
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let peerID = PeerID(str: id.removingPercentEncoding ?? id)
            selectedMessageSenderID = peerID

            selectedMessageSender = conversationUIModel.senderDisplayName(
                for: peerID,
                fallbackMessages: liveMessages(privatePeer)
            )

            if conversationUIModel.isSelfSender(peerID: peerID, displayName: selectedMessageSender) {
                selectedMessageSender = nil
                selectedMessageSenderID = nil
            } else {
                showMessageActions = true
            }

        case "geohash":
            let gh = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            guard (2...12).contains(gh.count), gh.allSatisfy({ Self.allowedGeohashChars.contains($0) }) else { return }
            appEnvironmentModels?.locationChannelsModel.openLocationChannel(for: gh)

        default:
            return
        }
    }

    func scrollToBottom(on proxy: ScrollViewProxy, privatePeer: PeerID?) {
        // A follow-scroll still pending (possibly for a timeline being left)
        // has nothing left to do.
        cancelFollowScroll()
        isAtBottom = true
        unseenCount = 0
        timelineMark = MessageListScrollPolicy.TimelineMark(
            contextKey: liveContextKey(privatePeer),
            messages: liveMessages(privatePeer),
            windowCount: liveWindowCount(privatePeer)
        )
        if let target = newestRowID(for: privatePeer) {
            proxy.scrollTo(target, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Retry only a scroll that has not landed. Once the newest row is
            // on screen the retry would be a no-op, and a no-op scrollTo stays
            // queued until the next layout pass: the reader's next drag.
            if let secondTarget = self.newestRowID(for: privatePeer),
               MessageListScrollPolicy.needsScroll(toNewestRowID: secondTarget, bottomRowID: bottomRowID) {
                proxy.scrollTo(secondTarget, anchor: .bottom)
            }
        }
    }

    /// Lands the list at the newest message of a timeline it was not showing
    /// (a channel or DM switch): nothing about the old timeline's bottom
    /// carries over.
    func land(on proxy: ScrollViewProxy, privatePeer: PeerID?) {
        bottomRowID = nil
        bottomSettledContextKey = nil
        scrollToBottom(on: proxy, privatePeer: privatePeer)
    }

    /// Row ID of the newest message that has a row (whitespace-only
    /// messages render none).
    func newestRowID(for privatePeer: PeerID?) -> String? {
        guard let newest = liveMessages(privatePeer).last(where: { $0.content.hasNonWhitespaceContent }) else {
            return nil
        }
        return "\(liveContextKey(privatePeer))|\(newest.id)"
    }

    /// Handles any change to the shown timeline: an append, a late message
    /// inserted mid-timeline, an eviction at the cap, a removal, or a
    /// different timeline altogether (a channel or DM switch).
    func onTimelineChange(_ signature: TimelineSignature, proxy: ScrollViewProxy) {
        // The deprecated onChange runs the previous render's closure, so the
        // timeline comes from the new value rather than `self.privatePeer`.
        let privatePeer = signature.privatePeer
        let contextKey = signature.contextKey
        let messages = liveMessages(privatePeer)

        // No mark in this context means the timeline was swapped wholesale:
        // nothing is booked as "new", the list lands instead.
        let mark = contextMark(for: contextKey)
        let appended = mark.map { MessageListScrollPolicy.appended(since: $0, in: messages) }
            ?? MessageListScrollPolicy.Appended()
        let currentWindowCount = liveWindowCount(privatePeer)
        let reaction = MessageListScrollPolicy.reaction(
            mark: mark,
            messages: messages,
            newestIsOwn: messages.last.map { conversationUIModel.isSentByCurrentUser($0) } ?? false,
            appendedCount: appended.total,
            windowCount: currentWindowCount,
            isAtBottom: isAtBottom
        )

        if reaction == .land {
            land(on: proxy, privatePeer: privatePeer)
            return
        }

        // Record the window this render kept: for a scrolled-up reader,
        // widened over what landed below its first row instead of dropping
        // that row (grown by the appended count if the mark lost track of
        // it). A follow keeps it too: rows changing above the viewport in the
        // same update as the scroll make SwiftUI hold its position instead.
        let keptWindowCount = isAtBottom
            ? currentWindowCount
            : MessageListScrollPolicy.windowCountKeepingFirstRow(
                current: currentWindowCount,
                mark: mark,
                appendedCount: appended.total,
                in: messages
            )
        if keptWindowCount != currentWindowCount {
            setWindowCount(keptWindowCount, privatePeer)
        }
        timelineMark = MessageListScrollPolicy.TimelineMark(contextKey: contextKey, messages: messages, windowCount: keptWindowCount)

        switch reaction {
        case .keepPosition:
            unseenCount += appended.unseen
        case .follow:
            // Ensure we consider ourselves at bottom for subsequent messages
            isAtBottom = true
            unseenCount = 0
            followToBottom(privatePeer: privatePeer, proxy: proxy)
        case .hold:
            if messages.isEmpty {
                // Timeline emptied (e.g. /clear): nothing below to jump to.
                unseenCount = 0
            }
        case .land:
            break
        }
    }

    /// Scrolls to the newest row, at most once per throttle interval. A
    /// throttled scroll decides when its timer fires: the timer is held back
    /// while a drag is tracking, so by then the reader may have scrolled
    /// away or switched timelines, and newer rows may have landed.
    func followToBottom(privatePeer: PeerID?, proxy: ScrollViewProxy) {
        let now = Date()
        if now.timeIntervalSince(lastScrollTime) > TransportConfig.uiScrollThrottleSeconds {
            // Immediate scroll if enough time has passed
            scrollToNewestRow(privatePeer: privatePeer, proxy: proxy, at: now)
            return
        }
        // Schedule a delayed scroll
        let scheduledContextKey = liveContextKey(privatePeer)
        scrollThrottleTimer?.invalidate()
        scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: TransportConfig.uiScrollThrottleSeconds, repeats: false) { _ in
            Task { @MainActor in
                guard MessageListScrollPolicy.shouldRunDeferredFollowScroll(
                    isAtBottom: isAtBottom,
                    scheduledContextKey: scheduledContextKey,
                    currentContextKey: liveContextKey(privatePeer)
                ) else { return }
                scrollToNewestRow(privatePeer: privatePeer, proxy: proxy, at: Date())
            }
        }
    }

    func scrollToNewestRow(privatePeer: PeerID?, proxy: ScrollViewProxy, at date: Date) {
        lastScrollTime = date
        if let target = newestRowID(for: privatePeer) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    /// Drops a follow-scroll still waiting on the throttle.
    func cancelFollowScroll() {
        guard let timer = scrollThrottleTimer else { return }
        timer.invalidate()
        scrollThrottleTimer = nil
    }
}

private struct MessageRowView: View, Equatable {
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @Environment(\.appEnvironmentModels) private var appEnvironmentModels
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    let message: BitchatMessage
    private let messageIdentity: ObjectIdentifier
    let deliveryStatus: DeliveryStatus
    let privatePeer: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var showSidebar: Bool
    let onInsertMention: (String) -> Void

    init(
        message: BitchatMessage,
        deliveryStatus: DeliveryStatus,
        privatePeer: PeerID?,
        imagePreviewURL: Binding<URL?>,
        showSidebar: Binding<Bool>,
        onInsertMention: @escaping (String) -> Void
    ) {
        self.message = message
        self.messageIdentity = ObjectIdentifier(message)
        self.deliveryStatus = deliveryStatus
        self.privatePeer = privatePeer
        self._imagePreviewURL = imagePreviewURL
        self._showSidebar = showSidebar
        self.onInsertMention = onInsertMention
    }

    nonisolated static func == (lhs: MessageRowView, rhs: MessageRowView) -> Bool {
        lhs.messageIdentity == rhs.messageIdentity
            && lhs.deliveryStatus == rhs.deliveryStatus
            && lhs.privatePeer == rhs.privatePeer
    }

    var body: some View {
        rowContent
            // Archived echoes ("heard here earlier") render dimmed: real
            // history, visually distinct from the live conversation.
            .opacity(message.isArchivedEcho ? 0.55 : 1)
            .contentShape(Rectangle())
            .contextMenu {
                let showsUserActions = message.sender != "system" && !conversationUIModel.isSentByCurrentUser(message)
                if showsUserActions {
                    // Mention and DM are redundant inside a 1:1 conversation:
                    // mentioning the only other participant is noise, and "DM"
                    // would just reopen the conversation that is already open.
                    if privatePeer == nil {
                        Button(String(localized: "content.actions.mention")) {
                            onInsertMention(message.sender)
                        }
                        if let peerID = message.senderPeerID {
                            Button(String(localized: "content.actions.direct_message")) {
                                appEnvironmentModels?.privateConversationModel.openConversation(for: peerID)
                                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                                    showSidebar = true
                                }
                            }
                        }
                    }
                    Button(String(localized: "content.actions.hug")) {
                        conversationUIModel.sendHug(to: message.sender)
                    }
                    Button(String(localized: "content.actions.slap")) {
                        conversationUIModel.sendSlap(to: message.sender)
                    }
                }
                Button(String(localized: "content.message.copy")) {
                    ClipboardHelper.copy(message.content)
                }
                if isResendableFailedMessage(message) {
                    Button(String(localized: "content.actions.resend")) {
                        conversationUIModel.resendFailedPrivateMessage(message)
                    }
                }
                if showsUserActions {
                    Button(String(localized: "content.actions.block"), role: .destructive) {
                        conversationUIModel.block(peerID: message.senderPeerID, displayName: message.sender)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
            // Archived echoes read as one tinted block, not just faded rows.
            .background(message.isArchivedEcho ? palette.secondary.opacity(0.08) : Color.clear)
    }

    @ViewBuilder
    private var rowContent: some View {
        if message.sender == "system" {
            Text(conversationUIModel.formatMessage(message, colorScheme: colorScheme, theme: theme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let media = conversationUIModel.mediaAttachment(for: message) {
            MediaMessageView(message: message, media: media, imagePreviewURL: $imagePreviewURL)
        } else {
            TextMessageView(message: message)
                .equatable()
        }
    }

    /// A failed private text message of our own can be resent through the
    /// normal send path (the context menu removes the failed original and
    /// re-submits its content).
    private func isResendableFailedMessage(_ message: BitchatMessage) -> Bool {
        guard message.isPrivate,
              conversationUIModel.isSentByCurrentUser(message),
              conversationUIModel.mediaAttachment(for: message) == nil,
              case .failed = deliveryStatus
        else { return false }
        return true
    }
}

private struct ScrollChromeInsetsModifier: ViewModifier {
    let top: CGFloat
    let bottom: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content
                .contentMargins(.top, top, for: .scrollContent)
                .contentMargins(.bottom, bottom, for: .scrollContent)
                .contentMargins(.top, top, for: .scrollIndicators)
                .contentMargins(.bottom, bottom, for: .scrollIndicators)
        } else {
            content
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
