import BitFoundation
import SwiftUI

/// Compact "groups" section for the people sheet: one row per private group
/// this device belongs to, tappable to open the group chat window.
struct GroupChatList: View {
    @ThemedPalette private var palette

    let groups: [GroupChatRow]
    let onTapGroup: (PeerID) -> Void

    private enum Strings {
        static let header = String(localized: "groups.section.header", comment: "Section header above the private groups list")
        static let creator = String(localized: "groups.state.creator", comment: "State label for a group the user created")
        static let unread = String(localized: "mesh_peers.state.unread", comment: "State label for a peer with unread private messages")
        static let newMessagesTooltip = String(localized: "mesh_peers.tooltip.new_messages", comment: "Tooltip for the unread messages indicator")
        static let openGroupHint = String(localized: "groups.accessibility.open_group_hint", comment: "Accessibility hint on a group row explaining activation opens the group chat")
        static let memberCountFormat = String(localized: "groups.member_count %@", comment: "Member count shown next to a group name; placeholder is the count")
    }

    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Same glyph+label header shape as #mesh / across the bridge.
                PeopleSectionHeader(
                    icon: "person.3.fill",
                    iconColor: palette.primary,
                    title: Strings.header
                )

                ForEach(groups) { group in
                    HStack(spacing: 4) {
                        Text("#\(group.name)")
                            .bitchatFont(size: 14)
                            .foregroundColor(palette.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(String(format: Strings.memberCountFormat, locale: .current, "\(group.memberCount)"))
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)

                        if group.isCreator {
                            Image(systemName: "crown.fill")
                                .font(.bitchatSystem(size: 9))
                                .foregroundColor(.yellow)
                                .help(Strings.creator)
                        }

                        Spacer()

                        if group.hasUnread {
                            Image(systemName: "envelope.fill")
                                .font(.bitchatSystem(size: 10))
                                .foregroundColor(.orange)
                                .help(Strings.newMessagesTooltip)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { onTapGroup(group.peerID) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityDescription(for: group))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Strings.openGroupHint)
                }
            }
        }
    }

    private func accessibilityDescription(for group: GroupChatRow) -> String {
        var parts: [String] = [
            group.name,
            String(format: Strings.memberCountFormat, locale: .current, "\(group.memberCount)")
        ]
        if group.isCreator { parts.append(Strings.creator) }
        if group.hasUnread { parts.append(Strings.unread) }
        return parts.joined(separator: ", ")
    }
}
