//
// IntelligentColorPicker.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if canImport(AppKit)
import AppKit

// Coordinator to sync NSColorPanel with SwiftUI
class ColorPanelCoordinator: ObservableObject {
    @Published var color: Color {
        didSet {
            if !isUpdatingFromPanel {
                NSColorPanel.shared.color = NSColor(color)
            }
        }
    }
    private var isUpdatingFromPanel = false
    private var observer: NSObjectProtocol?
    
    init(initialColor: Color) {
        self.color = initialColor
        observer = NotificationCenter.default.addObserver(forName: NSColorPanel.colorDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.isUpdatingFromPanel = true
            self.color = Color(NSColorPanel.shared.color)
            self.isUpdatingFromPanel = false
        }
    }
    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
#endif

struct IntelligentColorPicker: View {
    @Binding var color: CodableColor
    let propertyName: String
    
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.colorScheme) var colorScheme
    @State private var selectedColor = Color.white
#if canImport(AppKit)
    @StateObject private var colorPanelCoordinator = ColorPanelCoordinator(initialColor: .white)
#endif
    
    private var windowBackgroundColor: Color {
        themeManager.secondaryBackgroundColor(for: colorScheme)
    }
    
    private var controlBackgroundColor: Color {
        themeManager.backgroundColor(for: colorScheme)
    }
    
