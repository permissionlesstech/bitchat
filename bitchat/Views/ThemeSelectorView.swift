//
// ThemeSelectorView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct ThemeSelectorView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 4) {
                Image(systemName: "paintbrush.fill")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                Text("THEMES")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundColor(themeManager.secondaryTextColor(for: colorScheme))
            .padding(.horizontal, 12)
            
            // Theme list
            VStack(spacing: 8) {
                ForEach(themeManager.getAllThemes()) { theme in
                    ThemePreviewCard(
                        theme: theme,
                        isSelected: themeManager.selectedTheme.id == theme.id
                    ) {
                        themeManager.selectTheme(theme)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

struct ThemePreviewCard: View {
    let theme: BitchatTheme
    let isSelected: Bool
    let onSelect: () -> Void
    
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var themeManager: ThemeManager
    
    private var previewBackgroundColor: Color {
        if theme.followsSystemAppearance {
            return colorScheme == .dark ? Color.black : Color.white
        }
        return theme.backgroundColor.color
    }
    
    private var previewTextColor: Color {
        if theme.followsSystemAppearance {
            return colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        }
        return theme.primaryTextColor.color
    }
    
    private var previewAccentColor: Color {
        if theme.followsSystemAppearance {
            return colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        }
        return theme.accentColor.color
    }
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Theme preview
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        // Mini color swatches
                        RoundedRectangle(cornerRadius: 2)
                            .fill(previewBackgroundColor)
                            .frame(width: 8, height: 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(previewTextColor.opacity(0.3), lineWidth: 0.5)
                            )
                        
                        RoundedRectangle(cornerRadius: 2)
                            .fill(previewTextColor)
                            .frame(width: 8, height: 8)
                        
                        RoundedRectangle(cornerRadius: 2)
                            .fill(previewAccentColor)
                            .frame(width: 8, height: 8)
                    }
                    
                    // Mini terminal preview
                    RoundedRectangle(cornerRadius: 3)
                        .fill(previewBackgroundColor)
                        .frame(width: 32, height: 16)
                        .overlay(
                            VStack(spacing: 1) {
                                HStack {
                                    Circle()
                                        .fill(previewTextColor)
                                        .frame(width: 2, height: 2)
                                    Rectangle()
                                        .fill(previewTextColor.opacity(0.6))
                                        .frame(width: 8, height: 1)
                                    Spacer()
                                }
                                HStack {
                                    Rectangle()
                                        .fill(previewAccentColor)
                                        .frame(width: 6, height: 1)
                                    Rectangle()
                                        .fill(previewTextColor.opacity(0.4))
                                        .frame(width: 4, height: 1)
                                    Spacer()
                                }
                                Spacer()
                            }
                            .padding(2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(previewTextColor.opacity(0.2), lineWidth: 0.5)
                        )
                }
                
                // Theme info
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(theme.name)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(themeManager.primaryTextColor(for: colorScheme))
                        
                        Spacer()
                        
                        // Removed settings icon for auto theme
                    }
                    
                    Text(theme.description)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(themeManager.secondaryTextColor(for: colorScheme))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected ? 
                        themeManager.accentColor(for: colorScheme).opacity(0.1) :
                        themeManager.secondaryBackgroundColor(for: colorScheme).opacity(0.3)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? 
                        themeManager.accentColor(for: colorScheme).opacity(0.5) :
                        themeManager.dividerColor(for: colorScheme).opacity(0.3),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityHint(theme.description)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    VStack {
        ThemeSelectorView()
            .environmentObject(ThemeManager())
            .padding()
    }
    .background(Color.black)
} 