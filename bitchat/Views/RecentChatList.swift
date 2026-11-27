//
// RecentChatList.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import SwiftUI

/// "chats" section for the people sheet: direct conversations with people
/// who are not in any roster above it (offline passersby, geoDMs from a
/// channel since left). Before this section existed, those threads were
/// unreachable the moment the unread envelope cleared — still in memory,
/// no row anywhere in the UI. Renders nothing when there are none.
struct RecentChatList: View {
    @ThemedPalette private var palette

    let chats: [RecentChatRow]
    let onTapChat: (PeerID) -> Void
    /// Clears the unread badge without opening the conversation.
    var onClearUnread: ((PeerID) -> Void)? = nil

    private enum Strings {
        static let header = String(localized: "chats.section.header", defaultValue: "chats", comment: "Section header above recent direct conversations in the people sheet")
        static let unread = String(localized: "mesh_peers.state.unread", comment: "State label for a peer with unread private messages")
        static let newMessagesTooltip = String(localized: "mesh_peers.tooltip.new_messages", comment: "Tooltip for the unread messages indicator")
        static let markRead = String(localized: "conversation.action.mark_read", comment: "Context menu action that clears the unread badge for one conversation")
        static let openChatHint = String(localized: "chats.accessibility.open_hint", defaultValue: "opens this conversation", comment: "Accessibility hint on a recent chat row explaining activation opens the direct conversation")
    }

    /// Relative "5 min ago" stamps; the formatter is locale-aware.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        if !chats.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Same glyph+label header shape as #mesh / groups.
                PeopleSectionHeader(
                    icon: "bubble.left.and.bubble.right",
                    iconColor: palette.secondary,
                    title: Strings.header
                )

                ForEach(chats) { chat in
                    HStack(spacing: 4) {
                        Text(verbatim: chat.displayName)
                            .bitchatFont(size: 14)
                            .foregroundColor(palette.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(verbatim: Self.relativeFormatter.localizedString(for: chat.lastActivity, relativeTo: Date()))
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.secondary.opacity(0.8))

                        Spacer()

                        if chat.hasUnread {
                            Image(systemName: "envelope.fill")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.orange)
                                .help(Strings.newMessagesTooltip)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { onTapChat(chat.peerID) }
                    .contextMenu {
                        if chat.hasUnread, let onClearUnread {
                            Button(Strings.markRead) {
                                onClearUnread(chat.peerID)
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityDescription(for: chat))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Strings.openChatHint)
                    .accessibilityActions {
                        if chat.hasUnread, let onClearUnread {
                            Button(Strings.markRead) {
                                onClearUnread(chat.peerID)
                            }
                        }
                    }
                }
            }
        }
    }

    private func accessibilityDescription(for chat: RecentChatRow) -> String {
        var parts: [String] = [
            chat.displayName,
            Self.relativeFormatter.localizedString(for: chat.lastActivity, relativeTo: Date())
        ]
        if chat.hasUnread { parts.append(Strings.unread) }
        return parts.joined(separator: ", ")
    }
}
