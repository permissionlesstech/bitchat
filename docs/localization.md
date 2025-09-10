# Localization Guide

BitChat supports comprehensive internationalization with **29 languages**, following Apple's modern best practices using the `.xcstrings` format.

## File Structure (Modern 2024 Apple Approach)

```
bitchat/
├── Localizable.xcstrings    # App UI strings (146 keys × 29 languages = 4,234 entries)
└── Infoplist.xcstrings      # System permissions (2 keys × 29 languages = 58 entries)
```

**Total: 4,292 localization entries with zero legacy files.**

## Supported Languages (29 Total)

### Major World Languages (18)
- **English (en)** - Base language
- **Spanish (es)** - 500M+ speakers  
- **Chinese Simplified (zh-Hans)** - 918M speakers
- **Chinese Traditional (zh-Hant)** - 75M speakers
- **Chinese Hong Kong (zh-HK)** - 7M speakers
- **Arabic (ar)** - 400M+ speakers
- **Hindi (hi)** - 600M+ speakers
- **French (fr)** - 280M speakers
- **German (de)** - 100M speakers
- **Japanese (ja)** - 125M speakers
- **Russian (ru)** - 258M speakers
- **Portuguese (pt)** - 260M speakers
- **Brazilian Portuguese (pt-BR)** - 215M speakers
- **Urdu (ur)** - 230M speakers
- **Turkish (tr)** - 80M speakers
- **Vietnamese (vi)** - 95M speakers
- **Indonesian (id)** - 270M speakers
- **Bengali (bn)** - 300M speakers

### Regional & Cultural Languages (11)  
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

## Developer Workflow

### Adding New Localizable Strings

1. **Add to Localizable.xcstrings** using Xcode String Catalog editor:
   ```swift
   // ❌ Wrong
   Button("Save") { ... }
   
   // ✅ Correct  
   Button(String(localized: "common.save")) { ... }
   ```

2. **Sync all languages and comments:**
   ```bash
   ./scripts/localization/sync-all-localizations.sh
   ```
   - Ensures 29-language parity and fills gaps with English
   - Auto-adds concise developer comments for any keys missing context

3. **Add translation context** for translators in Xcode String Catalog comments

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

## Scripts & Tooling

### Main Sync Script
```bash
./scripts/localization/sync-all-localizations.sh
```
- Syncs both Localizable.xcstrings AND Infoplist.xcstrings
- Ensures all 29 languages have complete coverage
- Fills missing keys with English values for translation
- Adds concise developer comments where missing

### Simulator Locale Helper
```bash
# Use the only booted Simulator
./scripts/simulator/set-locale.sh --lang fr --region FR --restart

# Specify a device UDID explicitly
./scripts/simulator/set-locale.sh --lang es --device <UDID>

# Launch an app with per-launch overrides (no reboot)
./scripts/simulator/set-locale.sh --lang zh-Hans --region CN --device <UDID> --launch com.your.bundleid

# Auto-boot an available iPhone if none booted
./scripts/simulator/set-locale.sh --lang de --boot --restart
```
- Auto-detects the single booted Simulator if `--device` is omitted.
- Writes device-wide AppleLanguages and AppleLocale; `--restart` reboots to apply system-wide.
- `--launch` starts an app with `-AppleLanguages`/`-AppleLocale` arguments for fast spot checks.
 - `--boot` selects and boots the first available iPhone device if no single booted device is found.

### Build-Time Validation
```bash
./scripts/localization/validate-localization-build.sh
```
- Prevents hardcoded strings in commits
- Validates .xcstrings file integrity
- Checks language parity across all 29 languages
- Confirms every key has a developer comment for translator context

### Pre-Commit Hook (Optional)
```bash
# Enable validation
cp scripts/github/localization-pre-commit-hook.sh .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```
What it enforces:
- No hardcoded UI strings in Swift files
- Valid `.xcstrings` JSON and 29-language parity
- Every key has a concise developer comment

