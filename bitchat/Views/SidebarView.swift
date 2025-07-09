
//
//  SidebarView.swift
//  bitchat
//
//  Created by Gemini on 7/9/25.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var showSidebar: Bool
    @Environment(\.colorScheme) var colorScheme

    private var colorPalette: ColorPalette {
        ColorPalette.forColorScheme(colorScheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Grey vertical bar for visual continuity
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                // Header - match main toolbar height
                HStack {
                    Text("YOUR NETWORK")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(colorPalette.textColor)
                    Spacer()
                }
                .frame(height: 44) // Match header height
                .padding(.horizontal, 12)
                .background(colorPalette.backgroundColor.opacity(0.95))

                Divider()

                // Rooms and People list
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Channels section
                        channelsSection

                        if !viewModel.joinedChannels.isEmpty {
                            Divider()
                                .padding(.vertical, 4)
                        }

                        // People section
                        peopleSection
                    }
                    .padding(.vertical, 8)
                }

                Spacer()
            }
            .background(colorPalette.backgroundColor)
        }
    }

    @ViewBuilder
    private var channelsSection: some View {
        if !viewModel.joinedChannels.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "square.split.2x2")
                        .font(.system(size: 10))
                    Text("CHANNELS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundColor(colorPalette.secondaryTextColor)
                .padding(.horizontal, 12)

                ForEach(Array(viewModel.joinedChannels).sorted(), id: \.self) { channel in
                    channelButton(for: channel)
                }
            }
        }
    }

    @ViewBuilder
    private func channelButton(for channel: String) -> some View {
        Button(action: {
            // Check if channel needs password and we don't have it
            if viewModel.passwordProtectedChannels.contains(channel) && viewModel.channelKeys[channel] == nil {
                // Need password
                viewModel.passwordPromptChannel = channel
                viewModel.showPasswordPrompt = true
            } else {
                // Can enter channel
                viewModel.switchToChannel(channel)
                withAnimation(.spring()) {
                    showSidebar = false
                }
            }
        }) {
            HStack {
                // Lock icon for password protected channels
                if viewModel.passwordProtectedChannels.contains(channel) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(colorPalette.secondaryTextColor)
                }

                Text(channel)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(viewModel.currentChannel == channel ? Color.blue : colorPalette.textColor)

                Spacer()

                // Unread count
                if let unreadCount = viewModel.unreadChannelMessages[channel], unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(colorPalette.backgroundColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .clipShape(Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(viewModel.currentChannel == channel ? colorPalette.backgroundColor.opacity(0.5) : Color.clear)
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Show appropriate header based on context
            if let currentChannel = viewModel.currentChannel {
                Text("IN \(currentChannel.uppercased())")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(colorPalette.secondaryTextColor)
                    .padding(.horizontal, 12)
            } else if !viewModel.connectedPeers.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                    Text("PEOPLE")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundColor(colorPalette.secondaryTextColor)
                .padding(.horizontal, 12)
            }

            if viewModel.connectedPeers.isEmpty {
                Text("No one connected")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(colorPalette.secondaryTextColor)
                    .padding(.horizontal)
            } else if let currentChannel = viewModel.currentChannel,
                      let channelMemberIDs = viewModel.channelMembers[currentChannel],
                      channelMemberIDs.isEmpty {
                Text("No one in this channel yet")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(colorPalette.secondaryTextColor)
                    .padding(.horizontal)
            } else {
                let sortedPeers = viewModel.sortedPeers(in: viewModel.currentChannel)

                ForEach(sortedPeers, id: \.self) { peerID in
                    PeerRow(peerID: peerID, showSidebar: $showSidebar)
                }
            }
        }
    }

    @ViewBuilder
    private func channelControls(for channel: String) -> some View {
        HStack(spacing: 4) {
            // Password button for channel creator only
            if viewModel.channelCreators[channel] == viewModel.meshService.myPeerID {
                Button(action: {
                    // Toggle password protection
                    if viewModel.passwordProtectedChannels.contains(channel) {
                        viewModel.removeChannelPassword(for: channel)
                    } else {
                        // Show password input
                        viewModel.showPasswordInput = true
                        viewModel.passwordInputChannel = channel
                    }
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: viewModel.passwordProtectedChannels.contains(channel) ? "lock.fill" : "lock")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(viewModel.passwordProtectedChannels.contains(channel) ? colorPalette.backgroundColor : colorPalette.secondaryTextColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(viewModel.passwordProtectedChannels.contains(channel) ? Color.orange : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(viewModel.passwordProtectedChannels.contains(channel) ? Color.orange : colorPalette.secondaryTextColor.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            // Leave button
            Button(action: {
                viewModel.showLeaveChannelAlert = true
            }) {
                Text("leave channel")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(colorPalette.secondaryTextColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(colorPalette.secondaryTextColor.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .alert("leave channel", isPresented: $viewModel.showLeaveChannelAlert) {
                Button("cancel", role: .cancel) { }
                Button("leave", role: .destructive) {
                    viewModel.leaveChannel(channel)
                }
            } message: {
                Text("sure you want to leave \(channel)?")
            }
        }
    }
}
