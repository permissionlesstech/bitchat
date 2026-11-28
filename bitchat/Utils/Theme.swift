//
// Theme.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// A user-selectable app-wide visual theme. Persisted by raw value.
enum AppTheme: String, CaseIterable, Identifiable {
    case matrix
    case liquidGlass

    var id: String { rawValue }

    /// UserDefaults key backing the theme selection.
    static let storageKey = "appTheme"

    var displayNameKey: String {
        switch self {
        case .matrix: return String(localized: "app_info.appearance.matrix")
        case .liquidGlass: return String(localized: "app_info.appearance.liquid_glass")
        }
    }

    /// Font design used for themed text. Matrix keeps the terminal monospace;
    /// liquid glass uses the system default.
    var bodyFontDesign: Font.Design {
        switch self {
        case .matrix: return .monospaced
        case .liquidGlass: return .default
        }
    }

    /// Whether chrome surfaces (header/composer bars, input field) render as
    /// translucent glass/material instead of the flat matrix background.
    var usesGlassChrome: Bool {
        self == .liquidGlass
    }

    /// Discriminator mixed into per-message formatting caches so cached
    /// AttributedStrings from one theme are never served under another.
    /// Empty for matrix to keep its historical cache keys.
    var formatCacheVariant: String {
        switch self {
        case .matrix: return ""
        case .liquidGlass: return "lg:"
        }
    }

    /// Resolves the semantic color palette for this theme under the given color scheme.
    func palette(for colorScheme: ColorScheme) -> ThemePalette {
        switch self {
        case .matrix:
            return .matrix(colorScheme)
        case .liquidGlass:
            return .liquidGlass(colorScheme)
        }
    }
}

/// Semantic colors for the active theme, resolved against the current color scheme.
/// Views should consume these via `@ThemedPalette` rather than computing colors inline.
struct ThemePalette {
    /// Primary window/sheet background.
    let background: Color
    /// Primary text color.
    let primary: Color
    /// De-emphasized text (timestamps, hints, captions).
    let secondary: Color
    /// Interactive tint (buttons, toggles, selection).
    let accent: Color
    /// High-contrast text/icon color rendered on top of `accent` fills.
    let accentForeground: Color
    /// Location/geohash channel accent (badges, counts, subtitles).
    let locationAccent: Color
    /// Informational accent (links, read receipts, teleport markers).
    let accentBlue: Color
    /// Destructive/error accent.
    let alertRed: Color
    /// Hairline separators.
    let divider: Color
    /// Unified card fill across tabs and sheets.
    let cardBackground: Color
    /// Subtle hairline border around cards.
    let cardBorder: Color
    /// Consistent corner radius for grouped cards.
    let cardRadius: CGFloat
    /// Consistent corner radius for primary/secondary action buttons.
    let buttonRadius: CGFloat

    static func matrix(_ colorScheme: ColorScheme) -> ThemePalette {
        let isDark = colorScheme == .dark
        let green = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        return ThemePalette(
            background: isDark ? Color.black : Color.white,
            primary: green,
            secondary: green.opacity(0.8),
            accent: green,
            accentForeground: isDark ? Color.black : Color.white,
            locationAccent: green,
            accentBlue: Color(red: 0.0, green: 0.478, blue: 1.0),
            alertRed: Color(red: 0.75, green: 0.1, blue: 0.1),
            divider: isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
            cardBackground: green.opacity(isDark ? 0.10 : 0.07),
            cardBorder: green.opacity(isDark ? 0.25 : 0.18),
            cardRadius: 8,
            buttonRadius: 6
        )
    }

    static func liquidGlass(_ colorScheme: ColorScheme) -> ThemePalette {
        let isDark = colorScheme == .dark
        return ThemePalette(
            background: isDark ? Color(red: 0.04, green: 0.04, blue: 0.05) : Color(red: 0.96, green: 0.965, blue: 0.975),
            primary: .primary,
            secondary: .secondary,
            accent: .blue,
            accentForeground: .white,
            locationAccent: .green,
            accentBlue: .blue,
            alertRed: .red,
            divider: isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.08),
            cardBackground: isDark ? Color.white.opacity(0.07) : Color.white,
            cardBorder: isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.07),
            cardRadius: 14,
            buttonRadius: 12
        )
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .liquidGlass
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

