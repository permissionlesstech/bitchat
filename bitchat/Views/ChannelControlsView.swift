
//
//  ChannelControlsView.swift
//  bitchat
//
//  Created by Gemini on 7/9/25.
//

import SwiftUI

struct ChannelControlsView: View {
    let channel: String
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme

    private var colorPalette: ColorPalette {
        ColorPalette.forColorScheme(colorScheme)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Show retention indicator for all users
            if viewModel.retentionEnabledChannels.contains(channel) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Color.yellow)
                    .help("Messages in this channel are being saved locally")
            }

            // Save button - only for channel owner
            if viewModel.channelCreators[channel] == viewModel.meshService.myPeerID {
                Button(action: {
                    viewModel.sendMessage("/save")
                }) {
                    Image(systemName: viewModel.retentionEnabledChannels.contains(channel) ? "bookmark.slash" : "bookmark")
                        .font(.system(size: 16))
                        .foregroundColor(colorPalette.textColor)
                }
                .buttonStyle(.plain)
                .help(viewModel.retentionEnabledChannels.contains(channel) ? "Disable message retention" : "Enable message retention")
            }

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
                    Image(systemName: viewModel.passwordProtectedChannels.contains(channel) ? "lock.fill" : "lock")
                        .font(.system(size: 16))
                        .foregroundColor(viewModel.passwordProtectedChannels.contains(channel) ? Color.yellow : colorPalette.textColor)
                }
                .buttonStyle(.plain)
            }

            // Leave channel button
            Button(action: {
                viewModel.showLeaveChannelAlert = true
            }) {
                Text("leave")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.red)
            }
            .buttonStyle(.plain)
        }
    }
}
