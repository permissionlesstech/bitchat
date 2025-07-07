import SwiftUI

struct ThemeManager {
    
    // MARK: - Color Definitions
    
    static func backgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    static func textColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    static func secondaryTextColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    // MARK: - Accent Colors
    
    static let privateMessageColor = Color.orange
    static let roomColor = Color.blue
    static let errorColor = Color.red
    static let warningColor = Color.yellow
    static let successColor = Color.green
    
    // MARK: - Utility Colors
    
    static func getRSSIColor(rssi: Int, colorScheme: ColorScheme) -> Color {
        let baseColor = textColor(for: colorScheme)
        
        if rssi > -50 {
            return baseColor  // Excellent
        } else if rssi > -70 {
            return baseColor.opacity(0.8)  // Good
        } else if rssi > -85 {
            return baseColor.opacity(0.6)  // Fair
        } else {
            return baseColor.opacity(0.3)  // Poor
        }
    }
    
    static func getSenderColor(for message: BitchatMessage, colorScheme: ColorScheme) -> Color {
        // Use a hash of the sender name to generate consistent colors
        let senderHash = abs(message.sender.hashValue)
        let colorIndex = senderHash % 6
        
        let colors: [Color] = [
            Color.blue,
            Color.purple,
            Color.orange,
            Color.pink,
            Color.cyan,
            Color.mint
        ]
        
        return colors[colorIndex]
    }
}

// MARK: - Environment Extension

extension EnvironmentValues {
    var themeColors: ThemeColors {
        ThemeColors(colorScheme: colorScheme)
    }
}

struct ThemeColors {
    let colorScheme: ColorScheme
    
    var backgroundColor: Color {
        ThemeManager.backgroundColor(for: colorScheme)
    }
    
    var textColor: Color {
        ThemeManager.textColor(for: colorScheme)
    }
    
    var secondaryTextColor: Color {
        ThemeManager.secondaryTextColor(for: colorScheme)
    }
}
