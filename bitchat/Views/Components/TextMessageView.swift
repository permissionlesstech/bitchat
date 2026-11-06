//
// TextMessageView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import BitFoundation

struct TextMessageView: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette
    @Environment(\.chatStyle) private var chatStyle
    @EnvironmentObject private var conversationUIModel: ConversationUIModel

    let message: BitchatMessage
    /// Whether this row starts its author's run of messages; the bubble
    /// layout names the sender only on the first bubble of a run.
    let startsRun: Bool
    /// Value snapshot of the message's mutable delivery status, captured at
    /// construction. `BitchatMessage` is a reference type mutated in place by
    /// `ConversationStore`, and SwiftUI compares reference-typed view fields
    /// by identity — so a status-only change (e.g. delivered → read) on the
    /// SAME instance would otherwise compare "unchanged" and this row's body
    /// would be skipped even though the parent list re-rendered. Snapshotting
    /// the enum makes the change visible to SwiftUI's structural diff.
    private let deliveryStatus: DeliveryStatus
    @State private var expandedMessageIDs: Set<String> = []
    @State private var showDeliveryDetail = false

    init(message: BitchatMessage, startsRun: Bool = true) {
        self.message = message
        self.startsRun = startsRun
        self.deliveryStatus = message.deliveryStatus
    }

    var body: some View {
        Group {
            if chatStyle.usesBubbles {
                bubbleBody
            } else {
                ircBody
            }
        }
        // Collapse the revealed caption when the status advances (e.g.
        // sending → sent → delivered) so a detail opened for one state
        // doesn't linger and silently morph into another. Guarded write:
        // under a message storm many rows change status within one frame,
        // and an unconditional state write per change trips SwiftUI's
        // "tried to update multiple times per frame" re-entrancy warning.
        .onChange(of: deliveryStatus) { _ in
            if showDeliveryDetail {
                showDeliveryDetail = false
            }
        }
    }

    private var ircBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Heavy token scans run once per message, not once per render
            let scan = message.contentScan
            // Baseline alignment keeps the lock and delivery glyphs on the
            // first text line; a fixed top padding left the lock's solid body
            // hanging below the line's visual center.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                let isExpanded = expandedMessageIDs.contains(message.id)
                if message.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.bitchatSystem(size: 8))
                        .foregroundColor(Color.orange.opacity(0.75))
                        .padding(.trailing, 4)
                        .accessibilityHidden(true)
                }
                if conversationUIModel.showsVerifiedSeal(for: message) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.bitchatSystem(size: 8))
                        .foregroundColor(Color.green.opacity(0.85))
                        .padding(.trailing, 4)
                        .accessibilityLabel(
                            String(localized: "content.accessibility.verified_sender", defaultValue: "Verified sender", comment: "Accessibility label for the seal next to a verified peer's name on a private message")
                        )
                }
                if message.isBridged {
                    Image(systemName: "network")
                        .font(.bitchatSystem(size: 8))
                        .foregroundColor(Color.cyan.opacity(0.75))
                        .padding(.trailing, 4)
                        .accessibilityLabel(
                            String(localized: "content.accessibility.bridged_message", defaultValue: "Arrived across a mesh bridge", comment: "Accessibility label for the glyph marking a message that arrived across a mesh bridge")
                        )
                }
                Text(conversationUIModel.formatMessage(message, colorScheme: colorScheme, theme: theme))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(scan.isLongForDisplay && !isExpanded ? TransportConfig.uiLongMessageLineLimit : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // Delivery status indicator for private messages. Tappable:
                // .help() tooltips only exist on macOS, so iOS users get the
                // explanation as a caption under the row instead.
                if message.isPrivate && conversationUIModel.isSentByCurrentUser(message),
                   deliveryStatus != .notSentYet {
                    Button {
                        showDeliveryDetail.toggle()
                    } label: {
                        DeliveryStatusView(status: deliveryStatus)
                            .padding(.leading, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(
                        String(localized: "content.accessibility.delivery_detail_hint", comment: "Accessibility hint for the delivery status glyph explaining a tap reveals details")
                    )
                }
            }

            // Failure reasons stay visible without a tap; other statuses
            // reveal on demand.
            if message.isPrivate && conversationUIModel.isSentByCurrentUser(message),
               deliveryStatus != .notSentYet {
                if case .failed = deliveryStatus {
                    Text(verbatim: deliveryStatus.bitchatDescription)
                        .bitchatFont(size: 11)
                        .foregroundColor(Color.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                } else if showDeliveryDetail {
                    Text(verbatim: deliveryStatus.bitchatDescription)
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            
            // Expand/Collapse for very long messages
            if scan.isLongForDisplay {
                expandToggle
                    .padding(.top, 4)
            }

            // Render payment chips (Lightning / Cashu) with rounded background
            if !scan.lightningLinks.isEmpty || !scan.cashuLinks.isEmpty {
                paymentChips(for: scan)
                    .padding(.top, 6)
                    .padding(.leading, 2)
            }
        }
    }

    /// Messenger layout: the content in a bubble washed with the author's
    /// color, the sender named on the first bubble of their run (never on my
    /// own), and the time plus delivery status in the bottom-trailing corner.
    private var bubbleBody: some View {
        let scan = message.contentScan
        let isOwn = conversationUIModel.isSentByCurrentUser(message)
        let isCollapsed = scan.isLongForDisplay && !expandedMessageIDs.contains(message.id)
        let status: DeliveryStatus? = message.isPrivate && isOwn && deliveryStatus != .notSentYet ? deliveryStatus : nil
        let time = MessageBubbleMetrics.timestamp(for: message.timestamp)
        // Only the inline cluster sits beside a placeholder that reads the
        // time; the one under a collapsed message must read it itself.
        func meta(timeIsSpokenByBody: Bool) -> MessageBubbleMeta {
            MessageBubbleMeta(time: time, isBridged: message.isBridged, status: status, timeIsSpokenByBody: timeIsSpokenByBody) {
                showDeliveryDetail.toggle()
            }
        }

        return VStack(alignment: isOwn ? .trailing : .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 2) {
                if startsRun && !isOwn {
                    bubbleSenderLine
                }

                let bodyText = Text(conversationUIModel.formatBubbleBody(message, colorScheme: colorScheme, theme: theme))
                // A collapsed long message hangs its meta off the toggle row
                // instead: the truncated last line has no room to reserve.
                (isCollapsed
                    ? bodyText
                    : bodyText + MessageBubbleMeta.placeholder(time: time, isBridged: message.isBridged, status: status, design: theme.bodyFontDesign))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(isCollapsed ? TransportConfig.uiLongMessageLineLimit : nil)
                    .overlay(alignment: Alignment(horizontal: .trailing, vertical: .lastTextBaseline)) {
                        if !isCollapsed {
                            meta(timeIsSpokenByBody: true)
                        }
                    }

                if scan.isLongForDisplay {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        expandToggle
                        if isCollapsed {
                            meta(timeIsSpokenByBody: false)
                        }
                    }
                    .padding(.top, 2)
                }

                if !scan.lightningLinks.isEmpty || !scan.cashuLinks.isEmpty {
                    paymentChips(for: scan)
                        .padding(.top, 4)
                }
            }
            .messageBubbleChrome(tint: conversationUIModel.bubbleTint(for: message, colorScheme: colorScheme), isOwn: isOwn)

            if let status {
                MessageBubbleDeliveryCaption(status: status, showsDetail: showDeliveryDetail)
            }
        }
    }

    private var bubbleSenderLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(conversationUIModel.formatBubbleSender(message, colorScheme: colorScheme, theme: theme))
                .lineLimit(1)
            if conversationUIModel.showsVerifiedSeal(for: message) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.bitchatSystem(size: 9))
                    .foregroundColor(Color.green.opacity(0.85))
                    .accessibilityLabel(
                        String(localized: "content.accessibility.verified_sender", defaultValue: "Verified sender", comment: "Accessibility label for the seal next to a verified peer's name on a private message")
                    )
            }
        }
    }

    private var expandToggle: some View {
        let isExpanded = expandedMessageIDs.contains(message.id)
        let labelKey = isExpanded ? LocalizedStringKey("content.message.show_less") : LocalizedStringKey("content.message.show_more")
        return Button(labelKey) {
            if isExpanded { expandedMessageIDs.remove(message.id) }
            else { expandedMessageIDs.insert(message.id) }
        }
        .bitchatFont(size: 11, weight: .medium)
        .foregroundColor(palette.accentBlue)
    }

    private func paymentChips(for scan: BitchatMessage.ContentScan) -> some View {
        HStack(spacing: 8) {
            ForEach(scan.lightningLinks, id: \.self) { link in
                PaymentChipView(paymentType: .lightning(link))
            }
            ForEach(scan.cashuLinks, id: \.self) { link in
                PaymentChipView(paymentType: .cashu(link))
            }
        }
    }
}

// Wrapped in #if DEBUG because the preview depends on _PreviewHelpers
// (PreviewKeychainManager, BitchatMessage.preview), a development asset
// excluded from archive builds.
#if DEBUG
#Preview {
    let keychain = PreviewKeychainManager()
    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: NostrIdentityBridge(),
        identityManager: SecureIdentityStateManager(keychain)
    )
    let privateConversationModel = PrivateConversationModel(
        chatViewModel: viewModel,
        conversations: viewModel.conversations
    )
    let conversationUIModel = ConversationUIModel(
        chatViewModel: viewModel,
        privateConversationModel: privateConversationModel,
        conversations: viewModel.conversations
    )
    
    Group {
        List {
            TextMessageView(message: .preview)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(EmptyView())
        }
        .environment(\.colorScheme, .light)
        
        List {
            TextMessageView(message: .preview)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(EmptyView())
        }
        .environment(\.colorScheme, .dark)
    }
    .environmentObject(conversationUIModel)
}
#endif
