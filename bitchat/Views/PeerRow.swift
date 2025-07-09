
//
//  PeerRow.swift
//  bitchat
//
//  Created by Gemini on 7/9/25.
//

import SwiftUI

struct PeerRow: View {
    let peerID: String
    @Binding var showSidebar: Bool
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme

    private var colorPalette: ColorPalette {
        ColorPalette.forColorScheme(colorScheme)
    }

    var body: some View {
        let peerNicknames = viewModel.meshService.getPeerNicknames()
        let peerRSSI = viewModel.meshService.getPeerRSSI()
        let myPeerID = viewModel.meshService.myPeerID

        let displayName = peerID == myPeerID ? viewModel.nickname : (peerNicknames[peerID] ?? "person-\(peerID.prefix(4))")
        let rssi = peerRSSI[peerID]?.intValue ?? -100
        let isFavorite = viewModel.isFavorite(peerID: peerID)
        let isMe = peerID == myPeerID

        HStack(spacing: 8) {
            // Signal strength indicator or unread message icon
            if isMe {
                Image(systemName: "person.fill")
                    .font(.system(size: 10))
                    .foregroundColor(colorPalette.textColor)
            } else if viewModel.unreadPrivateMessages.contains(peerID) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color.orange)
            } else {
                Circle()
                    .fill(viewModel.getRSSIColor(rssi: rssi, colorScheme: colorScheme))
                    .frame(width: 8, height: 8)
            }

            // Favorite star (not for self)
            if !isMe {
                Button(action: {
                    viewModel.toggleFavorite(peerID: peerID)
                }) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundColor(isFavorite ? Color.yellow : colorPalette.secondaryTextColor)
                }
                .buttonStyle(.plain)
            }

            // Peer name
            if isMe {
                HStack {
                    Text(displayName + " (you)")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(colorPalette.textColor)

                    Spacer()
                }
            } else {
                Button(action: {
                    if peerNicknames[peerID] != nil {
                        viewModel.startPrivateChat(with: peerID)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showSidebar = false
                        }
                    }
                }) {
                    HStack {
                        Text(displayName)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(peerNicknames[peerID] != nil ? colorPalette.textColor : colorPalette.secondaryTextColor)

                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .disabled(peerNicknames[peerID] == nil)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
