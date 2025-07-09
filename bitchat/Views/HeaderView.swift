
//
//  HeaderView.swift
//  bitchat
//
//  Created by Gemini on 7/9/25.
//

import SwiftUI

struct HeaderView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var showSidebar: Bool
    @Binding var showAppInfo: Bool

    private var colorPalette: ColorPalette {
        ColorPalette.forColorScheme(colorScheme)
    }

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack {
            if let privatePeerID = viewModel.selectedPrivateChatPeer,
               let privatePeerNick = viewModel.meshService.getPeerNicknames()[privatePeerID] {
                privateChatHeader(privatePeerID: privatePeerID, privatePeerNick: privatePeerNick)
            } else if let currentChannel = viewModel.currentChannel {
                channelHeader(currentChannel: currentChannel)
            } else {
                publicChatHeader()
            }
        }
        .frame(height: 44) // Fixed height to prevent bouncing
        .padding(.horizontal, 12)
        .background(colorPalette.backgroundColor.opacity(0.95))
    }

    private func privateChatHeader(privatePeerID: String, privatePeerNick: String) -> some View {
        HStack {
            Button(action: {
                viewModel.endPrivateChat()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12))
                    Text("back")
                        .font(.system(size: 14, design: .monospaced))
                }
                .foregroundColor(colorPalette.textColor)
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Color.orange)
                Text("\(privatePeerNick)")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.orange)
            }
            .frame(maxWidth: .infinity)

            Spacer()

            // Favorite button
            Button(action: {
                viewModel.toggleFavorite(peerID: privatePeerID)
            }) {
                Image(systemName: viewModel.isFavorite(peerID: privatePeerID) ? "star.fill" : "star")
                    .font(.system(size: 16))
                    .foregroundColor(viewModel.isFavorite(peerID: privatePeerID) ? Color.yellow : colorPalette.textColor)
            }
            .buttonStyle(.plain)
        }
    }

    private func channelHeader(currentChannel: String) -> some View {
        HStack {
            Button(action: {
                viewModel.switchToChannel(nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12))
                    Text("back")
                        .font(.system(size: 14, design: .monospaced))
                }
                .foregroundColor(colorPalette.textColor)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showSidebar.toggle()
                    }
                }) {
                HStack(spacing: 6) {
                    if viewModel.passwordProtectedChannels.contains(currentChannel) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color.orange)
                    }
                    Text("channel: \(currentChannel)")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(viewModel.passwordProtectedChannels.contains(currentChannel) ? Color.orange : Color.blue)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Spacer()

            ChannelControlsView(channel: currentChannel)
        }
    }

    private func publicChatHeader() -> some View {
        HStack {
            HStack(spacing: 4) {
                Text("bitchat*")
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundColor(colorPalette.textColor)
                    .onTapGesture(count: 3) {
                        // PANIC: Triple-tap to clear all data
                        viewModel.panicClearAllData()
                    }
                    .onTapGesture(count: 1) {
                        // Single tap for app info
                        showAppInfo = true
                    }

                HStack(spacing: 0) {
                    Text("@")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(colorPalette.secondaryTextColor)

                    TextField("nickname", text: $viewModel.nickname)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .frame(maxWidth: 100)
                        .foregroundColor(colorPalette.textColor)
                        .onChange(of: viewModel.nickname) { _ in
                            viewModel.saveNickname()
                        }
                        .onSubmit {
                            viewModel.saveNickname()
                        }
                }
            }

            Spacer()

            // People counter with unread indicator
            HStack(spacing: 4) {
                // Check for any unread channel messages
                let hasUnreadChannelMessages = viewModel.unreadChannelMessages.values.contains { $0 > 0 }

                if hasUnreadChannelMessages {
                    Image(systemName: "number")
                        .font(.system(size: 12))
                        .foregroundColor(Color.blue)
                }

                if !viewModel.unreadPrivateMessages.isEmpty {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.orange)
                }

                let otherPeersCount = viewModel.connectedPeers.filter { $0 != viewModel.meshService.myPeerID }.count
                let channelCount = viewModel.joinedChannels.count

                HStack(spacing: 4) {
                    // People icon with count
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11))
                    Text("\(otherPeersCount)")
                        .font(.system(size: 12, design: .monospaced))

                    // Channels icon with count (only if there are channels)
                    if channelCount > 0 {
                        Text("·")
                            .font(.system(size: 12, design: .monospaced))
                        Image(systemName: "square.split.2x2")
                            .font(.system(size: 11))
                        Text("\(channelCount)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .foregroundColor(viewModel.isConnected ? colorPalette.textColor : Color.red)
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showSidebar.toggle()
                }
            }
        }
    }

    
}
