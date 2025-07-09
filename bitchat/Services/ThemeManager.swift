//
// ThemeManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    
    @Published var isDarkMode: Bool {
        didSet {
            UserDefaults.standard.set(isDarkMode, forKey: "bitchat.isDarkMode")
        }
    }
    
    private init() {
        self.isDarkMode = UserDefaults.standard.bool(forKey: "bitchat.isDarkMode")
    }
    
    // MARK: - Cursor IDE-inspired colors with neon accents
    
    // Main background colors - not too black, like Cursor IDE
    var backgroundColor: Color {
        isDarkMode ? Color(hex: "1E1E1E") : Color.white
    }
    
    var secondaryBackgroundColor: Color {
        isDarkMode ? Color(hex: "252526") : Color(hex: "F5F5F5")
    }
    
    var tertiaryBackgroundColor: Color {
        isDarkMode ? Color(hex: "2D2D30") : Color(hex: "EBEBEB")
    }
    
    // Text colors
    var primaryTextColor: Color {
        isDarkMode ? Color(hex: "CCCCCC") : Color(hex: "1E1E1E")
    }
    
    var secondaryTextColor: Color {
        isDarkMode ? Color(hex: "999999") : Color(hex: "6E6E6E")
    }
    
    // Neon accent colors
    var neonGreen: Color {
        Color(hex: "00FF88")
    }
    
    var neonBlue: Color {
        Color(hex: "00D9FF")
    }
    
    var neonPurple: Color {
        Color(hex: "BD93F9")
    }
    
    var neonPink: Color {
        Color(hex: "FF79C6")
    }
    
    var neonYellow: Color {
        Color(hex: "F1FA8C")
    }
    
    var neonOrange: Color {
        Color(hex: "FFB86C")
    }
    
    // UI Element colors
    var dividerColor: Color {
        isDarkMode ? Color(hex: "3E3E42") : Color(hex: "E5E5E7")
    }
    
    var toggleTintColor: Color {
        isDarkMode ? neonBlue : Color.blue
    }
    
    // Message colors
    var systemMessageColor: Color {
        isDarkMode ? Color(hex: "858585") : Color(hex: "8E8E93")
    }
    
    var senderColor: Color {
        isDarkMode ? neonGreen : Color(red: 0, green: 0.7, blue: 0)
    }
    
    var timestampColor: Color {
        isDarkMode ? Color(hex: "6E6E73") : Color(hex: "8E8E93")
    }
    
    var mentionBackgroundColor: Color {
        isDarkMode ? neonPurple.opacity(0.2) : Color.purple.opacity(0.1)
    }
    
    var mentionTextColor: Color {
        isDarkMode ? neonPurple : Color.purple
    }
    
    var linkColor: Color {
        isDarkMode ? neonBlue : Color.blue
    }
    
    var privateMessageColor: Color {
        isDarkMode ? neonOrange : Color.orange
    }
    
    var channelColor: Color {
        isDarkMode ? neonBlue : Color.blue
    }
    
    var favoriteColor: Color {
        isDarkMode ? neonYellow : Color.yellow
    }
    
    var errorColor: Color {
        Color.red
    }
    
    // Button and interactive element colors
    var buttonBackgroundColor: Color {
        isDarkMode ? Color(hex: "3E3E42") : Color(hex: "E5E5E7")
    }
    
    var buttonHoverColor: Color {
        isDarkMode ? Color(hex: "4E4E52") : Color(hex: "D5D5D7")
    }
    
    // Toggle theme
    func toggleTheme() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isDarkMode.toggle()
        }
    }
}

// MARK: - Color Extension for Hex Support
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
} 