Behavior:
- If comments are missing, the hook attempts to auto-add them using
  `scripts/localization/add_missing_comments.py`, then asks you to review and
  stage the changes.
 - Note: There is no separate polishing step; `add_missing_comments.py` is the
   sole source of comment generation.

## Testing

### Comprehensive Test Coverage

**LocalizationTests.swift** - Real value testing:
- `testCriticalUIStringsAreLocalized()` - Validates top 5 UI strings × 3 major languages
- `testTechnicalTermsNotTranslated()` - Ensures #mesh, BitChat, Nostr preserved
- `testMajorLanguagesProperlyTranslated()` - Verifies native translations vs English fallbacks
- `testInfoPlistLocalization()` - Validates Bluetooth permission strings work
- `testLocalizationFallbackWorks()` - Tests graceful degradation

**UI Tests:**
- App launch validation across languages
- Accessibility compliance testing
- Navigation flow validation

```bash
# Run comprehensive tests
xcodebuild test -scheme "bitchat (iOS)" -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest'
```

## Translation Guidelines

### Cultural Adaptation
- **Preserve technical terms**: Keep "#mesh", "/msg", "BitChat", "Nostr" untranslated
- **Cultural context**: Consider local communication patterns
- **RTL languages**: Arabic and Urdu require right-to-left consideration
- **CJK languages**: Chinese variants and Japanese need proper character sets

### Quality Standards
- **Professional translations**: Not literal word-for-word conversion
- **Context comments**: Provided in .xcstrings for ambiguous terms
- **Consistency**: Same terms across related features
- **Length validation**: UI elements have reasonable text length

## Technical Details

### Modern .xcstrings Benefits
- **Single file management** vs multiple .strings files
- **Native Xcode integration** with String Catalog editor
- **Better version control** and merge handling
- **Automatic plural support** and state tracking
- **Translation progress** visibility in Xcode

### Language Fallback Chain
1. User's preferred language (e.g., `zh-HK`)
2. Language family fallback (e.g., `zh-Hans`)
3. English base (`en`)
4. Key name as last resort

### Right-to-Left (RTL) Support
Languages: Arabic (`ar`, `arz`), Urdu (`ur`), Punjabi (`pnb`)
- Text alignment automatically handled by SwiftUI
- UI layouts adapt automatically to RTL reading direction

## Troubleshooting

### Build Issues
```bash
# Regenerate project after .xcstrings changes
xcodegen generate

# Validate localization integrity  
./scripts/localization/validate-localization-build.sh
```

### Missing Translations
```bash
# Sync all languages to ensure parity
./scripts/localization/sync-all-localizations.sh

# Check for English fallbacks in major languages
# Edit Localizable.xcstrings in Xcode String Catalog editor
```

### Adding New Languages
1. Add language code to `scripts/localization/sync_xcstrings.py`
2. Run sync script to populate with English placeholders  
3. Translate values in both .xcstrings files
4. Test with iOS Simulator set to that language

## Quality Assurance

### Build-Time Validation
- Automatic detection of hardcoded UI strings
- .xcstrings file integrity validation
- Language parity enforcement across all 29 languages

### Runtime Testing
- Comprehensive unit test coverage
- UI interaction testing across languages
- Permission dialog localization validation

### Manual Testing Checklist
- [ ] Test in iOS Simulator with different languages
- [ ] Verify RTL languages display correctly (Arabic, Urdu)  
- [ ] Check CJK languages render properly (Chinese, Japanese)
- [ ] Validate Bluetooth permission dialogs appear in user's language
- [ ] Ensure technical terms (#mesh, Nostr) remain consistent

## Contributing

When adding localized strings:
1. **Use semantic key names** with dot hierarchy
2. **Add context comments** for translators in String Catalog
3. **Preserve technical terms** - don't translate brand/protocol names
4. **Test across languages** before submitting  
5. **Run sync script** to maintain 29-language parity

## Resources

- [Apple String Catalog Guide](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)
- [iOS Accessibility Guidelines](https://developer.apple.com/accessibility/ios/)
- [Unicode CLDR Plural Rules](http://cldr.unicode.org/index/cldr-spec/plural-rules)
