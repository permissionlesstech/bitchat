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
    @EnvironmentObject private var conversationUIModel: ConversationUIModel

    let message: BitchatMessage
    /// Value snapshot of the message's mutable delivery status, captured at
    /// construction. `BitchatMessage` is a reference type mutated in place by
    /// `ConversationStore`, and SwiftUI compares reference-typed view fields
    /// by identity — so a status-only change (e.g. delivered → read) on the
    /// SAME instance would otherwise compare "unchanged" and this row's body
    /// would be skipped even though the parent list re-rendered. Snapshotting
    /// the enum makes the change visible to SwiftUI's structural diff.
    private let deliveryStatus: DeliveryStatus?
    @State private var expandedMessageIDs: Set<String> = []
    @State private var showDeliveryDetail = false

    init(message: BitchatMessage) {
        self.message = message
        self.deliveryStatus = message.deliveryStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Precompute heavy token scans once per row
            let cashuLinks = message.content.extractCashuLinks()
            let lightningLinks = message.content.extractLightningLinks()
            // Baseline alignment keeps the lock and delivery glyphs on the
            // first text line; a fixed top padding left the lock's solid body
            // hanging below the line's visual center.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                let isLong = (message.content.count > TransportConfig.uiLongMessageLengthThreshold || message.content.hasVeryLongToken(threshold: TransportConfig.uiVeryLongTokenThreshold)) && cashuLinks.isEmpty
                let isExpanded = expandedMessageIDs.contains(message.id)
                if message.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.bitchatSystem(size: 8))
                        .foregroundColor(Color.orange.opacity(0.75))
                        .padding(.trailing, 4)
                        .accessibilityHidden(true)
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
                    .lineLimit(isLong && !isExpanded ? TransportConfig.uiLongMessageLineLimit : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // Delivery status indicator for private messages. Tappable:
                // .help() tooltips only exist on macOS, so iOS users get the
                // explanation as a caption under the row instead.
                if message.isPrivate && conversationUIModel.isSentByCurrentUser(message),
                   let status = deliveryStatus {
                    Button {
                        showDeliveryDetail.toggle()
                    } label: {
                        DeliveryStatusView(status: status)
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
               let status = deliveryStatus {
                if case .failed = status {
                    Text(verbatim: status.bitchatDescription)
                        .bitchatFont(size: 11)
                        .foregroundColor(Color.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                } else if showDeliveryDetail {
                    Text(verbatim: status.bitchatDescription)
                        .bitchatFont(size: 11)
                        .foregroundColor(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            
            // Expand/Collapse for very long messages
            if (message.content.count > TransportConfig.uiLongMessageLengthThreshold || message.content.hasVeryLongToken(threshold: TransportConfig.uiVeryLongTokenThreshold)) && cashuLinks.isEmpty {
                let isExpanded = expandedMessageIDs.contains(message.id)
                let labelKey = isExpanded ? LocalizedStringKey("content.message.show_less") : LocalizedStringKey("content.message.show_more")
                Button(labelKey) {
                    if isExpanded { expandedMessageIDs.remove(message.id) }
                    else { expandedMessageIDs.insert(message.id) }
                }
                .bitchatFont(size: 11, weight: .medium)
                .foregroundColor(palette.accentBlue)
                .padding(.top, 4)
            }

            // Render payment chips (Lightning / Cashu) with rounded background
            if !lightningLinks.isEmpty || !cashuLinks.isEmpty {
                HStack(spacing: 8) {
                    ForEach(lightningLinks, id: \.self) { link in
                        PaymentChipView(paymentType: .lightning(link))
                    }
                    ForEach(cashuLinks, id: \.self) { link in
                        PaymentChipView(paymentType: .cashu(link))
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 2)
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
