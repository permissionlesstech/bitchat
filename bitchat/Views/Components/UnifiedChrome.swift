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

/// Standard height and icon metrics shared across all top and bottom bars.
enum ChromeMetrics {
    static let barHeight: CGFloat = 48
    static let bottomBarHeight: CGFloat = 40
    static let iconSize: CGFloat = 16
    static let iconTapSize: CGFloat = 36
}

/// Descriptor for one item in `SlimBottomTabBar`.
struct SlimTabItem<Tab: Hashable>: Identifiable {
    let tab: Tab
    let title: String
    let systemImage: String
    var badgeCount: Int = 0

    var id: Tab { tab }
}

/// Compact 40pt bottom navigation bar shared across iOS and macOS: renders as
/// a sleek floating Liquid Glass capsule in Liquid Glass mode and a flat
/// hairline bar in Matrix mode.
struct SlimBottomTabBar<Tab: Hashable>: View {
    @Binding var selection: Tab
    let items: [SlimTabItem<Tab>]
    var onSelect: ((Tab) -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let isSelected = selection == item.tab
                Button {
                    if selection != item.tab {
                        selection = item.tab
                    }
                    onSelect?(item.tab)
                } label: {
                    VStack(spacing: 2) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                                .frame(height: 16)

                            if item.badgeCount > 0 {
                                Text(verbatim: item.badgeCount > 99 ? "99+" : "\(item.badgeCount)")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 14, minHeight: 13)
                                    .background(palette.alertRed)
                                    .clipShape(Capsule())
                                    .offset(x: 11, y: -4)
                            }
                        }

                        Text(item.title)
                            .bitchatFont(size: 9.5, weight: isSelected ? .semibold : .medium)
                            .lineLimit(1)
                    }
                    .foregroundColor(isSelected ? palette.accent : palette.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: ChromeMetrics.bottomBarHeight)
                    .background(
                        Group {
                            if isSelected && theme.usesGlassChrome {
                                Capsule()
                                    .fill(palette.accent.opacity(0.14))
                            }
                        }
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .themedBottomBarSurface()
    }
}

/// Unified floating/flat top navigation bar used by Chats, Nearby, Places,
/// and active Place rooms so switching tabs never jumps header style or height.
struct AppTopBar<Leading: View, Trailing: View>: View {
    @ThemedPalette private var palette
    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = ChromeMetrics.barHeight

    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                trailing()
            }
            .layoutPriority(3)
        }
        .frame(height: barHeight)
        .padding(.horizontal, 14)
        .themedChromePanel(edge: .top)
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

/// Unified sheet header: title (and optional subtitle) on the left, optional
/// trailing accessories, and `SheetCloseButton` consistently on the top-right.
struct ThemedSheetHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing
    let onClose: () -> Void

    @ThemedPalette private var palette

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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
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
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .themedSurface()

            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)
        }
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
