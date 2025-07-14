//
// ThemeManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import Combine

class ThemeManager: ObservableObject {
    @Published var selectedTheme: BitchatTheme = .systemAuto
    
    private let userDefaults = UserDefaults.standard
    private let themeKey = "bitchat.selectedTheme"
    
    init() {
        loadSelectedTheme()
    }
    
    private func loadSelectedTheme() {
        if let themeData = userDefaults.data(forKey: themeKey),
           let theme = try? JSONDecoder().decode(BitchatTheme.self, from: themeData) {
            selectedTheme = theme
        } else {
            // Default to system auto theme
            selectedTheme = .systemAuto
        }
    }
    
    func selectTheme(_ theme: BitchatTheme) {
        selectedTheme = theme
        saveSelectedTheme()
    }
    
    private func saveSelectedTheme() {
        if let themeData = try? JSONEncoder().encode(selectedTheme) {
            userDefaults.set(themeData, forKey: themeKey)
            userDefaults.synchronize()
        }
    }
    
    // MARK: - Color Accessors
    
    func backgroundColor(for colorScheme: ColorScheme) -> Color {
        if selectedTheme.followsSystemAppearance {
            return colorScheme == .dark ? Color.black : Color.white
        }
        return selectedTheme.backgroundColor.color
    }
    
    func secondaryBackgroundColor(for colorScheme: ColorScheme) -> Color {
        if selectedTheme.followsSystemAppearance {
            return colorScheme == .dark ? Color.black.opacity(0.95) : Color.white.opacity(0.95)
        }
        return selectedTheme.secondaryBackgroundColor.color
    }
    
    func primaryTextColor(for colorScheme: ColorScheme) -> Color {
        if selectedTheme.followsSystemAppearance {
            return colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        }
        return selectedTheme.primaryTextColor.color
    }
    
    func secondaryTextColor(for colorScheme: ColorScheme) -> Color {
        if selectedTheme.followsSystemAppearance {
            return colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
        }
        return selectedTheme.secondaryTextColor.color
    }
    
    func systemTextColor(for colorScheme: ColorScheme) -> Color {
        if selectedTheme.followsSystemAppearance {
            return Color.gray
        }
        return selectedTheme.systemTextColor.color
    }
    
    func accentColor(for colorScheme: ColorScheme) -> Color {
        if selectedTheme.followsSystemAppearance {
            return colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        }
        return selectedTheme.accentColor.color
    }
    
    func mentionColor(for colorScheme: ColorScheme) -> Color {
        if selectedTheme.followsSystemAppearance {
            return Color.orange
        }
        return selectedTheme.mentionColor.color
    }
    
    func hashtagColor(for colorScheme: ColorScheme) -> Color {
        if selectedTheme.followsSystemAppearance {
            return Color.blue
        }
        return selectedTheme.hashtagColor.color
    }
    
    func dividerColor(for colorScheme: ColorScheme) -> Color {
        if selectedTheme.followsSystemAppearance {
            return colorScheme == .dark ? Color.gray.opacity(0.3) : Color.gray.opacity(0.6)
        }
        return selectedTheme.dividerColor.color
    }
    
    func unreadMessageColor(for colorScheme: ColorScheme) -> Color {
        if selectedTheme.followsSystemAppearance {
            return Color.orange
        }
        return selectedTheme.unreadMessageColor.color
    }
    
    func favoriteColor(for colorScheme: ColorScheme) -> Color {
        if selectedTheme.followsSystemAppearance {
            return Color.yellow
        }
        return selectedTheme.favoriteColor.color
    }
    
    // MARK: - Signal Strength Colors
    
    func getRSSIColor(rssi: Int, colorScheme: ColorScheme) -> Color {
        let colors = selectedTheme.followsSystemAppearance ? 
            getSystemRSSIColors(colorScheme: colorScheme) : 
            getThemeRSSIColors()
        
        if rssi >= -50 {
            return colors.excellent
        } else if rssi >= -60 {
            return colors.good
        } else if rssi >= -70 {
            return colors.fair
        } else if rssi >= -80 {
            return colors.weak
        } else {
            return colors.poor
        }
    }
    
    private func getSystemRSSIColors(colorScheme: ColorScheme) -> (excellent: Color, good: Color, fair: Color, weak: Color, poor: Color) {
        let isDark = colorScheme == .dark
        return (
            excellent: isDark ? Color(red: 0.0, green: 1.0, blue: 0.0) : Color(red: 0.0, green: 0.7, blue: 0.0),
            good: isDark ? Color(red: 0.5, green: 1.0, blue: 0.0) : Color(red: 0.3, green: 0.7, blue: 0.0),
            fair: isDark ? Color(red: 1.0, green: 1.0, blue: 0.0) : Color(red: 0.7, green: 0.7, blue: 0.0),
            weak: isDark ? Color(red: 1.0, green: 0.6, blue: 0.0) : Color(red: 0.8, green: 0.4, blue: 0.0),
            poor: isDark ? Color(red: 1.0, green: 0.2, blue: 0.2) : Color(red: 0.8, green: 0.0, blue: 0.0)
        )
    }
    
    private func getThemeRSSIColors() -> (excellent: Color, good: Color, fair: Color, weak: Color, poor: Color) {
        return (
            excellent: selectedTheme.excellentSignalColor.color,
            good: selectedTheme.goodSignalColor.color,
            fair: selectedTheme.fairSignalColor.color,
            weak: selectedTheme.weakSignalColor.color,
            poor: selectedTheme.poorSignalColor.color
        )
    }
    
    // MARK: - Convenience Methods
    
    func isSystemTheme() -> Bool {
        return selectedTheme.followsSystemAppearance
    }
    
    func getCurrentThemeName() -> String {
        return selectedTheme.name
    }
    
    func getAllThemes() -> [BitchatTheme] {
        return BitchatTheme.allThemes
    }
} 