//
// UnifiedChrome.swift
// bitchat
//
// Shared layout primitives so every root tab (Chats, Nearby, Places) and every
// modal sheet (Settings, Add Friend, New Group, Group Info, People, Notices)
// speaks one consistent visual language in both Liquid Glass and Matrix themes.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Standard height and icon metrics shared across all top bars and rows.
enum ChromeMetrics {
    static let barHeight: CGFloat = 46
    static let iconSize: CGFloat = 16
    static let iconTapSize: CGFloat = 36
    static let backChevronSize: CGFloat = 15
    static let rowChevronSize: CGFloat = 12
}

/// Descriptor for one destination in the top-left section dropdown menu.
struct SectionNavItem<Tab: Hashable>: Identifiable {
    let tab: Tab
    let title: String
    let systemImage: String
    var badgeCount: Int = 0
    /// True only for actionable unread indicators (e.g. unread DMs in Chats),
    /// never for passive presence counts like nearby BLE peers.
    var showsAlertDot: Bool = false

    var id: Tab { tab }
}

/// Top-left section switcher dropdown replacing a bottom tab bar so every
/// screen maximizes vertical space with zero bottom navigation chrome.
struct SectionNavMenu<Tab: Hashable>: View {
    let currentTab: Tab
    let items: [SectionNavItem<Tab>]
    let onSelect: (Tab) -> Void

    @ThemedPalette private var palette

    private var currentTitle: String {
        items.first(where: { $0.tab == currentTab })?.title ?? ""
    }

    private var hasUnreadElsewhere: Bool {
        items.contains { $0.tab != currentTab && $0.showsAlertDot }
    }

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button {
                    onSelect(item.tab)
                } label: {
                    if item.badgeCount > 0 {
                        Label {
                            Text(verbatim: "\(item.title) (\(item.badgeCount))")
                        } icon: {
                            Image(systemName: item.tab == currentTab ? "checkmark" : item.systemImage)
                        }
                    } else {
                        Label(
                            item.title,
                            systemImage: item.tab == currentTab ? "checkmark" : item.systemImage
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentTitle)
                    .bitchatFont(size: 19, weight: .bold)
                    .foregroundColor(palette.primary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: ChromeMetrics.rowChevronSize, weight: .semibold))
                    .foregroundColor(palette.secondary)

                if hasUnreadElsewhere {
                    Circle()
                        .fill(palette.alertRed)
                        .frame(width: 7, height: 7)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(currentTitle)
    }
}

/// Surface style for `AppTopBar`. Root tabs float as Liquid Glass pills with
/// zero divider lines; sheets sit flush inside native rounded sheet corners.
enum AppTopBarStyle {
    case floating
    case sheet
}

/// Unified top navigation bar used across root tabs, active Place rooms, and
/// DM/group sheets.
struct AppTopBar<Leading: View, Trailing: View>: View {
    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = ChromeMetrics.barHeight

    let style: AppTopBarStyle
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    init(
        style: AppTopBarStyle = .floating,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.style = style
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        let bar = HStack(spacing: 8) {
            leading()
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                trailing()
            }
            .layoutPriority(3)
        }
        .frame(height: barHeight)
        .padding(.horizontal, 14)

        switch style {
        case .floating:
            bar.themedChromePanel(edge: .top)
        case .sheet:
            bar
                .padding(.top, 4)
                .themedSurface()
        }
    }
}

extension View {
    /// Arms the Stealth Mode emergency triple-tap panic wipe on root top bars.
    /// Uses `simultaneousGesture` so single-tap navigation menus and buttons keep
    /// responding immediately while a deliberate triple-tap triggers the dialog.
    func stealthTripleTapPanicWipe(action: @escaping () -> Void) -> some View {
        self.simultaneousGesture(
            TapGesture(count: 3)
                .onEnded {
                    guard PrivacyModeSettings.isTripleTapPanicEnabled() else { return }
                    action()
                }
        )
    }
}

/// Consistent icon button for `AppTopBar` and sheet toolbars (36×36 visual
/// box with 44pt effective hit area).
struct TopBarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var color: Color? = nil
    var badgeCount: Int = 0
    let action: () -> Void

    @ThemedPalette private var palette

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: ChromeMetrics.iconSize, weight: .medium))
                    .foregroundColor(color ?? palette.primary)
                    .frame(width: ChromeMetrics.iconTapSize, height: ChromeMetrics.iconTapSize)
                    .contentShape(Rectangle())

                if badgeCount > 0 {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                        .offset(x: -5, y: 6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Unified sheet header: flush with native rounded sheet corners and borderless
/// so there are zero double-rounded corner collisions or heavy divider lines.
struct ThemedSheetHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing
    let onClose: () -> Void

    @ThemedPalette private var palette
    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = ChromeMetrics.barHeight

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .bitchatFont(size: 18, weight: .semibold)
                    .foregroundColor(palette.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .bitchatFont(size: 12)
                        .foregroundColor(palette.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
            SheetCloseButton(action: onClose)
                .foregroundColor(palette.primary)
        }
        .frame(minHeight: barHeight)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .themedSurface()
    }
}

/// Unified grouped card container used across Settings, Places, Groups, and Add Friend.
struct ThemedCard<Content: View>: View {
    let padding: CGFloat
    let spacing: CGFloat
    let content: Content

    @ThemedPalette private var palette

    init(
        padding: CGFloat = 14,
        spacing: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous)
                .stroke(palette.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: palette.cardRadius, style: .continuous))
    }
}

/// Unified uppercase section caption placed above `ThemedCard` blocks.
struct ThemedSectionLabel: View {
    let text: String
    @ThemedPalette private var palette

    var body: some View {
        Text(text)
            .bitchatFont(size: 11, weight: .semibold)
            .foregroundColor(palette.secondary)
            .tracking(0.4)
    }
}
