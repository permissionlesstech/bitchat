//
// TextMessageView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import BitFoundation

struct TextMessageView: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette
    @EnvironmentObject private var conversationUIModel: ConversationUIModel

    let message: BitchatMessage
    private let messageIdentity: ObjectIdentifier
    /// Value snapshot of the message's mutable delivery status, captured at
    /// construction. `BitchatMessage` is a reference type mutated in place by
    /// `ConversationStore`, and SwiftUI compares reference-typed view fields
    /// by identity — so a status-only change (e.g. delivered → read) on the
    /// SAME instance would otherwise compare "unchanged" and this row's body
    /// would be skipped even though the parent list re-rendered. Snapshotting
    /// the enum makes the change visible to SwiftUI's structural diff.
    private let deliveryStatus: DeliveryStatus
    private let reactions: [AggregatedReaction]
    private let isHighlighted: Bool
    private let onToggleReaction: ((String) -> Void)?
    private let onTapQuote: ((String, String) -> Void)?
    @State private var expandedMessageIDs: Set<String> = []
    @State private var showDeliveryDetail = false

    init(
        message: BitchatMessage,
        reactions: [AggregatedReaction] = [],
        isHighlighted: Bool = false,
        onToggleReaction: ((String) -> Void)? = nil,
        onTapQuote: ((String, String) -> Void)? = nil
    ) {
        self.message = message
        self.messageIdentity = ObjectIdentifier(message)
        self.deliveryStatus = message.deliveryStatus
        self.reactions = reactions
        self.isHighlighted = isHighlighted
        self.onToggleReaction = onToggleReaction
        self.onTapQuote = onTapQuote
    }

    nonisolated static func == (lhs: TextMessageView, rhs: TextMessageView) -> Bool {
        lhs.messageIdentity == rhs.messageIdentity
            && lhs.deliveryStatus == rhs.deliveryStatus
            && lhs.reactions == rhs.reactions
            && lhs.isHighlighted == rhs.isHighlighted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Heavy token scans run once per message, not once per render
            let scan = message.contentScan
            let parsedReply = MessageInteractionCodec.parseReply(from: message.content)
            let showsDeliveryStatus = message.isPrivate
                && conversationUIModel.isSentByCurrentUser(message)
                && deliveryStatus != .notSentYet

            if let parsedReply {
                let quoteTint = conversationUIModel.colorForSenderName(
                    parsedReply.quotedSender,
                    isDark: colorScheme == .dark
                )
                Button {
                    onTapQuote?(parsedReply.quotedSender, parsedReply.quotedSnippet)
                } label: {
                    HStack(spacing: 6) {
                        Capsule()
                            .fill(quoteTint.opacity(0.85))
                            .frame(width: 2.5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: "@\(parsedReply.quotedSender)")
                                .bitchatFont(size: 11, weight: .semibold)
                                .foregroundColor(quoteTint)
                                .lineLimit(1)
                            Text(verbatim: parsedReply.quotedSnippet)
                                .bitchatFont(size: 11)
                                .foregroundColor(palette.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(quoteTint.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }
            // Baseline alignment keeps the lock and delivery glyphs on the
            // first text line; a fixed top padding left the lock's solid body
            // hanging below the line's visual center.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                let isExpanded = expandedMessageIDs.contains(message.id)
                MessageLeadingBadges(
                    isPrivate: message.isPrivate,
                    showsVerifiedSeal: conversationUIModel.showsVerifiedSeal(for: message),
                    isBridged: message.isBridged
                )
                Text(conversationUIModel.formatMessage(message, colorScheme: colorScheme, theme: theme))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(scan.isLongForDisplay && !isExpanded ? TransportConfig.uiLongMessageLineLimit : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if showsDeliveryStatus {
                    MessageDeliveryStatusButton(status: deliveryStatus, showDetail: $showDeliveryDetail)
                }
            }

            if showsDeliveryStatus {
                MessageDeliveryDetailCaption(status: deliveryStatus, showDetail: showDeliveryDetail)
                    .padding(.top, 2)
            }
            
            // Expand/Collapse for very long messages
            if scan.isLongForDisplay {
                let isExpanded = expandedMessageIDs.contains(message.id)
                let labelKey = isExpanded ? String(localized: "content.message.show_less") : String(localized: "content.message.show_more")
                Button(labelKey) {
                    if isExpanded { expandedMessageIDs.remove(message.id) }
                    else { expandedMessageIDs.insert(message.id) }
                }
                .bitchatFont(size: 11, weight: .medium)
                .foregroundColor(palette.accentBlue)
                .padding(.top, 4)
            }

            // Render payment chips (Lightning / Cashu) with rounded background
            if !scan.lightningLinks.isEmpty || !scan.cashuLinks.isEmpty {
                HStack(spacing: 8) {
                    ForEach(scan.lightningLinks, id: \.self) { link in
                        PaymentChipView(paymentType: .lightning(link))
                    }
                    ForEach(scan.cashuLinks, id: \.self) { link in
                        PaymentChipView(paymentType: .cashu(link))
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 2)
            }

            if !reactions.isEmpty {
                MessageReactionChipsView(
                    reactions: reactions,
                    onToggleReaction: onToggleReaction
                )
                .padding(.top, 4)
            }
        }
        .padding(.vertical, isHighlighted ? 4 : 0)
        .padding(.horizontal, isHighlighted ? 6 : 0)
        .background(
            isHighlighted
                ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.accent.opacity(0.16))
                : nil
        )
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
}

struct MessageReactionChipsView: View {
    @ThemedPalette private var palette
    let reactions: [AggregatedReaction]
    let onToggleReaction: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(reactions) { reaction in
                Button {
                    onToggleReaction?(reaction.emoji)
                } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: reaction.emoji)
                            .font(.system(size: 12))
                        if reaction.count > 1 {
                            Text(verbatim: "\(reaction.count)")
                                .bitchatFont(size: 11, weight: .semibold)
                                .foregroundColor(reaction.includesCurrentUser ? palette.accent : palette.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        reaction.includesCurrentUser
                            ? palette.accent.opacity(0.16)
                            : palette.secondary.opacity(0.10)
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                reaction.includesCurrentUser
                                    ? palette.accent.opacity(0.45)
                                    : palette.cardBorder,
                                lineWidth: 1
                            )
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
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
