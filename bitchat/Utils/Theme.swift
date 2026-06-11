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

    var id: String { rawValue }

    /// UserDefaults key backing the theme selection.
    static let storageKey = "appTheme"

    /// Resolves the semantic color palette for this theme under the given color scheme.
    func palette(for colorScheme: ColorScheme) -> ThemePalette {
        switch self {
        case .matrix:
            return .matrix(colorScheme)
        }
    }
}

/// Semantic colors for the active theme, resolved against the current color scheme.
/// Views should consume these via `@ThemePalette` rather than computing colors inline.
struct ThemePalette {
    /// Primary window/sheet background.
    let background: Color
    /// Primary text and accent color.
    let primary: Color
    /// De-emphasized text (timestamps, hints, captions).
    let secondary: Color
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
            accentBlue: Color(red: 0.0, green: 0.478, blue: 1.0),
            alertRed: Color(red: 0.75, green: 0.1, blue: 0.1),
            divider: isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
        )
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
