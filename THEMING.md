# BitChat Theming System

BitChat includes a flexible theming system that allows users to customize the appearance of the app. This document explains how to add new themes to the system.

## Overview

The theming system consists of three main components:

1. **`BitchatTheme`** - Defines the color scheme and properties for a theme
2. **`ThemeManager`** - Manages theme selection, persistence, and color access
3. **`ThemeSelectorView`** - Provides the UI for theme selection

## Adding a New Theme

### Step 1: Define Your Theme

Add your new theme as a static property in the `BitchatTheme` struct in `bitchat/Theme/Theme.swift`:

```swift
static let yourThemeName = BitchatTheme(
    id: "your_theme_id",
    name: "Your Theme Name",
    description: "Brief description of your theme",
    followsSystemAppearance: false, // Set to true for system-following themes
    
    // Core colors
    backgroundColor: ThemeColor(red: 0.1, green: 0.1, blue: 0.1),
    secondaryBackgroundColor: ThemeColor(red: 0.15, green: 0.15, blue: 0.15),
    primaryTextColor: ThemeColor(red: 1.0, green: 1.0, blue: 1.0),
    secondaryTextColor: ThemeColor(red: 0.8, green: 0.8, blue: 0.8),
    systemTextColor: ThemeColor(red: 0.6, green: 0.6, blue: 0.6),
    
    // Accent colors
    accentColor: ThemeColor(red: 0.0, green: 0.8, blue: 1.0),
    mentionColor: ThemeColor(red: 1.0, green: 0.6, blue: 0.0),
    hashtagColor: ThemeColor(red: 0.4, green: 0.8, blue: 1.0),
    
    // UI elements
    dividerColor: ThemeColor(red: 0.3, green: 0.3, blue: 0.3),
    unreadMessageColor: ThemeColor(red: 1.0, green: 0.4, blue: 0.0),
    favoriteColor: ThemeColor(red: 1.0, green: 0.8, blue: 0.0),
    
    // Signal strength colors (RSSI-based)
    excellentSignalColor: ThemeColor(red: 0.0, green: 1.0, blue: 0.0),
    goodSignalColor: ThemeColor(red: 0.6, green: 1.0, blue: 0.0),
    fairSignalColor: ThemeColor(red: 1.0, green: 1.0, blue: 0.0),
    weakSignalColor: ThemeColor(red: 1.0, green: 0.6, blue: 0.0),
    poorSignalColor: ThemeColor(red: 1.0, green: 0.0, blue: 0.0)
)
```

### Step 2: Register Your Theme

Add your theme to the `allThemes` array in the same file:

```swift
static let allThemes: [BitchatTheme] = [
    .systemAuto,
    .classicLight,
    .classicDark,
    .cyberpunk,
    .ocean,
    .yourThemeName  // Add your theme here
]
```

### Step 3: Test Your Theme

1. Build and run the app: `just dev-run`
2. Open the sidebar and navigate to the THEMES section
3. Your new theme should appear in the list
4. Click on it to test the color scheme
5. Verify all UI elements look good with your colors

## Theme Properties Reference

### Core Colors

- **`backgroundColor`** - Main app background
- **`secondaryBackgroundColor`** - Secondary surfaces (cards, panels)
- **`primaryTextColor`** - Main text color
- **`secondaryTextColor`** - Dimmed text, timestamps
- **`systemTextColor`** - System messages, status text

### Accent Colors

- **`accentColor`** - Primary accent (buttons, selections, highlights)
- **`mentionColor`** - @mention highlighting
- **`hashtagColor`** - #hashtag highlighting

### UI Elements

- **`dividerColor`** - Separators, borders
- **`unreadMessageColor`** - Unread message indicators
- **`favoriteColor`** - Favorite channel indicators

### Signal Strength Colors

These colors are used to indicate Bluetooth signal strength:

- **`excellentSignalColor`** - RSSI ≥ -50 dBm
- **`goodSignalColor`** - RSSI -50 to -60 dBm  
- **`fairSignalColor`** - RSSI -60 to -70 dBm
- **`weakSignalColor`** - RSSI -70 to -80 dBm
- **`poorSignalColor`** - RSSI < -80 dBm

## Color Format

Colors are defined using the `ThemeColor` struct with RGB values from 0.0 to 1.0:

```swift
ThemeColor(red: 1.0, green: 0.5, blue: 0.0)  // Orange
```

### Common Color Values

- **Black**: `ThemeColor(red: 0.0, green: 0.0, blue: 0.0)`
- **White**: `ThemeColor(red: 1.0, green: 1.0, blue: 1.0)`
- **Terminal Green**: `ThemeColor(red: 0.0, green: 1.0, blue: 0.0)`
- **Dark Green**: `ThemeColor(red: 0.0, green: 0.5, blue: 0.0)`

## System-Following Themes

To create a theme that adapts to the system's light/dark mode:

1. Set `followsSystemAppearance: true`
2. The colors will be automatically adjusted based on system appearance
3. The `ThemeManager` handles the logic for system-following themes

## Theme Design Guidelines

### Contrast
- Ensure sufficient contrast between text and background colors
- Test in both bright and dim lighting conditions
- Consider accessibility guidelines (WCAG 2.1)

### Terminal Aesthetic
- BitChat has a terminal/retro aesthetic
- Monospaced fonts are used throughout
- Consider classic terminal color schemes for inspiration

### Signal Colors
- Use intuitive colors for signal strength (green = good, red = poor)
- Maintain consistency with the overall theme palette
- Ensure signal colors are distinguishable from each other