    // Smart color suggestions based on property type
    private var smartSuggestions: [Color] {
        switch propertyName {
        case "backgroundColor":
            return [
                Color.black, Color.white, Color(red: 0.1, green: 0.1, blue: 0.1),
                Color(red: 0.95, green: 0.95, blue: 0.95), Color(red: 0.05, green: 0.05, blue: 0.1)
            ]
        case "secondaryBackgroundColor":
            return [
                Color(red: 0.15, green: 0.15, blue: 0.15), Color(red: 0.9, green: 0.9, blue: 0.9),
                Color(red: 0.1, green: 0.1, blue: 0.15), Color(red: 0.97, green: 0.97, blue: 0.97)
            ]
        case "primaryTextColor":
            return [
                Color.green, Color(red: 0, green: 0.5, blue: 0), Color.white, Color.black,
                Color(red: 1, green: 0.2, blue: 0.8), Color(red: 0.2, green: 0.8, blue: 1)
            ]
        case "secondaryTextColor":
            return [
                Color.gray, Color(red: 0.5, green: 0.5, blue: 0.5), Color(red: 0.7, green: 0.7, blue: 0.7),
                Color(red: 0.3, green: 0.3, blue: 0.3), Color(red: 0.6, green: 0.6, blue: 0.6)
            ]
        case "accentColor":
            return [
                Color.green, Color.blue, Color.orange, Color.purple, Color.cyan,
                Color(red: 1, green: 0.2, blue: 0.8), Color(red: 0, green: 0.8, blue: 0.8)
            ]
        case "mentionColor":
            return [
                Color.orange, Color(red: 1, green: 0.6, blue: 0), Color(red: 1, green: 0.8, blue: 0),
                Color(red: 1, green: 0.4, blue: 0.2), Color(red: 0.8, green: 0.4, blue: 0)
            ]
        case "hashtagColor":
            return [
                Color.blue, Color(red: 0.3, green: 0.7, blue: 1), Color(red: 0.2, green: 0.4, blue: 0.8),
                Color(red: 0.3, green: 1, blue: 0.7), Color(red: 0, green: 1, blue: 1)
            ]
        case "excellentSignalColor":
            return [
                Color.green, Color(red: 0, green: 1, blue: 0), Color(red: 0, green: 0.7, blue: 0),
                Color(red: 0, green: 1, blue: 0.8), Color(red: 0.2, green: 0.8, blue: 0.2)
            ]
        case "goodSignalColor":
            return [
                Color(red: 0.5, green: 1, blue: 0), Color(red: 0.3, green: 0.7, blue: 0),
                Color(red: 0.2, green: 0.9, blue: 0.9), Color(red: 0.4, green: 0.8, blue: 0.4)
            ]
        case "fairSignalColor":
            return [
                Color.yellow, Color(red: 1, green: 1, blue: 0), Color(red: 0.7, green: 0.7, blue: 0),
                Color(red: 0.8, green: 0.9, blue: 0.3), Color(red: 1, green: 0.8, blue: 0.2)
            ]
        case "weakSignalColor":
            return [
                Color.orange, Color(red: 1, green: 0.6, blue: 0), Color(red: 0.8, green: 0.4, blue: 0),
                Color(red: 1, green: 0.6, blue: 0.2), Color(red: 0.9, green: 0.5, blue: 0.1)
            ]
        case "poorSignalColor":
            return [
                Color.red, Color(red: 1, green: 0.2, blue: 0.2), Color(red: 0.8, green: 0, blue: 0),
                Color(red: 1, green: 0.3, blue: 0.3), Color(red: 0.9, green: 0.1, blue: 0.1)
            ]
        case "dividerColor":
            return [
                Color.gray, Color(red: 0.3, green: 0.3, blue: 0.3), Color(red: 0.8, green: 0.8, blue: 0.8),
                Color(red: 0.2, green: 0.4, blue: 0.5), Color(red: 0.3, green: 0.1, blue: 0.4)
            ]
        case "unreadMessageColor":
            return [
                Color.orange, Color(red: 1, green: 0.6, blue: 0), Color(red: 0.8, green: 0.4, blue: 0),
                Color(red: 1, green: 0.7, blue: 0.3), Color(red: 0.9, green: 0.5, blue: 0.2)
            ]
        case "favoriteColor":
            return [
                Color.yellow, Color(red: 1, green: 0.8, blue: 0), Color(red: 0.9, green: 0.7, blue: 0),
                Color(red: 1, green: 0.9, blue: 0.2), Color(red: 0.8, green: 0.6, blue: 0.1)
            ]
        default:
            return [
                Color.black, Color.white, Color.gray, Color.red, Color.green, Color.blue,
                Color.yellow, Color.orange, Color.purple, Color.cyan
            ]
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("COLOR PICKER")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(themeManager.primaryTextColor(for: colorScheme))
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button("Done") {
                        updateColor()
                        dismiss()
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(themeManager.accentColor(for: colorScheme))
                    
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(themeManager.secondaryTextColor(for: colorScheme))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(windowBackgroundColor)
            
            // Divider
            Rectangle()
                .fill(themeManager.dividerColor(for: colorScheme))
                .frame(height: 1)
            
            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Current color preview
                    VStack(spacing: 12) {
                        Text("CURRENT COLOR")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(themeManager.secondaryTextColor(for: colorScheme))
                        
                        HStack(spacing: 16) {
                            // Custom color swatch/button
                            Button(action: {
#if canImport(AppKit)
                                NSColorPanel.shared.setTarget(nil)
                                NSColorPanel.shared.setAction(nil)
                                NSColorPanel.shared.color = NSColor(colorPanelCoordinator.color)
                                NSColorPanel.shared.makeKeyAndOrderFront(nil)
#endif
                            }) {
                                RoundedRectangle(cornerRadius: 8)
#if canImport(AppKit)
                                    .fill(colorPanelCoordinator.color)
#else
                                    .fill(selectedColor)
#endif
                                    .frame(width: 60, height: 60)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(themeManager.dividerColor(for: colorScheme), lineWidth: 1)
                                    )
                                    .shadow(color: themeManager.backgroundColor(for: colorScheme).opacity(0.08), radius: 2, x: 0, y: 1)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit color")
                            
                            // Small system color picker
#if canImport(AppKit)
                            ColorPicker("", selection: $colorPanelCoordinator.color, supportsOpacity: true)
                                .labelsHidden()
                                .frame(width: 32, height: 32)
#else
                            ColorPicker("", selection: $selectedColor, supportsOpacity: true)
                                .labelsHidden()
                                .frame(width: 32, height: 32)
#endif
                        }
                        
                        Text(propertyName.replacingOccurrences(of: "Color", with: "").capitalized)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(themeManager.primaryTextColor(for: colorScheme))
                    }
                    
                    // Smart suggestions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SUGGESTIONS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(themeManager.secondaryTextColor(for: colorScheme))
                    
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                            ForEach(smartSuggestions, id: \.self) { suggestionColor in
                                Button(action: {
                                    selectedColor = suggestionColor
                                    updateColor()
                                }) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(suggestionColor)
                                        .frame(height: 40)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(themeManager.dividerColor(for: colorScheme), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding(16)
            }
            .background(controlBackgroundColor)
        }
        .onAppear {
#if canImport(AppKit)
            colorPanelCoordinator.color = color.color
#else
            selectedColor = color.color
#endif
        }
        .onChange(of: selectedColor) { newValue in
#if !canImport(AppKit)
            color = CodableColor(newValue)
#endif
        }
#if canImport(AppKit)
        .onChange(of: colorPanelCoordinator.color) { newValue in
            color = CodableColor(newValue)
        }
#endif
    }
    
    private func updateColor() {
        color = CodableColor(selectedColor)
    }
}

// MARK: - System Color Picker View

struct SystemColorPickerView: View {
    @Binding var selectedColor: Color
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.colorScheme) var colorScheme
    
    private var windowBackgroundColor: Color {
        themeManager.secondaryBackgroundColor(for: colorScheme)
    }
    
    private var controlBackgroundColor: Color {
        themeManager.backgroundColor(for: colorScheme)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("ADVANCED COLOR PICKER")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(themeManager.primaryTextColor(for: colorScheme))
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(themeManager.accentColor(for: colorScheme))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(windowBackgroundColor)
            
            // Divider
            Rectangle()
                .fill(themeManager.dividerColor(for: colorScheme))
                .frame(height: 1)
            
            // Content
            VStack {
                ColorPicker("Select Color", selection: $selectedColor, supportsOpacity: true)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(themeManager.primaryTextColor(for: colorScheme))
                Spacer()
            }
            .padding(16)
            .background(controlBackgroundColor)
        }
    }
}

