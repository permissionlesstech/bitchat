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

/// The one timeline model a message list observes: a public channel's
/// model, or the private inbox for a DM list.
@MainActor
private protocol MessageListTimelineModel: ObservableObject {
    /// The public channel the timeline belongs to, published together with
    /// its messages; nil for private timelines.
    var listChannel: ChannelID? { get }
    /// The rows to show (`privatePeer` names the private conversation).
    func listMessages(for privatePeer: PeerID?) -> [BitchatMessage]
}

extension PublicChatModel: MessageListTimelineModel {
    fileprivate var listChannel: ChannelID? { channel }

    fileprivate func listMessages(for _: PeerID?) -> [BitchatMessage] {
        messages
    }
}

extension PrivateInboxModel: MessageListTimelineModel {
    fileprivate var listChannel: ChannelID? { nil }

    fileprivate func listMessages(for privatePeer: PeerID?) -> [BitchatMessage] {
        messages(for: privatePeer)
    }
}

/// A conversation's message list. Each list observes exactly one timeline
/// model, the one it renders: a public list its `PublicChatModel` (the split
/// layout's #mesh pane is handed the pinned one), a DM list the private
/// inbox. So a message in another timeline (the open DM beside the #mesh
/// pane, a public channel under a DM) never re-renders the list.
///
/// Its actions act in its own conversation and type into its own composer
/// (`MessageListActions`), never the selection's.
struct MessageListView: View {
    /// The DM this list shows, as the target its actions act in (its owner
    /// knows the DM's scope); nil for a public list, which shows the
    /// timeline of the `PublicChatModel` it is handed and acts in that
    /// model's channel.
    let privateTarget: ConversationTarget?
    @Binding var isAtBottom: Bool
    /// The composer under this list, which a mention types into; held, not
    /// observed, so typing never re-renders the list. Nil while that
    /// composer isn't on screen: the list then offers no mention.
    let composer: ComposerSession?
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var showSidebar: Bool

    /// The composer with the keyboard; a mention hands it to `composer`.
    var focusedComposer: FocusState<ComposerSlot?>.Binding

    private var privatePeer: PeerID? {
        privateTarget?.privatePeer
    }

    var body: some View {
        if privatePeer == nil {
            content(observing: PublicChatModel.self)
        } else {
            content(observing: PrivateInboxModel.self)
        }
    }

    private func content<Timeline: MessageListTimelineModel>(
        observing _: Timeline.Type
    ) -> MessageListContent<Timeline> {
        MessageListContent(
            privatePeer: privatePeer,
            privateTarget: privateTarget,
            isAtBottom: $isAtBottom,
            composer: composer,
            selectedMessageSender: $selectedMessageSender,
            selectedMessageSenderID: $selectedMessageSenderID,
            imagePreviewURL: $imagePreviewURL,
            windowCountPublic: $windowCountPublic,
            windowCountPrivate: $windowCountPrivate,
            showSidebar: $showSidebar,
            focusedComposer: focusedComposer
        )
    }
}

/// `MessageListView` over its one timeline model.
private struct MessageListContent<Timeline: MessageListTimelineModel>: View {
    /// The timeline this list renders, and the only one it observes.
    @EnvironmentObject private var timeline: Timeline
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @ObservedObject private var nearbyNotes = NearbyNotesCounter.shared

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var theme

    let privatePeer: PeerID?
    let privateTarget: ConversationTarget?
    @Binding var isAtBottom: Bool
    let composer: ComposerSession?
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var showSidebar: Bool

    var focusedComposer: FocusState<ComposerSlot?>.Binding

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
    /// Whether this instance holds the nearby-notes counter active (mesh
    /// public timeline only); balanced against activate/deactivate.
    @State private var holdsNotesCounter = false

    @ThemedPalette private var palette

