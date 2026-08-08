import SwiftUI
import BitFoundation

/// Compact recent-DM rows for the people sheet — reopen past private threads
/// without hunting through the full mesh / favorites lists (#615).
struct RecentDirectMessagesList: View {
    @EnvironmentObject private var peerListModel: PeerListModel
    @ThemedPalette private var palette
    let onTapPeer: (PeerID) -> Void

    private enum Strings {
        static let unread = String(localized: "mesh_peers.state.unread", comment: "State label for a peer with unread private messages")
        static let openDMHint = String(localized: "mesh_peers.accessibility.open_dm_hint", comment: "Accessibility hint on a peer row explaining activation opens a private chat")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(peerListModel.recentDirectRows) { row in
                Button {
                    onTapPeer(row.peerID)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.fill")
                            .font(.bitchatSystem(size: 10))
                            .foregroundColor(palette.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(row.displayName)
                                    .bitchatFont(size: 14)
                                    .foregroundColor(palette.primary)
                                    .lineLimit(1)
                                if row.hasUnread {
                                    Image(systemName: "envelope.fill")
                                        .font(.bitchatSystem(size: 9))
                                        .foregroundColor(palette.accentBlue)
                                        .help(Strings.unread)
                                }
                            }
                            if !row.preview.isEmpty {
                                Text(row.preview)
                                    .bitchatFont(size: 11)
                                    .foregroundColor(palette.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    row.hasUnread
                        ? "\(row.displayName), \(Strings.unread)"
                        : row.displayName
                )
                .accessibilityHint(Strings.openDMHint)
            }
        }
    }
}
