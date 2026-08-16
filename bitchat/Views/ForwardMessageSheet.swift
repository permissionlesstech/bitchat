//
// ForwardMessageSheet.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import SwiftUI

/// Picker presented from a message's context menu: choose a direct
/// conversation to resend this message's content into. Deliberately DMs
/// only for v1 -- forwarding into a public mesh/geohash channel is a
/// materially different action (broadcasting someone's content rather than
/// resending it privately) and stays out of scope here.
///
/// Sources targets the same way the people sheet does: currently-known mesh
/// peers first (PeerListModel.meshRows, connected or not), then people whose
/// direct conversation fell out of that roster (PeerListModel.recentChatRows,
/// reusing RecentChatList verbatim -- see its own doc comment for why that
/// section exists). "Me" and blocked peers are never valid forward targets.
struct ForwardMessageSheet: View {
    @EnvironmentObject private var peerListModel: PeerListModel
    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    /// Called with the chosen recipient; the sheet dismisses itself right
    /// after, so this only needs to hand off the target.
    let onForward: (PeerID) -> Void

    private enum Strings {
        static let title = String(localized: "forward.title", defaultValue: "Forward to…", comment: "Title of the sheet for picking who to forward a message to")
        static let noRecipients = String(localized: "forward.no_recipients", defaultValue: "No one to forward to yet — no known peers or recent conversations.", comment: "Empty state shown in the forward-message sheet when there is nobody to pick")
        static let peersHeader = String(localized: "forward.peers_header", defaultValue: "people", comment: "Section header above known peers in the forward-message sheet")
    }

    private var meshTargets: [MeshPeerRow] {
        peerListModel.meshRows.filter { !$0.isMe && !$0.isBlocked }
    }

    private var hasAnyTarget: Bool {
        !meshTargets.isEmpty || !peerListModel.recentChatRows.isEmpty
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text(Strings.title)
                    .bitchatFont(size: 16, weight: .bold)
                    .foregroundColor(palette.primary)
                Spacer()
                SheetCloseButton { dismiss() }
                    .foregroundColor(palette.primary)
            }
            .padding()
            .themedSurface(opacity: 0.95)

            content
        }
        .frame(width: 380, height: 420)
        .themedSheetBackground()
        #else
        NavigationView {
            content
                .themedSheetBackground()
                .navigationTitle(Text(Strings.title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        SheetCloseButton { dismiss() }
                            .foregroundColor(palette.primary)
                    }
                }
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if !hasAnyTarget {
            VStack {
                Spacer()
                Text(Strings.noRecipients)
                    .bitchatFont(size: 14)
                    .foregroundColor(palette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !meshTargets.isEmpty {
                        PeopleSectionHeader(
                            icon: "antenna.radiowaves.left.and.right",
                            iconColor: palette.accentBlue,
                            title: Strings.peersHeader
                        )
                        ForEach(meshTargets) { peer in
                            forwardRow(displayName: peer.displayName, peerID: peer.peerID)
                        }
                    }

                    RecentChatList(chats: peerListModel.recentChatRows) { peerID in
                        forward(to: peerID)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func forwardRow(displayName: String, peerID: PeerID) -> some View {
        Button {
            forward(to: peerID)
        } label: {
            Text(verbatim: displayName)
                .bitchatFont(size: 14)
                .foregroundColor(palette.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func forward(to peerID: PeerID) {
        onForward(peerID)
        dismiss()
    }
}
