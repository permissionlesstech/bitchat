# 🌍 International Support

BitChat provides comprehensive localization supporting **29 languages** and **4+ billion speakers worldwide**.

## Quick Start

**For Users:** BitChat automatically adapts to your device's language settings.

**For Developers:** 
```bash
# Add new strings to bitchat/Localizable.xcstrings
# Then sync all languages
./scripts/sync-localization.sh
```

## Supported Languages

### Tier 1: Major World Languages (15)
🇺🇸 English • 🇪🇸 Spanish • 🇨🇳 Chinese (3 variants) • 🇮🇳 Hindi • 🇸🇦 Arabic  
🇵🇹 Portuguese (2 variants) • 🇧🇩 Bengali • 🇷🇺 Russian • 🇯🇵 Japanese • 🇩🇪 German  
🇫🇷 French • 🇵🇰 Urdu • 🇹🇷 Turkish • 🇻🇳 Vietnamese • 🇮🇩 Indonesian

### Tier 2: Regional & Cultural Languages (14)
🇪🇬 Egyptian Arabic • 🇵🇭 Filipino • 🇭🇰 Cantonese • 🇮🇳 Tamil • 🇮🇳 Telugu  
🇮🇳 Marathi • 🇰🇪 Swahili • 🇳🇬 Hausa • 🇳🇬 Nigerian Pidgin • 🇵🇰 Punjabi

**Coverage:** 4+ billion people can use BitChat in their native language.

## Features

✅ **Native iOS Localization** - Uses system language preferences  
✅ **RTL Language Support** - Arabic, Urdu with proper text direction  
✅ **Cultural Adaptation** - Context-aware translations, not just literal  
✅ **Accessibility** - Screen readers work in all supported languages  
✅ **Modern Apple Standards** - Uses .xcstrings format for easy maintenance

## For Contributors

See [LOCALIZATION.md](LOCALIZATION.md) for complete developer documentation.

**Quick Reference:**
- Add strings to `bitchat/Localizable.xcstrings`
- Use `String(localized: "key")` in Swift code  
- Run `./scripts/sync-localization.sh` after changes
- Test in multiple languages before submitting

## Translation Help Wanted

Native speakers are welcome to improve translations! The sync tooling automatically maintains key parity across all languages - translators can focus on quality translations rather than technical setup.