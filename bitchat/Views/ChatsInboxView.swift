//
// ChatsInboxView.swift
// bitchat
//
// Inbox-first everyday home tab: displays all private direct messages,
// mutual friends, and hybrid encrypted groups sorted by unread & recency,
// using the unified AppTopBar and ThemedCard design system.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import SwiftUI

struct ChatsInboxView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    let navItems: [SectionNavItem<AppRootTab>]
    let onSelectTab: (AppRootTab) -> Void
    let onOpenAddFriend: () -> Void
    let onOpenCreateGroup: () -> Void
    let onSwitchToNearby: () -> Void
    let onSwitchToPlaces: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        let content = Group {
            if peerListModel.inboxRows.isEmpty {
                VStack(spacing: 0) {
                    banners
                    if peerListModel.reachableMeshPeerCount > 0 {
                        nearbyBanner
                    }
                    emptyInboxState
                }
                .padding(.top, theme.usesGlassChrome ? ChromeMetrics.barHeight + 10 : 0)
            } else {
                inboxList
            }
        }

        Group {
            if theme.usesGlassChrome {
                if #available(iOS 17.0, macOS 14.0, *) {
                    content
                        .overlay(alignment: .top) { topBar }
                } else {
                    VStack(spacing: 0) {
                        topBar
                        content
                    }
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedRootBackground())
    }

    @ViewBuilder
    private var banners: some View {
        if appChromeModel.panicWipeBlocked {
            ConnectivityStatusBanner(issue: .panicWipeBlocked)
        }
        if let issue = ConnectivityIssue.resolve(
            bluetoothState: appChromeModel.bluetoothState,
            torBlocked: appChromeModel.torBlocked
        ) {
            ConnectivityStatusBanner(issue: issue)
        }
    }

    private var topBar: some View {
        AppTopBar {
            HStack(spacing: 8) {
                SectionNavMenu(
                    currentTab: .chats,
                    items: navItems,
                    onSelect: onSelectTab
                )

                Button {
                    appChromeModel.presentAppInfo(pane: .settings)
                } label: {
                    Text(verbatim: "@\(appChromeModel.nickname)")
                        .bitchatFont(size: 12, weight: .medium)
                        .foregroundColor(palette.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.cardBackground)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "chats.accessibility.settings", defaultValue: "Settings", comment: "Accessibility label for profile and settings"))
            }
        } trailing: {
            TopBarIconButton(
                systemImage: "person.badge.plus",
                accessibilityLabel: String(localized: "chats.accessibility.add_friend", defaultValue: "Invite or add friend", comment: "Accessibility label for add friend toolbar button"),
                action: onOpenAddFriend
            )

            TopBarIconButton(
                systemImage: "person.3.fill",
                accessibilityLabel: String(localized: "chats.accessibility.new_group", defaultValue: "New group", comment: "Accessibility label for new group toolbar button"),
                action: onOpenCreateGroup
            )
        }
    }

    private var nearbyBanner: some View {
        Button(action: onSwitchToNearby) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.accentBlue)
                Text(
                    peerListModel.reachableMeshPeerCount == 1
                        ? String(localized: "chats.nearby_banner.one", defaultValue: "1 person nearby on Bluetooth mesh", comment: "Banner in Chats tab when 1 BLE peer is reachable")
                        : String(
                            format: String(localized: "chats.nearby_banner.many", defaultValue: "%lld people nearby on Bluetooth mesh", comment: "Banner in Chats tab when multiple BLE peers are reachable"),
                            locale: .current,
                            peerListModel.reachableMeshPeerCount
                        )
                )
                .bitchatFont(size: 13, weight: .medium)
                .foregroundColor(palette.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: ChromeMetrics.rowChevronSize, weight: .semibold))
                    .foregroundColor(palette.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.accentBlue.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous)
                    .stroke(palette.accentBlue.opacity(0.22), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var inboxList: some View {
        let list = ScrollView {
            LazyVStack(spacing: 0) {
                banners
                if peerListModel.reachableMeshPeerCount > 0 {
                    nearbyBanner
                }
                ForEach(peerListModel.inboxRows) { row in
                    Button {
                        privateConversationModel.openConversation(for: row.peerID)
                    } label: {
                        inboxRowView(row)
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(palette.divider)
                        .frame(height: 1)
                        .padding(.leading, 72)
                }
            }
            .padding(.top, 6)
        }

        if theme.usesGlassChrome {
            if #available(iOS 17.0, macOS 14.0, *) {
                list
                    .contentMargins(.top, ChromeMetrics.barHeight + 10, for: .scrollContent)
                    .contentMargins(.top, ChromeMetrics.barHeight + 10, for: .scrollIndicators)
            } else {
                list
            }
        } else {
            list
        }
    }

    private func inboxRowView(_ row: InboxChatRow) -> some View {
        HStack(spacing: 12) {
            avatarView(for: row)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .bitchatFont(size: 15, weight: row.hasUnread ? .bold : .semibold)
                        .foregroundColor(palette.primary)
                        .lineLimit(1)

                    if row.isGroup {
                        Text(verbatim: "\(row.memberCount)")
                            .bitchatFont(size: 11, weight: .medium)
                            .foregroundColor(palette.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(palette.cardBackground)
                            .clipShape(Capsule())
                    }

                    if row.disappearingTimer != .off {
                        Image(systemName: row.disappearingTimer.iconName)
                            .font(.system(size: 11))
                            .foregroundColor(palette.secondary)
                    }

                    Spacer(minLength: 4)

                    if let lastActivity = row.lastActivity {
                        Text(Self.relativeFormatter.localizedString(for: lastActivity, relativeTo: Date()))
                            .bitchatFont(size: 12)
                            .foregroundColor(row.hasUnread ? palette.accent : palette.secondary)
                    }
                }

                HStack(spacing: 6) {
                    reachabilityGlyph(for: row.reachability)
                    Text(row.subtitle)
                        .bitchatFont(size: 13)
                        .foregroundColor(row.hasUnread ? palette.primary : palette.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if row.hasUnread {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func avatarView(for row: InboxChatRow) -> some View {
        let tint: Color = row.isGroup
            ? palette.accent
            : peerListModel.colorForMeshPeer(id: row.peerID, isDark: colorScheme == .dark)
        return ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: 44, height: 44)
            if row.isGroup {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(tint)
            } else {
                Text(String(row.displayName.prefix(1)).uppercased())
                    .bitchatFont(size: 17, weight: .bold)
                    .foregroundColor(tint)
            }
        }
    }

    @ViewBuilder
    private func reachabilityGlyph(for reachability: InboxChatRow.Reachability) -> some View {
        switch reachability {
        case .meshConnected:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundColor(palette.accentBlue)
        case .meshReachable:
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 11))
                .foregroundColor(palette.accentBlue)
        case .nostr:
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundColor(.purple)
        case .group:
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundColor(palette.secondary)
        case .offline:
            EmptyView()
        }
    }

    private var emptyInboxState: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 36)

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 42))
                    .foregroundColor(palette.accent)
                    .padding(18)
                    .background(palette.accent.opacity(0.14))
                    .clipShape(Circle())

                VStack(spacing: 8) {
                    Text(String(localized: "chats.empty.title", defaultValue: "Private chats that work anywhere", comment: "Empty inbox headline"))
                        .bitchatFont(size: 20, weight: .bold)
                        .foregroundColor(palette.primary)
                        .multilineTextAlignment(.center)

                    Text(String(localized: "chats.empty.subtitle", defaultValue: "End-to-end encrypted over the internet and automatically offline over Bluetooth mesh when signal drops.", comment: "Empty inbox description"))
                        .bitchatFont(size: 14)
                        .foregroundColor(palette.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)

                VStack(spacing: 10) {
                    Button(action: onOpenAddFriend) {
                        Label(
                            String(localized: "chats.empty.invite_cta", defaultValue: "Invite a Friend", comment: "Primary CTA in empty Chats tab"),
                            systemImage: "person.badge.plus"
                        )
                        .bitchatFont(size: 15, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(palette.accent)
                        .foregroundColor(palette.accentForeground)
                        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(action: onOpenCreateGroup) {
                        Label(
                            String(localized: "chats.empty.group_cta", defaultValue: "Create a Group", comment: "Secondary CTA in empty Chats tab"),
                            systemImage: "person.3.fill"
                        )
                        .bitchatFont(size: 15, weight: .medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                                .stroke(palette.cardBorder, lineWidth: 1)
                        )
                        .foregroundColor(palette.primary)
                        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 28)

                HStack(spacing: 10) {
                    Button(action: onSwitchToNearby) {
                        Label(
                            String(localized: "chats.empty.nearby_shortcut", defaultValue: "Nearby Mesh", comment: "Shortcut pill to Nearby tab"),
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                        .bitchatFont(size: 13, weight: .medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                                .stroke(palette.cardBorder, lineWidth: 1)
                        )
                        .foregroundColor(palette.primary)
                        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(action: onSwitchToPlaces) {
                        Label(
                            String(localized: "chats.empty.places_shortcut", defaultValue: "Explore Places", comment: "Shortcut pill to Places tab"),
                            systemImage: "globe.americas.fill"
                        )
                        .bitchatFont(size: 13, weight: .medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous)
                                .stroke(palette.cardBorder, lineWidth: 1)
                        )
                        .foregroundColor(palette.primary)
                        .clipShape(RoundedRectangle(cornerRadius: palette.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