/// Resolves the active theme's palette against the view's color scheme.
///
///     @ThemedPalette private var palette
///     var body: some View { Text("hi").foregroundColor(palette.primary) }
@propertyWrapper
struct ThemedPalette: DynamicProperty {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var wrappedValue: ThemePalette { theme.palette(for: colorScheme) }
}

// MARK: - Themed view helpers

/// Themed replacement for `.font(.bitchatSystem(size:weight:design: .monospaced))`:
/// monospaced under matrix, system default under liquid glass.
private struct ThemedFontModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.bitchatSystem(size: size, weight: weight, design: theme.bodyFontDesign))
    }
}

/// Root backdrop. Matrix gets its pure black/white terminal canvas; Liquid Glass
/// gets a crisp, neutral system-like canvas so chat timelines, usernames, cards,
/// and translucent glass controls stay razor-sharp without pastel color cast.
struct ThemedRootBackground: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @ThemedPalette private var palette

    var body: some View {
        if theme.usesGlassChrome {
            let isDark = colorScheme == .dark
            LinearGradient(
                colors: isDark
                    ? [Color(red: 0.055, green: 0.058, blue: 0.068), Color(red: 0.025, green: 0.025, blue: 0.032)]
                    : [Color(red: 0.965, green: 0.968, blue: 0.976), Color(red: 0.945, green: 0.950, blue: 0.962)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        } else {
            // Full-bleed like the gradient above. Passed to .background(_:)
            // as a view, a backdrop stops at the safe area (a bare Color
            // passed as a ShapeStyle would not). In a sheet, the sheet's own
            // background (#1C1C1E in dark mode) then shows through the
            // home-indicator inset and under the navigation bar.
            palette.background
                .ignoresSafeArea()
        }
    }
}

/// Wraps glass-shape content in real Liquid Glass on OS 26+, with a material
/// fallback below that keeps the frosted look.
private struct GlassPanel<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            materialFallback(content)
        }
        #else
        materialFallback(content)
        #endif
    }

    private func materialFallback(_ content: Content) -> some View {
        content
            .background(shape.fill(.ultraThinMaterial))
            .overlay(shape.stroke(Color.white.opacity(0.15), lineWidth: 0.5))
    }
}

/// Floating Liquid Glass chrome for root top bars and the chat composer — no
/// full-width divider lines, maximizing vertical space while content scrolls
/// underneath. Matrix keeps its classic flat bar wash.
private struct ThemedChromePanelModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette
    let edge: VerticalEdge

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.usesGlassChrome {
            content
                .modifier(GlassPanel(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
                .padding(.horizontal, 10)
                .padding(edge == .top ? .top : .bottom, 4)
        } else {
            content.background(palette.background.opacity(0.95))
        }
    }
}

/// Background for the composer input field. Liquid Glass leaves it clear so
/// the field sits directly inside the single floating glass capsule (no nested
/// box-in-box); Matrix keeps its subtle rounded fill.
private struct ThemedInputBackgroundModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.usesGlassChrome {
            content
        } else {
            content.background(
                shape.fill(colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.7))
            )
        }
    }
}

extension View {
    func bitchatFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ThemedFontModifier(size: size, weight: weight))
    }

    func themedChromePanel(edge: VerticalEdge) -> some View {
        modifier(ThemedChromePanelModifier(edge: edge))
    }

    func themedInputBackground() -> some View {
        modifier(ThemedInputBackgroundModifier())
    }

    /// Floating surface for popover-style boxes (autocomplete, command
    /// suggestions): glass panel under liquid glass, the original flat
    /// background + hairline stroke under matrix.
    func themedOverlayPanel() -> some View {
        modifier(ThemedOverlayPanelModifier())
    }

    /// Root background for sheets — same backdrop as the main window so every
    /// surface speaks one visual language.
    func themedSheetBackground() -> some View {
        background(ThemedRootBackground())
    }

    /// Flat background wash for bars/headers inside sheets. Matrix keeps its
    /// opaque wash; glass goes transparent so the backdrop gradient shows.
    func themedSurface(opacity: Double = 1.0) -> some View {
        modifier(ThemedSurfaceModifier(opacity: opacity))
    }
}

private struct ThemedSurfaceModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette
    let opacity: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.usesGlassChrome {
            content
        } else {
            content.background(palette.background.opacity(opacity))
        }
    }
}

private struct ThemedOverlayPanelModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.usesGlassChrome {
            content.modifier(GlassPanel(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)))
        } else {
            content
                .background(palette.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(palette.secondary.opacity(0.3), lineWidth: 1)
                )
        }
    }
}
