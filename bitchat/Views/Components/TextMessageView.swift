//
// TextMessageView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct TextMessageView: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @EnvironmentObject private var viewModel: ChatViewModel
    
    let message: BitchatMessage
    @Binding var expandedMessageIDs: Set<String>
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Precompute heavy token scans once per row
            let cashuLinks = message.content.extractCashuLinks()
            let lightningLinks = message.content.extractLightningLinks()
            HStack(alignment: .top, spacing: 0) {
                let isLong = (message.content.count > TransportConfig.uiLongMessageLengthThreshold || message.content.hasVeryLongToken(threshold: TransportConfig.uiVeryLongTokenThreshold)) && cashuLinks.isEmpty
                let isExpanded = expandedMessageIDs.contains(message.id)
                Text(viewModel.formatMessageAsText(message, colorScheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(isLong && !isExpanded ? TransportConfig.uiLongMessageLineLimit : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // Delivery status indicator for private messages
                if message.isPrivate && message.sender == viewModel.nickname,
                   let status = message.deliveryStatus {
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
                .font(.bitchatSystem(size: 11, weight: .medium, design: .monospaced))
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

@available(macOS 14, iOS 17, *)
#Preview {
    @Previewable @State var ids: Set<String> = []
    let keychain = PreviewKeychainManager()
    
    Group {
        List {
            TextMessageView(message: .preview, expandedMessageIDs: $ids)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(EmptyView())
        }
        .environment(\.colorScheme, .light)
        
        List {
            TextMessageView(message: .preview, expandedMessageIDs: $ids)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(EmptyView())
        }
        .environment(\.colorScheme, .dark)
    }
    .environmentObject(
        ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(),
            identityManager: SecureIdentityStateManager(keychain)
        )
    )
}
