
//
//  MessagesView.swift
//  bitchat
//
//  Created by Gemini on 7/9/25.
//

import SwiftUI

struct MessagesView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme

    private var colorPalette: ColorPalette {
        ColorPalette.forColorScheme(colorScheme)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let messages: [BitchatMessage] = {
                        if let privatePeer = viewModel.selectedPrivateChatPeer {
                            return viewModel.getPrivateChatMessages(for: privatePeer)
                        } else if let currentChannel = viewModel.currentChannel {
                            return viewModel.getChannelMessages(currentChannel)
                        } else {
                            return viewModel.messages
                        }
                    }()

                    ForEach(messages, id: \.id) { message in
                        MessageView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(colorPalette.backgroundColor)
            .onChange(of: viewModel.messages.count) { _ in
                if viewModel.selectedPrivateChatPeer == nil && !viewModel.messages.isEmpty {
                    withAnimation {
                        proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.privateChats) { _ in
                if let peerID = viewModel.selectedPrivateChatPeer,
                   let messages = viewModel.privateChats[peerID],
                   !messages.isEmpty {
                    withAnimation {
                        proxy.scrollTo(messages.last?.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.selectedPrivateChatPeer) { newPeerID in
                // When switching to a private chat, send read receipts
                if let peerID = newPeerID {
                    // Small delay to ensure messages are loaded
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        viewModel.markPrivateMessagesAsRead(from: peerID)
                    }
                }
            }
            .onAppear {
                // Also check when view appears
                if let peerID = viewModel.selectedPrivateChatPeer {
                    // Try multiple times to ensure read receipts are sent
                    viewModel.markPrivateMessagesAsRead(from: peerID)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        viewModel.markPrivateMessagesAsRead(from: peerID)
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        viewModel.markPrivateMessagesAsRead(from: peerID)
                    }
                }
            }
        }
    }
}
