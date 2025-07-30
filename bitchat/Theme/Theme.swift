//
// Theme.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct BitchatTheme: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String
    
    // Background colors
    var backgroundColor: CodableColor
    var secondaryBackgroundColor: CodableColor
    
    // Text colors
    var primaryTextColor: CodableColor
    var secondaryTextColor: CodableColor
    var systemTextColor: CodableColor
    
    // Accent colors
    var accentColor: CodableColor
    var mentionColor: CodableColor
    var hashtagColor: CodableColor
    
    // Signal strength colors
    var excellentSignalColor: CodableColor
    var goodSignalColor: CodableColor
    var fairSignalColor: CodableColor
    var weakSignalColor: CodableColor
    var poorSignalColor: CodableColor
    
    // Additional UI colors
    var dividerColor: CodableColor
    var unreadMessageColor: CodableColor
    var favoriteColor: CodableColor
    
    // Whether this theme respects system appearance
    var followsSystemAppearance: Bool
}

// Helper struct to make Color codable
struct CodableColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    
    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    
    init(_ color: Color) {
        // This is a simplified approach - in practice you might want more sophisticated color extraction
        if let components = color.cgColor?.components {
            self.red = Double(components[0])
            self.green = Double(components[1])
            self.blue = Double(components[2])
            self.alpha = components.count > 3 ? Double(components[3]) : 1.0
        } else {
            self.red = 0
            self.green = 0
            self.blue = 0
            self.alpha = 1.0
        }
    }
    
    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension BitchatTheme {
    // System Auto theme - respects system light/dark mode
    static let systemAuto = BitchatTheme(
        id: "system_auto",
        name: "Auto",
        description: "Follows system appearance",
        backgroundColor: CodableColor(red: 0, green: 0, blue: 0, alpha: 1), // Will be overridden by system
        secondaryBackgroundColor: CodableColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.95),
        primaryTextColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 1), // Classic green
        secondaryTextColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 0.8),
        systemTextColor: CodableColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
        accentColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 1),
        mentionColor: CodableColor(red: 1, green: 0.6, blue: 0, alpha: 1),
        hashtagColor: CodableColor(red: 0.3, green: 0.7, blue: 1, alpha: 1),
        excellentSignalColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 1),
        goodSignalColor: CodableColor(red: 0.5, green: 1, blue: 0, alpha: 1),
        fairSignalColor: CodableColor(red: 1, green: 1, blue: 0, alpha: 1),
        weakSignalColor: CodableColor(red: 1, green: 0.6, blue: 0, alpha: 1),
        poorSignalColor: CodableColor(red: 1, green: 0.2, blue: 0.2, alpha: 1),
        dividerColor: CodableColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1),
        unreadMessageColor: CodableColor(red: 1, green: 0.6, blue: 0, alpha: 1),
        favoriteColor: CodableColor(red: 1, green: 0.8, blue: 0, alpha: 1),
        followsSystemAppearance: true
    )
    
    // Classic Light theme
    static let classicLight = BitchatTheme(
        id: "classic_light",
        name: "Light",
        description: "Classic light terminal look",
        backgroundColor: CodableColor(red: 1, green: 1, blue: 1, alpha: 1),
        secondaryBackgroundColor: CodableColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 0.95),
        primaryTextColor: CodableColor(red: 0, green: 0.5, blue: 0, alpha: 1),
        secondaryTextColor: CodableColor(red: 0, green: 0.5, blue: 0, alpha: 0.8),
        systemTextColor: CodableColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1),
        accentColor: CodableColor(red: 0, green: 0.5, blue: 0, alpha: 1),
        mentionColor: CodableColor(red: 0.8, green: 0.4, blue: 0, alpha: 1),
        hashtagColor: CodableColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
        excellentSignalColor: CodableColor(red: 0, green: 0.7, blue: 0, alpha: 1),
        goodSignalColor: CodableColor(red: 0.3, green: 0.7, blue: 0, alpha: 1),
        fairSignalColor: CodableColor(red: 0.7, green: 0.7, blue: 0, alpha: 1),
        weakSignalColor: CodableColor(red: 0.8, green: 0.4, blue: 0, alpha: 1),
        poorSignalColor: CodableColor(red: 0.8, green: 0, blue: 0, alpha: 1),
        dividerColor: CodableColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1),
        unreadMessageColor: CodableColor(red: 0.8, green: 0.4, blue: 0, alpha: 1),
        favoriteColor: CodableColor(red: 0.9, green: 0.7, blue: 0, alpha: 1),
        followsSystemAppearance: false
    )
    
    // Classic Dark theme
    static let classicDark = BitchatTheme(
        id: "classic_dark",
        name: "Dark",
        description: "Classic dark terminal look",
        backgroundColor: CodableColor(red: 0, green: 0, blue: 0, alpha: 1),
        secondaryBackgroundColor: CodableColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.95),
        primaryTextColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 1),
        secondaryTextColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 0.8),
        systemTextColor: CodableColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
        accentColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 1),
        mentionColor: CodableColor(red: 1, green: 0.6, blue: 0, alpha: 1),
        hashtagColor: CodableColor(red: 0.3, green: 0.7, blue: 1, alpha: 1),
        excellentSignalColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 1),
        goodSignalColor: CodableColor(red: 0.5, green: 1, blue: 0, alpha: 1),
        fairSignalColor: CodableColor(red: 1, green: 1, blue: 0, alpha: 1),
        weakSignalColor: CodableColor(red: 1, green: 0.6, blue: 0, alpha: 1),
        poorSignalColor: CodableColor(red: 1, green: 0.2, blue: 0.2, alpha: 1),
        dividerColor: CodableColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1),
        unreadMessageColor: CodableColor(red: 1, green: 0.6, blue: 0, alpha: 1),
        favoriteColor: CodableColor(red: 1, green: 0.8, blue: 0, alpha: 1),
        followsSystemAppearance: false
    )
    
    // Cyberpunk theme
    static let cyberpunk = BitchatTheme(
        id: "cyberpunk",
        name: "Cyberpunk",
        description: "Neon pink and cyan aesthetic",
        backgroundColor: CodableColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1),
        secondaryBackgroundColor: CodableColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 0.95),
        primaryTextColor: CodableColor(red: 1, green: 0.2, blue: 0.8, alpha: 1), // Hot pink
        secondaryTextColor: CodableColor(red: 1, green: 0.2, blue: 0.8, alpha: 0.8),
        systemTextColor: CodableColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1),
        accentColor: CodableColor(red: 0, green: 1, blue: 1, alpha: 1), // Cyan
        mentionColor: CodableColor(red: 1, green: 0.8, blue: 0, alpha: 1),
        hashtagColor: CodableColor(red: 0, green: 1, blue: 1, alpha: 1),
        excellentSignalColor: CodableColor(red: 0, green: 1, blue: 1, alpha: 1),
        goodSignalColor: CodableColor(red: 0.5, green: 1, blue: 0.8, alpha: 1),
        fairSignalColor: CodableColor(red: 1, green: 1, blue: 0.2, alpha: 1),
        weakSignalColor: CodableColor(red: 1, green: 0.6, blue: 0.2, alpha: 1),
        poorSignalColor: CodableColor(red: 1, green: 0.2, blue: 0.8, alpha: 1),
        dividerColor: CodableColor(red: 0.3, green: 0.1, blue: 0.4, alpha: 1),
        unreadMessageColor: CodableColor(red: 1, green: 0.8, blue: 0, alpha: 1),
        favoriteColor: CodableColor(red: 1, green: 0.2, blue: 0.8, alpha: 1),
        followsSystemAppearance: false
    )
    
    // Ocean theme
    static let ocean = BitchatTheme(
        id: "ocean",
        name: "Ocean",
        description: "Deep blue and teal colors",
        backgroundColor: CodableColor(red: 0.05, green: 0.1, blue: 0.2, alpha: 1),
        secondaryBackgroundColor: CodableColor(red: 0.1, green: 0.15, blue: 0.25, alpha: 0.95),
        primaryTextColor: CodableColor(red: 0.2, green: 0.8, blue: 1, alpha: 1), // Light blue
        secondaryTextColor: CodableColor(red: 0.2, green: 0.8, blue: 1, alpha: 0.8),
        systemTextColor: CodableColor(red: 0.4, green: 0.6, blue: 0.7, alpha: 1),
        accentColor: CodableColor(red: 0, green: 0.8, blue: 0.8, alpha: 1), // Teal
        mentionColor: CodableColor(red: 1, green: 0.7, blue: 0.3, alpha: 1),
        hashtagColor: CodableColor(red: 0.3, green: 1, blue: 0.7, alpha: 1),
        excellentSignalColor: CodableColor(red: 0, green: 1, blue: 0.8, alpha: 1),
        goodSignalColor: CodableColor(red: 0.2, green: 0.9, blue: 0.9, alpha: 1),
        fairSignalColor: CodableColor(red: 0.8, green: 0.9, blue: 0.3, alpha: 1),
        weakSignalColor: CodableColor(red: 1, green: 0.6, blue: 0.2, alpha: 1),
        poorSignalColor: CodableColor(red: 1, green: 0.3, blue: 0.3, alpha: 1),
        dividerColor: CodableColor(red: 0.2, green: 0.4, blue: 0.5, alpha: 1),
        unreadMessageColor: CodableColor(red: 1, green: 0.7, blue: 0.3, alpha: 1),
        favoriteColor: CodableColor(red: 1, green: 0.8, blue: 0.2, alpha: 1),
        followsSystemAppearance: false
    )
    
    static let allThemes: [BitchatTheme] = [
        .systemAuto,
        .classicLight,
        .classicDark,
        .cyberpunk,
        .ocean
    ]
    
    // Create a new custom theme
    static func createCustomTheme() -> BitchatTheme {
        return BitchatTheme(
            id: "custom_\(UUID().uuidString)",
            name: "Custom Theme",
            description: "Your custom theme",
            backgroundColor: CodableColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
            secondaryBackgroundColor: CodableColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 0.95),
            primaryTextColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 1),
            secondaryTextColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 0.8),
            systemTextColor: CodableColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
            accentColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 1),
            mentionColor: CodableColor(red: 1, green: 0.6, blue: 0, alpha: 1),
            hashtagColor: CodableColor(red: 0.3, green: 0.7, blue: 1, alpha: 1),
            excellentSignalColor: CodableColor(red: 0, green: 1, blue: 0, alpha: 1),
            goodSignalColor: CodableColor(red: 0.5, green: 1, blue: 0, alpha: 1),
            fairSignalColor: CodableColor(red: 1, green: 1, blue: 0, alpha: 1),
            weakSignalColor: CodableColor(red: 1, green: 0.6, blue: 0, alpha: 1),
            poorSignalColor: CodableColor(red: 1, green: 0.2, blue: 0.2, alpha: 1),
            dividerColor: CodableColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1),
            unreadMessageColor: CodableColor(red: 1, green: 0.6, blue: 0, alpha: 1),
            favoriteColor: CodableColor(red: 1, green: 0.8, blue: 0, alpha: 1),
            followsSystemAppearance: false
        )
    }
} 