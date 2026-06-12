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

    init(message: BitchatMessage) {
        self.message = message
        self.deliveryStatus = message.deliveryStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Precompute heavy token scans once per row
            let cashuLinks = message.content.extractCashuLinks()
            let lightningLinks = message.content.extractLightningLinks()
            HStack(alignment: .top, spacing: 0) {
                let isLong = (message.content.count > TransportConfig.uiLongMessageLengthThreshold || message.content.hasVeryLongToken(threshold: TransportConfig.uiVeryLongTokenThreshold)) && cashuLinks.isEmpty
                let isExpanded = expandedMessageIDs.contains(message.id)
                Text(conversationUIModel.formatMessage(message, colorScheme: colorScheme, theme: theme))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(isLong && !isExpanded ? TransportConfig.uiLongMessageLineLimit : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // Delivery status indicator for private messages
                if message.isPrivate && conversationUIModel.isSentByCurrentUser(message),
                   let status = deliveryStatus {
                    DeliveryStatusView(status: status)
                        .padding(.leading, 4)
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
                .foregroundColor(Color.blue)
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