// MARK: - Color Harmony Helper

struct ColorHarmonyHelper {
    static func generateHarmoniousColors(baseColor: Color, count: Int = 5) -> [Color] {
        // This is a simplified color harmony generator
        // In a real implementation, you'd use HSL color space for better harmony
        
        var colors: [Color] = [baseColor]
        
        // Generate complementary and analogous colors
        if let components = baseColor.cgColor?.components, components.count >= 3 {
            let r = Double(components[0])
            let g = Double(components[1])
            let b = Double(components[2])
            
            // Complementary color
            let complementary = Color(red: 1 - r, green: 1 - g, blue: 1 - b)
            colors.append(complementary)
            
            // Analogous colors (shifted hues)
            let analogous1 = Color(red: min(1, r + 0.2), green: min(1, g + 0.1), blue: min(1, b + 0.1))
            let analogous2 = Color(red: max(0, r - 0.2), green: max(0, g - 0.1), blue: max(0, b - 0.1))
            colors.append(analogous1)
            colors.append(analogous2)
            
            // Triadic colors
            let triadic1 = Color(red: g, green: b, blue: r)
            let triadic2 = Color(red: b, green: r, blue: g)
            colors.append(triadic1)
            colors.append(triadic2)
        }
        
        return Array(colors.prefix(count))
    }
    
    static func isAccessible(textColor: Color, backgroundColor: Color) -> Bool {
        // Simplified contrast ratio calculation
        // In a real implementation, you'd use proper WCAG contrast calculations
        
        let textBrightness = getBrightness(textColor)
        let backgroundBrightness = getBrightness(backgroundColor)
        
        let contrastRatio = abs(textBrightness - backgroundBrightness)
        return contrastRatio > 0.3 // Simplified threshold
    }
    
    private static func getBrightness(_ color: Color) -> Double {
        if let components = color.cgColor?.components, components.count >= 3 {
            let r = Double(components[0])
            let g = Double(components[1])
            let b = Double(components[2])
            return (r * 0.299 + g * 0.587 + b * 0.114)
        }
        return 0.5
    }
}

#Preview {
    IntelligentColorPicker(
        color: .constant(CodableColor(red: 0, green: 1, blue: 0)),
        propertyName: "primaryTextColor"
    )
} 