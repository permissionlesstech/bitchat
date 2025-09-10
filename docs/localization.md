# Localization Guide

BitChat supports comprehensive internationalization with 29 languages, following Apple's modern best practices using the `.xcstrings` format.

## Supported Languages (29 Total)

### Major World Languages
- **English (en)** - Base language
- **Spanish (es)** - 500M+ speakers
- **Chinese Simplified (zh-Hans)** - 918M speakers
- **Chinese Traditional (zh-Hant)** - 75M speakers  
- **Chinese Hong Kong (zh-HK)** - 7M speakers
- **Hindi (hi)** - 600M+ speakers
- **Arabic (ar)** - 400M+ speakers
- **Portuguese (pt)** - 260M speakers
- **Brazilian Portuguese (pt-BR)** - 215M speakers
- **Bengali (bn)** - 300M speakers
- **Russian (ru)** - 258M speakers
- **Japanese (ja)** - 125M speakers
- **German (de)** - 100M speakers
- **French (fr)** - 280M speakers
- **Urdu (ur)** - 230M speakers
- **Turkish (tr)** - 80M speakers
- **Vietnamese (vi)** - 95M speakers
- **Indonesian (id)** - 270M speakers

### Regional & Cultural Languages
- **Egyptian Arabic (arz)** - 100M speakers
- **Filipino (fil)** - 45M speakers
- **Tagalog (tl)** - 45M speakers
- **Cantonese (yue)** - 85M speakers
- **Tamil (ta)** - 75M speakers
- **Telugu (te)** - 95M speakers
- **Marathi (mr)** - 83M speakers
- **Swahili (sw)** - 200M speakers
- **Hausa (ha)** - 70M speakers
- **Nigerian Pidgin (pcm)** - 75M speakers
- **Punjabi (pnb)** - 130M speakers

## File Structure

```
bitchat/
├── Localizable.xcstrings          # Single file containing all 29 languages
├── Utils/
│   └── Localization.swift         # Localization utility functions
└── */InfoPlist.strings            # Platform permission strings
```

## Development Workflow

### Adding New Localizable Strings

1. **Never use hardcoded strings in UI code:**
   ```swift
   // ❌ Wrong
   Button("Save") { ... }
   
   // ✅ Correct  
   Button(String(localized: "common.save")) { ... }
   ```

2. **Add the key to `Localizable.xcstrings`** using Xcode's String Catalog editor

3. **Sync all languages:**
   ```bash
   ./scripts/sync-localization.sh
   ```

4. **Commit changes including the updated .xcstrings file**

### Key Naming Conventions

Use hierarchical naming with dots for organization:

```
nav.people              # Navigation elements
common.save             # Common actions  
actions.mention         # Message actions
placeholder.nickname    # Input placeholders
alert.bluetooth_required # Alert titles
accessibility.send_message # Accessibility labels
fp.verified            # Security/fingerprint features
location.teleport      # Location-specific features
```

### Translation Guidelines

- **Preserve technical terms**: Keep "#mesh", "/msg", "BitChat", "Nostr" untranslated
- **Maintain UI consistency**: Use the same terms across related features
- **Consider context**: Some words have different meanings in different UI contexts
- **RTL languages**: Arabic and Urdu require right-to-left layout consideration
- **Cultural adaptation**: Some concepts may need cultural adaptation beyond literal translation

## Scripts & Tooling

### `scripts/sync-localization.sh`
Primary script to maintain language parity:
```bash
./scripts/sync-localization.sh
```
- Ensures all 29 languages have identical key sets
- Fills missing keys with English values for translation
- Run after adding new localization keys

### `scripts/localization/sync_xcstrings.py` 
Low-level Python utility that powers the sync functionality:
```bash
python3 scripts/localization/sync_xcstrings.py bitchat/Localizable.xcstrings
```

### Pre-Commit Hook (Optional)
Validates localization integrity before commits:
```bash
# Enable validation
cp scripts/localization-pre-commit-hook.sh .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

# Disable temporarily
git commit --no-verify
```

## Testing

The localization system includes comprehensive test coverage:

- **LocalizationTests.swift** - Validates key resolution and fallback behavior
- **Bundle resolution testing** - Ensures proper locale-specific bundle loading  
- **Key completeness verification** - Validates all languages have all keys

Run tests:
```bash
# Swift Package Manager
swift build && swift test

# Xcode
xcodebuild test -scheme bitchatTests_iOS
```

## Accessibility

All localized strings include comprehensive accessibility support:
- Screen reader labels with `accessibility.` prefixed keys
- Localized hints for complex UI interactions
- Multi-language accessibility testing coverage

## Technical Details

### Modern .xcstrings Format
- Single JSON file vs. multiple `.strings` files
- Native Xcode String Catalog integration
- Better version control and merge handling
- Automatic plural form support
- State tracking (translated/needs review)

### Language Fallback Chain
1. User's preferred language (e.g., `zh-HK`)
2. Language family fallback (e.g., `zh-Hans`)
3. English base (`en`)
4. Key name as last resort

### Right-to-Left (RTL) Support
Languages with RTL support: Arabic (`ar`, `arz`), Urdu (`ur`), Punjabi (`pnb`)
- Text alignment automatically handled by SwiftUI
- Consider UI layout for RTL languages during design

## Troubleshooting

### Build Warnings
If you see localization-related build warnings:
1. Run `./scripts/sync-localization.sh`
2. Ensure `Localizable.xcstrings` is in project resources
3. Verify `Package.swift` includes proper resource declarations

### Missing Translations
If strings appear in English in non-English locales:
1. Check the key exists in `Localizable.xcstrings`
2. Verify the target language has a value (not empty/null)
3. Test with iOS Simulator in different languages

### Adding a New Language
1. Add the language code to `scripts/localization/sync_xcstrings.py`
2. Run sync script to populate with English placeholders
3. Translate the values in `Localizable.xcstrings`
4. Test with a device/simulator set to that language

## Contributing

When contributing localized strings:
1. Use semantic, hierarchical key names
2. Test in multiple languages before submitting
3. Run the sync script to maintain parity
4. Include accessibility keys for all interactive elements
5. Consider cultural context, not just literal translation

## Resources

- [Apple Localization Guide](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)
- [String Catalog Documentation](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)
- [iOS Accessibility Guidelines](https://developer.apple.com/accessibility/ios/)