## Example Themes

### Minimal Dark Theme
```swift
static let minimal = BitchatTheme(
    id: "minimal",
    name: "Minimal",
    description: "Clean and minimal dark theme",
    followsSystemAppearance: false,
    backgroundColor: ThemeColor(red: 0.05, green: 0.05, blue: 0.05),
    secondaryBackgroundColor: ThemeColor(red: 0.1, green: 0.1, blue: 0.1),
    primaryTextColor: ThemeColor(red: 0.9, green: 0.9, blue: 0.9),
    secondaryTextColor: ThemeColor(red: 0.6, green: 0.6, blue: 0.6),
    systemTextColor: ThemeColor(red: 0.5, green: 0.5, blue: 0.5),
    accentColor: ThemeColor(red: 0.3, green: 0.3, blue: 0.3),
    mentionColor: ThemeColor(red: 0.7, green: 0.7, blue: 0.7),
    hashtagColor: ThemeColor(red: 0.5, green: 0.5, blue: 0.5),
    dividerColor: ThemeColor(red: 0.2, green: 0.2, blue: 0.2),
    unreadMessageColor: ThemeColor(red: 0.8, green: 0.8, blue: 0.8),
    favoriteColor: ThemeColor(red: 0.6, green: 0.6, blue: 0.6),
    excellentSignalColor: ThemeColor(red: 0.8, green: 0.8, blue: 0.8),
    goodSignalColor: ThemeColor(red: 0.7, green: 0.7, blue: 0.7),
    fairSignalColor: ThemeColor(red: 0.6, green: 0.6, blue: 0.6),
    weakSignalColor: ThemeColor(red: 0.5, green: 0.5, blue: 0.5),
    poorSignalColor: ThemeColor(red: 0.4, green: 0.4, blue: 0.4)
)
```

### Retro Amber Theme
```swift
static let retroAmber = BitchatTheme(
    id: "retro_amber",
    name: "Retro Amber",
    description: "Classic amber terminal theme",
    followsSystemAppearance: false,
    backgroundColor: ThemeColor(red: 0.0, green: 0.0, blue: 0.0),
    secondaryBackgroundColor: ThemeColor(red: 0.05, green: 0.05, blue: 0.0),
    primaryTextColor: ThemeColor(red: 1.0, green: 0.75, blue: 0.0),
    secondaryTextColor: ThemeColor(red: 0.8, green: 0.6, blue: 0.0),
    systemTextColor: ThemeColor(red: 0.6, green: 0.45, blue: 0.0),
    accentColor: ThemeColor(red: 1.0, green: 0.75, blue: 0.0),
    mentionColor: ThemeColor(red: 1.0, green: 0.9, blue: 0.2),
    hashtagColor: ThemeColor(red: 1.0, green: 0.8, blue: 0.1),
    dividerColor: ThemeColor(red: 0.3, green: 0.225, blue: 0.0),
    unreadMessageColor: ThemeColor(red: 1.0, green: 0.5, blue: 0.0),
    favoriteColor: ThemeColor(red: 1.0, green: 0.9, blue: 0.0),
    excellentSignalColor: ThemeColor(red: 1.0, green: 0.9, blue: 0.0),
    goodSignalColor: ThemeColor(red: 1.0, green: 0.8, blue: 0.0),
    fairSignalColor: ThemeColor(red: 1.0, green: 0.7, blue: 0.0),
    weakSignalColor: ThemeColor(red: 1.0, green: 0.6, blue: 0.0),
    poorSignalColor: ThemeColor(red: 1.0, green: 0.4, blue: 0.0)
)
```

## Testing Checklist

When adding a new theme, test these elements:

- [ ] Sidebar readability
- [ ] Message text readability  
- [ ] Timestamp and metadata visibility
- [ ] @mention highlighting
- [ ] #hashtag highlighting
- [ ] Button and accent colors
- [ ] Signal strength indicators
- [ ] System messages
- [ ] Dividers and separators
- [ ] Theme preview in selector
- [ ] Light and dark environment compatibility

## File Structure

```
bitchat/
└── Theme/
    ├── Theme.swift          # Theme definitions
    ├── ThemeManager.swift   # Theme management logic
    └── ThemeSelectorView.swift  # Theme selection UI
```

## Best Practices

1. **Unique IDs**: Use descriptive, unique IDs for themes
2. **Clear Names**: Choose clear, memorable names
3. **Good Descriptions**: Write helpful descriptions for users
4. **Test Thoroughly**: Test your theme in various lighting conditions
5. **Consider Accessibility**: Ensure good contrast ratios
6. **Be Consistent**: Follow the app's design language
7. **Document Colors**: Comment complex color choices

## Troubleshooting

### Theme Not Appearing
- Check that the theme is added to `allThemes` array
- Verify the theme ID is unique
- Ensure the build completed successfully

### Colors Not Working
- Verify RGB values are between 0.0 and 1.0
- Check for typos in property names
- Test with a simple color first (e.g., pure red)

### Preview Issues
- The preview uses a simplified version of your colors
- Test the actual app to see the full theme
- Preview adapts to current system appearance for system themes

## Contributing

When contributing new themes:

1. Follow the existing code style
2. Test thoroughly on different screen sizes
3. Consider users with visual impairments
4. Provide clear documentation for your theme
5. Submit themes that offer distinct visual experiences

For questions or issues with the theming system, please refer to the main BitChat documentation or create an issue in the repository. 