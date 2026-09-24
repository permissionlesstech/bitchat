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
    case nord
    case dracula
    case solarizedDark
    case tokyoNight
    case monochrome

    var id: String { rawValue }

    /// UserDefaults key backing the theme selection.
    static let storageKey = "appTheme"

    var displayNameKey: LocalizedStringKey {
        switch self {
        case .matrix: return "app_info.appearance.matrix"
        case .liquidGlass: return "app_info.appearance.liquid_glass"
        case .nord: return "app_info.appearance.nord"
        case .dracula: return "app_info.appearance.dracula"
        case .solarizedDark: return "app_info.appearance.solarized_dark"
        case .tokyoNight: return "app_info.appearance.tokyo_night"
        case .monochrome: return "app_info.appearance.monochrome"
        }
    }

    /// Font design used for themed text. Matrix keeps the terminal monospace;
    /// liquid glass uses the system default.
    var bodyFontDesign: Font.Design {
        switch self {
        case .matrix: return .monospaced
        case .liquidGlass: return .default
        case .nord: return .default
        case .dracula: return .monospaced
        case .solarizedDark: return .monospaced
        case .tokyoNight: return .default
        case .monochrome: return .default
        }
    }

    /// Whether chrome surfaces (header/composer bars, input field) render as
    /// translucent glass/material instead of the flat matrix background.
    var usesGlassChrome: Bool {
        switch self {
        case .liquidGlass: return true
        case .matrix, .nord, .dracula, .solarizedDark, .tokyoNight, .monochrome: return false
        }
    }

    /// Discriminator mixed into per-message formatting caches so cached
    /// AttributedStrings from one theme are never served under another.
    /// Empty for matrix to keep its historical cache keys.
    var formatCacheVariant: String {
        switch self {
        case .matrix: return ""
        case .liquidGlass: return "lg:"
        case .nord: return "nd:"
        case .dracula: return "dc:"
        case .solarizedDark: return "sd:"
        case .tokyoNight: return "tn:"
        case .monochrome: return "mc:"
        }
    }

    /// Resolves the semantic color palette for this theme under the given color scheme.
    func palette(for colorScheme: ColorScheme) -> ThemePalette {
        switch self {
        case .matrix: return .matrix(colorScheme)
        case .liquidGlass: return .liquidGlass(colorScheme)
        case .nord: return .nord(colorScheme)
        case .dracula: return .dracula(colorScheme)
        case .solarizedDark: return .solarizedDark(colorScheme)
        case .tokyoNight: return .tokyoNight(colorScheme)
        case .monochrome: return .monochrome(colorScheme)
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
    /// Location/geohash channel accent (badges, counts, subtitles).
    let locationAccent: Color
    /// Informational accent (links, read receipts, teleport markers).
    let accentBlue: Color
    /// Destructive/error accent.
    let alertRed: Color
    /// Hairline separators.
    let divider: Color

    static func matrix(_ colorScheme: ColorScheme) -> ThemePalette {
        let isDark = colorScheme == .dark
        let green = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        return ThemePalette(
            background: isDark ? Color.black : Color.white,
            primary: green,
            secondary: green.opacity(0.8),
            accent: green,
            locationAccent: green,
            accentBlue: Color(red: 0.0, green: 0.478, blue: 1.0),
            alertRed: Color(red: 0.75, green: 0.1, blue: 0.1),
            divider: isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
        )
    }

    static func liquidGlass(_: ColorScheme) -> ThemePalette {
        ThemePalette(
            background: systemBackground,
            primary: .primary,
            secondary: .secondary,
            accent: .blue,
            locationAccent: .green,
            accentBlue: .blue,
            alertRed: .red,
            divider: separator
        )
    }

    static func nord(_ colorScheme: ColorScheme) -> ThemePalette {
        let isDark = colorScheme == .dark
        return ThemePalette(
            background: isDark ? Color(red: 0.18, green: 0.20, blue: 0.25) : Color(red: 0.93, green: 0.94, blue: 0.96),
            primary: isDark ? Color(red: 0.93, green: 0.94, blue: 0.96) : Color(red: 0.18, green: 0.20, blue: 0.25),
            secondary: isDark ? Color(red: 0.61, green: 0.66, blue: 0.74) : Color(red: 0.30, green: 0.34, blue: 0.40),
            accent: isDark ? Color(red: 0.53, green: 0.75, blue: 0.82) : Color(red: 0.37, green: 0.51, blue: 0.67),
            locationAccent: isDark ? Color(red: 0.64, green: 0.75, blue: 0.55) : Color(red: 0.40, green: 0.55, blue: 0.31),
            accentBlue: isDark ? Color(red: 0.51, green: 0.63, blue: 0.76) : Color(red: 0.51, green: 0.63, blue: 0.76),
            alertRed: isDark ? Color(red: 0.75, green: 0.38, blue: 0.42) : Color(red: 0.75, green: 0.38, blue: 0.42),
            divider: isDark ? Color(red: 0.30, green: 0.34, blue: 0.40) : Color(red: 0.85, green: 0.87, blue: 0.91)
        )
    }

    static func dracula(_ colorScheme: ColorScheme) -> ThemePalette {
        let isDark = colorScheme == .dark
        return ThemePalette(
            background: isDark ? Color(red: 0.16, green: 0.16, blue: 0.21) : Color(red: 0.97, green: 0.97, blue: 0.95),
            primary: isDark ? Color(red: 0.97, green: 0.97, blue: 0.95) : Color(red: 0.16, green: 0.16, blue: 0.21),
            secondary: isDark ? Color(red: 0.38, green: 0.45, blue: 0.64) : Color(red: 0.38, green: 0.45, blue: 0.64),
            accent: isDark ? Color(red: 1.0, green: 0.47, blue: 0.78) : Color(red: 0.80, green: 0.28, blue: 0.56),
            locationAccent: isDark ? Color(red: 0.31, green: 0.98, blue: 0.48) : Color(red: 0.22, green: 0.60, blue: 0.33),
            accentBlue: isDark ? Color(red: 0.55, green: 0.91, blue: 0.99) : Color(red: 0.27, green: 0.73, blue: 0.83),
            alertRed: isDark ? Color(red: 1.0, green: 0.33, blue: 0.33) : Color(red: 0.82, green: 0.18, blue: 0.18),
            divider: isDark ? Color(red: 0.27, green: 0.28, blue: 0.35) : Color(red: 0.88, green: 0.88, blue: 0.88)
        )
    }

    static func solarizedDark(_ colorScheme: ColorScheme) -> ThemePalette {
        let isDark = colorScheme == .dark
        return ThemePalette(
            background: isDark ? Color(red: 0.0, green: 0.17, blue: 0.21) : Color(red: 0.99, green: 0.96, blue: 0.89),
            primary: isDark ? Color(red: 0.51, green: 0.58, blue: 0.59) : Color(red: 0.40, green: 0.48, blue: 0.51),
            secondary: isDark ? Color(red: 0.40, green: 0.48, blue: 0.51) : Color(red: 0.51, green: 0.58, blue: 0.59),
            accent: isDark ? Color(red: 0.16, green: 0.63, blue: 0.60) : Color(red: 0.16, green: 0.63, blue: 0.60),
            locationAccent: isDark ? Color(red: 0.52, green: 0.60, blue: 0.0) : Color(red: 0.52, green: 0.60, blue: 0.0),
            accentBlue: isDark ? Color(red: 0.15, green: 0.55, blue: 0.82) : Color(red: 0.15, green: 0.55, blue: 0.82),
            alertRed: isDark ? Color(red: 0.86, green: 0.20, blue: 0.18) : Color(red: 0.86, green: 0.20, blue: 0.18),
            divider: isDark ? Color(red: 0.03, green: 0.24, blue: 0.26) : Color(red: 0.93, green: 0.91, blue: 0.84)
        )
    }

    static func tokyoNight(_ colorScheme: ColorScheme) -> ThemePalette {
        let isDark = colorScheme == .dark
        return ThemePalette(
            background: isDark ? Color(red: 0.10, green: 0.11, blue: 0.15) : Color(red: 0.84, green: 0.84, blue: 0.86),
            primary: isDark ? Color(red: 0.66, green: 0.69, blue: 0.84) : Color(red: 0.22, green: 0.38, blue: 0.75),
            secondary: isDark ? Color(red: 0.47, green: 0.51, blue: 0.67) : Color(red: 0.36, green: 0.38, blue: 0.56),
            accent: isDark ? Color(red: 0.49, green: 0.81, blue: 1.0) : Color(red: 0.18, green: 0.49, blue: 0.91),
            locationAccent: isDark ? Color(red: 0.62, green: 0.81, blue: 0.42) : Color(red: 0.35, green: 0.46, blue: 0.22),
            accentBlue: isDark ? Color(red: 0.48, green: 0.64, blue: 0.97) : Color(red: 0.18, green: 0.49, blue: 0.91),
            alertRed: isDark ? Color(red: 0.97, green: 0.46, blue: 0.56) : Color(red: 0.78, green: 0.26, blue: 0.26),
            divider: isDark ? Color(red: 0.18, green: 0.24, blue: 0.39) : Color(red: 0.71, green: 0.71, blue: 0.77)
        )
    }

    static func monochrome(_ colorScheme: ColorScheme) -> ThemePalette {
        let isDark = colorScheme == .dark
        return ThemePalette(
            background: isDark ? .black : .white,
            primary: isDark ? .white : .black,
            secondary: isDark ? Color(white: 0.65) : Color(white: 0.40),
            accent: isDark ? .white : .black,
            locationAccent: isDark ? Color(white: 0.75) : Color(white: 0.25),
            accentBlue: isDark ? Color(white: 0.75) : Color(white: 0.25),
            alertRed: isDark ? Color(red: 0.82, green: 0.32, blue: 0.32) : Color(red: 0.72, green: 0.18, blue: 0.18),
            divider: isDark ? Color(white: 0.25) : Color(white: 0.80)
        )
    }

    private static var systemBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    private static var separator: Color {
        #if os(iOS)
        Color(UIColor.separator)
        #else
        Color(NSColor.separatorColor)
        #endif
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .matrix
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

/// Root backdrop. Matrix gets its flat background; glass gets a subtle static
/// gradient with a soft tinted glow — glass panels need visual texture behind
/// them to refract, and collapse to flat gray over a solid color.
struct ThemedRootBackground: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @ThemedPalette private var palette

    var body: some View {
        if theme.usesGlassChrome {
            let isDark = colorScheme == .dark
            ZStack {
                LinearGradient(
                    colors: isDark
                        ? [Color(red: 0.09, green: 0.10, blue: 0.15), Color(red: 0.04, green: 0.04, blue: 0.07)]
                        : [Color(red: 0.93, green: 0.95, blue: 1.0), Color(red: 0.98, green: 0.97, blue: 0.99)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [Color.blue.opacity(isDark ? 0.22 : 0.12), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 600
                )
                RadialGradient(
                    colors: [Color.purple.opacity(isDark ? 0.14 : 0.08), .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 500
                )
            }
            .ignoresSafeArea()
        } else {
            palette.background
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

/// Chrome surface for the header and composer. Matrix keeps the original flat
/// edge-to-edge wash; glass floats the content as an inset Liquid Glass panel
/// (content is expected to scroll underneath via safe-area insets).
private struct ThemedChromePanelModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette
    let edge: VerticalEdge

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.usesGlassChrome {
            content
                .modifier(GlassPanel(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
                .padding(.horizontal, 8)
                .padding(edge == .top ? .top : .bottom, 4)
        } else {
            content.background(palette.background.opacity(0.95))
        }
    }
}

/// Background for the composer input field. Matrix keeps its translucent fill;
/// glass leaves it clear — the field sits inside the composer's glass panel,
/// and glass cannot sample other glass.
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