    var body: some View {
        let currentWindowCount = windowCount(for: privatePeer)

        let messages = conversationMessages(for: privatePeer)
        let contextKey = timelineContextKey(for: privatePeer)
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
        let windowedMessages = Array(messages.suffix(renderedWindowCount))

        let messageItems: [MessageDisplayItem] = windowedMessages.compactMap { message in
            guard !message.content.trimmed.isEmpty else { return nil }
            return MessageDisplayItem(id: "\(contextKey)|\(message.id)", message: message)
        }
        // Top edge of the rendered window (whitespace-only messages get no
        // row, so they could never report reaching it).
        let firstRowID = messageItems.first?.id

        VStack(spacing: 0) {
        // Notes pinned to this place stay visible while chatting — a
        // conversation starting must not hide what's left here. Keyed on the
        // timeline this list shows, not the selection: the split layout's
        // #mesh list renders beside a selected geohash.
        if channelPolicy.showsNotesStrip(noteCount: nearbyNotes.noteCount) {
            notesHereStrip
        }
        GeometryReader { geometry in
        ScrollViewReader { proxy in
            ScrollView {
                if messageItems.isEmpty, let emptyState = channelPolicy.emptyState {
                    publicEmptyState(emptyState, fillHeight: geometry.size.height)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(messageItems) { item in
                        let message = item.message
                        messageRow(for: message)
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
                                if item.id == firstRowID,
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
                            .contentShape(Rectangle())
                            .contextMenu {
                                let showsUserActions = message.sender != "system" && !conversationUIModel.isSentByCurrentUser(message)
                                if showsUserActions {
                                    // Mention and DM are redundant inside a 1:1 conversation:
                                    // mentioning the only other participant is noise, and "DM"
                                    // would just reopen the conversation that is already open.
                                    if privatePeer == nil {
                                        if let actions, actions.canMention {
                                            Button("content.actions.mention") {
                                                actions.mention(message.sender)
                                            }
                                        }
                                        if let peerID = message.senderPeerID {
                                            Button("content.actions.direct_message") {
                                                openConversation(with: peerID)
                                                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                                                    showSidebar = true
                                                }
                                            }
                                        }
                                    }
                                    if let actions {
                                        Button("content.actions.hug") {
                                            actions.hug(message.sender)
                                        }
                                        Button("content.actions.slap") {
                                            actions.slap(message.sender)
                                        }
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
                                if let actions, isResendableFailedMessage(message) {
                                    Button("content.actions.resend") {
                                        actions.resend(message)
                                    }
                                }
                                if let actions, showsUserActions {
                                    Button("content.actions.block", role: .destructive) {
                                        actions.block(peerID: message.senderPeerID, displayName: message.sender)
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
                .padding(.vertical, 2)

                // Only carried history on screen: the ambient layer (radar,
                // sightings, live hints) stays visible below it instead of
                // vanishing the moment echoes exist.
                if channelPolicy.showsAmbientFooter(below: messageItems.lazy.map(\.message)) {
                    MeshEmptyStateView(compact: true, bluetoothAvailable: bluetoothCanScan)
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
            // No onOpenURL: every mounted list would receive each external
            // link (two lists in the split layout, or a DM over the public
            // timeline). AppRuntime opens external #geohash links once; the
            // links a list draws act through the openURL action below.
            .onTapGesture(count: 3) {
                if actions != nil {
                    showClearConfirmation = true
                }
            }
            .confirmationDialog(
                "content.clear.confirm_title",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("content.clear.confirm_action", role: .destructive) {
                    actions?.clear()
                }
                Button("common.cancel", role: .cancel) {}
            }
            .onAppear {
                // Runs before the rows' onAppear: lands the list (and sets the
                // mark the row callbacks are checked against) before any row
                // reports in. Expansion waits until the scroll below has
                // brought the newest row on screen.
                bottomSettledContextKey = nil
                scrollToBottom(on: proxy, privatePeer: privatePeer)
            }
            // The one change handler: a channel or DM switch changes the
            // signature too, so landing in the new timeline happens here,
            // ahead of that update's row callbacks.
            .onChange(of: TimelineSignature(privatePeer: privatePeer, contextKey: contextKey, messages: messages)) { signature in
                onTimelineChange(signature, proxy: proxy)
            }
            .onChange(of: geometry.size.width) { _ in
                // Rows reflow at a new width (fold, unfold, the people column
                // appearing), so the same offset lands in older history.
                guard isAtBottom else { return }
                DispatchQueue.main.async {
                    scrollToBottom(on: proxy, privatePeer: privatePeer)
                }
            }
            .confirmationDialog(
                selectedMessageSender.map { "@\($0)" } ?? String(localized: "content.actions.title", comment: "Fallback title for the message action sheet"),
                isPresented: $showMessageActions,
                titleVisibility: .visible
            ) {
                if let actions, actions.canMention {
                    Button("content.actions.mention") {
                        if let sender = selectedMessageSender {
                            actions.mention(sender)
                        }
                    }
                }

                Button("content.actions.direct_message") {
                    if let peerID = selectedMessageSenderID {
                        openConversation(with: peerID)
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            showSidebar = true
                        }
                    }
                }

                if let actions {
                    Button("content.actions.hug") {
                        if let sender = selectedMessageSender {
                            actions.hug(sender)
                        }
                    }

                    Button("content.actions.slap") {
                        if let sender = selectedMessageSender {
                            actions.slap(sender)
                        }
                    }

                    Button("content.actions.block", role: .destructive) {
                        actions.block(peerID: selectedMessageSenderID, displayName: selectedMessageSender)
                    }
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
                cancelFollowScroll()
            }
        }
        }
        }
        .onAppear { updateNotesCounterHold() }
        .onDisappear { releaseNotesCounterHold() }
        .onChange(of: timeline.listChannel) { _ in updateNotesCounterHold() }
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
            // Sender and #geohash links drawn by this list act here, in this
            // list only, rather than leaving the app and coming back as
            // external links.
            if url.scheme == "bitchat", url.host == "user" || url.host == "geohash" {
                handleOpenURL(url)
                return .handled
            }
            return .systemAction
        })
    }
}

private extension MessageListContent {
    /// Whether the radio could be scanning at all — the empty-state radar
    /// must not sweep over a switched-off or denied radio.
    var bluetoothCanScan: Bool {
        switch appChromeModel.bluetoothState {
        case .poweredOff, .unauthorized, .unsupported: return false
        default: return true
        }
    }

    /// Context key of the timeline shown for `privatePeer` (the DM, or the
    /// public channel); also the prefix of its row IDs. The public key comes
    /// from the channel this list's timeline model publishes together with
    /// its messages, never from the selection: the selected channel switches
    /// one render or more before the timeline does (keying the old messages
    /// with the new channel re-keys, and re-appears, every row), and the split
    /// layout's #mesh list renders beside a selected geohash.
    func timelineContextKey(for privatePeer: PeerID?) -> String {
        if let peer = privatePeer {
            return "dm:\(peer)"
        }
        // A private timeline without a peer has no rows to key.
        return timeline.listChannel?.contextKey ?? "dm:"
    }

    /// The channel decisions of the timeline this list renders.
    var channelPolicy: MessageListChannelPolicy {
        MessageListChannelPolicy(channel: timeline.listChannel, privatePeer: privatePeer)
    }

    func windowCount(for privatePeer: PeerID?) -> Int {
        if let peer = privatePeer {
            return windowCountPrivate[peer] ?? TransportConfig.uiWindowInitialCountPrivate
        }
        return windowCountPublic
    }

    func setWindowCount(_ count: Int, for privatePeer: PeerID?) {
        if let peer = privatePeer {
            windowCountPrivate[peer] = count
        } else {
            windowCountPublic = count
        }
    }

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
        guard windowCount(for: privatePeer) > initialCount else { return }
        setWindowCount(initialCount, for: privatePeer)
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

    /// "Direct message": the sender's DM, opened from this list's own
    /// conversation, where a refusal (a blocked sender's DM doesn't open)
    /// lands, never the selection, which can be the other pane's.
    func openConversation(with peerID: PeerID) {
        guard let origin = actions?.target else { return }
        privateConversationModel.openConversation(for: peerID, from: origin)
    }

    /// The list's actions: in its own conversation (its DM, or its own
    /// timeline's channel) and into its own composer. Nil only for a list
    /// with neither, which offers none.
    var actions: MessageListActions? {
        guard let target = MessageListActions.target(
            privateTarget: privateTarget,
            timelineChannel: timeline.listChannel
        ) else { return nil }
        let focusedComposer = focusedComposer
        return MessageListActions(
            target: target,
            composer: composer,
            focusComposer: { focusedComposer.wrappedValue = $0 },
            performer: conversationUIModel
        )
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

    /// The nearby-notes counter is held whenever this list shows the mesh
    /// public timeline — the strip needs a live count before it can decide to
    /// exist. Holding is not subscribing: nothing hits the relays until an
    /// explicit act reveals the counter (tap-to-reveal). The counter is
    /// ref-counted, so two lists showing #mesh hold it twice.
    func updateNotesCounterHold() {
        let shouldHold = channelPolicy.holdsNotesCounter
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

    /// Terminal-styled narration for an empty public timeline: says which
    /// channel this is, that the app is waiting for peers, and where to go
    /// next. Rendered inside the ScrollView; disappears with the first row.
    /// The mesh case fills the visible chat height so its radar can center
    /// in the space below the text.
    func publicEmptyState(_ emptyState: MessageListChannelPolicy.EmptyState, fillHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch emptyState {
            case .mesh:
                MeshEmptyStateView(
                    fillHeight: max(0, fillHeight - 24),
                    bluetoothAvailable: bluetoothCanScan
                )
            case .location(let geohash):
                emptyStateLine(
                    String(
                        format: String(localized: "content.empty.location_intro", comment: "First line of an empty geohash timeline naming the channel"),
                        locale: .current,
                        geohash
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

    /// A failed private text message of our own can be resent through the
    /// normal send path (the context menu removes the failed original and
    /// re-submits its content).
    func isResendableFailedMessage(_ message: BitchatMessage) -> Bool {
        guard message.isPrivate,
              conversationUIModel.isSentByCurrentUser(message),
              conversationUIModel.mediaAttachment(for: message) == nil,
              case .failed = message.deliveryStatus
        else { return false }
        return true
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
        let contextKey = timelineContextKey(for: privatePeer)
        guard MessageListScrollPolicy.canExpandWindow(
            isRestoringExpansion: isRestoringExpansion,
            bottomSettledContextKey: bottomSettledContextKey,
            contextKey: contextKey
        ) else { return }

        let current = windowCount(for: privatePeer)
        let newCount = min(allMessages.count, current + TransportConfig.uiWindowStepCount)
        guard newCount != current else { return }
        setWindowCount(newCount, for: privatePeer)
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

    func scrollToBottom(on proxy: ScrollViewProxy, privatePeer: PeerID?) {
        // A follow-scroll still pending (possibly for a timeline being left)
        // has nothing left to do.
        cancelFollowScroll()
        isAtBottom = true
        unseenCount = 0
        timelineMark = MessageListScrollPolicy.TimelineMark(
            contextKey: timelineContextKey(for: privatePeer),
            messages: conversationMessages(for: privatePeer),
            windowCount: windowCount(for: privatePeer)
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
        guard let newest = conversationMessages(for: privatePeer).last(where: { !$0.content.trimmed.isEmpty }) else {
            return nil
        }
        return "\(timelineContextKey(for: privatePeer))|\(newest.id)"
    }

    /// Handles any change to the shown timeline: an append, a late message
    /// inserted mid-timeline, an eviction at the cap, a removal, or a
    /// different timeline altogether (a channel or DM switch).
    func onTimelineChange(_ signature: TimelineSignature, proxy: ScrollViewProxy) {
        // The deprecated onChange runs the previous render's closure, so the
        // timeline comes from the new value rather than `self.privatePeer`.
        let privatePeer = signature.privatePeer
        let contextKey = signature.contextKey
        let messages = conversationMessages(for: privatePeer)

        // No mark in this context means the timeline was swapped wholesale:
        // nothing is booked as "new", the list lands instead.
        let mark = contextMark(for: contextKey)
        let appended = mark.map { MessageListScrollPolicy.appended(since: $0, in: messages) }
            ?? MessageListScrollPolicy.Appended()
        let currentWindowCount = windowCount(for: privatePeer)
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
            setWindowCount(keptWindowCount, for: privatePeer)
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
        let scheduledContextKey = timelineContextKey(for: privatePeer)
        scrollThrottleTimer?.invalidate()
        scrollThrottleTimer = Timer.scheduledTimer(withTimeInterval: TransportConfig.uiScrollThrottleSeconds, repeats: false) { _ in
            Task { @MainActor in
                guard MessageListScrollPolicy.shouldRunDeferredFollowScroll(
                    isAtBottom: isAtBottom,
                    scheduledContextKey: scheduledContextKey,
                    currentContextKey: timelineContextKey(for: privatePeer)
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

    func conversationMessages(for privatePeer: PeerID?) -> [BitchatMessage] {
        timeline.listMessages(for: privatePeer)
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
