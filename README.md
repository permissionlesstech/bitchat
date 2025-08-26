<img width="256" height="256" alt="icon_128x128@2x" src="https://github.com/user-attachments/assets/90133f83-b4f6-41c6-aab9-25d0859d2a47" />

## bitchat

A decentralized peer-to-peer messaging app that works over Bluetooth mesh networks. No internet required, no servers, no phone numbers. It's the side-groupchat. 

[bitchat.free](http://bitchat.free)

📲 [App Store](https://apps.apple.com/us/app/bitchat-mesh/id6748219622)

> [!WARNING]
> Private messages have not received external security review and may contain vulnerabilities. Do not use for sensitive use cases, and do not rely on its security until it has been reviewed. Now uses the [Noise Protocol](http://www.noiseprotocol.org) for identity and encryption. Public local chat (the main feature) has no security concerns. 


## License

This project is released into the public domain. See the [LICENSE](LICENSE) file for details.


## Features

- **Decentralized Mesh Network**: Automatic peer discovery and multi-hop message relay over Bluetooth LE
- **Privacy First**: No accounts, no phone numbers, no persistent identifiers
- **Private Message End-to-End Encryption**: [Noise Protocol](http://noiseprotocol.org)
- **IRC-Style Commands**: Familiar `/slap`, `/msg`, `/who` style interface
- **Universal App**: Native support for iOS and macOS
- **Emergency Wipe**: Triple-tap to instantly clear all data
- **Performance Optimizations**: LZ4 message compression, adaptive battery modes, and optimized networking


## [Technical Architecture](https://deepwiki.com/permissionlesstech/bitchat)

### Binary Protocol
bitchat uses an efficient binary protocol optimized for Bluetooth LE:
- Compact packet format with 1-byte type field
- TTL-based message routing (max 7 hops)
- Automatic fragmentation for large messages
- Message deduplication via unique IDs

### Mesh Networking
- Each device acts as both client and peripheral
- Automatic peer discovery and connection management
- Adaptive duty cycling for battery optimization

For detailed protocol documentation, see the [Technical Whitepaper](WHITEPAPER.md).


## Setup

### Option 1: Using XcodeGen (Recommended)

1. Install XcodeGen if you haven't already:
   ```bash
   brew install xcodegen
   ```

2. Generate the Xcode project:
   ```bash
   cd bitchat
   xcodegen generate
   ```

3. Open the generated project:
   ```bash
   open bitchat.xcodeproj
   ```

### Option 2: Using Swift Package Manager

1. Open the project in Xcode:
   ```bash
   cd bitchat
   open Package.swift
   ```

2. Select your target device and run

### Option 3: Manual Xcode Project

1. Open Xcode and create a new iOS/macOS App
2. Copy all Swift files from the `bitchat` directory into your project
3. Update Info.plist with Bluetooth permissions
4. Set deployment target to iOS 16.0 / macOS 13.0

### Option 4: just

Want to try this on macos: `just run` will set it up and run from source. 
Run `just clean` afterwards to restore things to original state for mobile app building and development.

## Localization

- Supported locales: English (Base), Spanish (`es`), Simplified Chinese (`zh-Hans`), Arabic (`ar`), French (`fr`).
- UI strings live in a String Catalog: `bitchat/Localization/Localizable.xcstrings`.
- System permission texts (e.g., Bluetooth) live in `InfoPlist.strings` per locale under `bitchat/Localization/<locale>.lproj/`.
- Key naming convention uses namespaces: `nav.*`, `settings.*`, `cmd.*`, `errors.*`, `toast.*`, `accessibility.*`, `placeholder.*`.

Add a new language
- Add translations to `Localizable.xcstrings` via Xcode (recommended) or by editing JSON.
- Create `bitchat/Localization/<locale>.lproj/InfoPlist.strings` (copy Base keys) for permission prompts.
- Update the UITest locales list in `bitchatTests/UI/Localization/Support/LocalizationUITestUtils.swift` and add exact expected labels if available.
- Run UITests with the helper:
  - `./bitchatTests/UI/Localization/Scripts/test-sim-locale.sh --test`
- For manual runs: launch the app in Simulator with overrides:
  - `-AppleLanguages (es) -AppleLocale es_ES`

Notes
- Command tokens (`/msg`, `/w`, etc.) remain canonical and are not localized. Only titles/help text are.
- RTL (Arabic) is supported; UI uses SwiftUI’s directionality where possible.
- See `bitchatTests/UI/Localization/README.md` for localization test structure and guidance.

Lint rule: no raw UI string literals
- SwiftLint enforces a custom rule (`no_raw_ui_string_literals`) that errors on raw literals passed directly to UI APIs like `Text("…")`, `.alert("…")`, `.help("…")`, `.accessibilityLabel("…")`.
- Use `Text(LocalizedStringKey("key"))` or `String(localized: "key")` instead.
- Intentional, non-translatable symbols/brand (e.g., `"bitchat/"`, `"@"`, `"#"`, `"•"`, `"✔︎"`) are allowed by the rule.
- To intentionally bypass for a single line, use a SwiftLint directive:
  - `// swiftlint:disable:next no_raw_ui_string_literals`
  - or wrap a block with `// swiftlint:disable no_raw_ui_string_literals` … `// swiftlint:enable no_raw_ui_string_literals`

Strings verification checklist
- New key added to `Localizable.xcstrings` with translations for en, es, zh-Hans, ar, fr.
- Any matching Info.plist user-facing text added to `Localization/<locale>.lproj/InfoPlist.strings`.
- UI uses `Text(LocalizedStringKey(...))` or `String(localized:)` for literals; dynamic keys resolve with `NSLocalizedString`/`Bundle.localizedString`.
- Formatting uses placeholders (`%@`, `%d`) and `String(format:)` where needed.
- RTL smoke: launch in Arabic and verify critical labels don’t truncate and align correctly.
