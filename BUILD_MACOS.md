# BitChat macOS Build

This Justfile provides easy commands to build and run BitChat natively on macOS while preserving the original project configuration.

## Quick Start

```bash
# Build and run the app
just run

# Or see all available commands
just
```

## Commands

- `just run` - Build and run the macOS app
- `just build` - Build the macOS app only  
- `just clean` - Clean build artifacts and restore original files
- `just check` - Check prerequisites (XcodeGen, Xcode, etc.)
- `just info` - Show app information and requirements

## How It Works

The Justfile temporarily modifies `project.yml` to:
- Use your local development team ID (replaces `L3N5LHJD5Y`)
- Change bundle identifier to avoid conflicts (`chat.bitchat` → `com.local.bitchat`)
- Disable code signing for local development (`Automatic` → `Manual`)
- Exclude iOS-specific files from macOS build (`LaunchScreen.storyboard`)

**Original files are always preserved** - modifications are only applied during builds and automatically cleaned up. The project files remain exactly as they are on the main branch.

## Requirements

- macOS 13.0+ (Ventura)
- Xcode (from App Store)
- XcodeGen (`brew install xcodegen`)
- Bluetooth LE capable Mac
- Physical device (Bluetooth doesn't work in simulator)

## App Features

- **Native macOS SwiftUI app** - not a Catalyst port
- **Bluetooth LE mesh networking** - no internet required
- **End-to-end encryption** - X25519 + AES-256-GCM
- **Store-and-forward messaging** - works with offline peers
- **Channel-based group chats** - IRC-style commands
- **Private messaging** with delivery receipts
- **Emergency wipe** - triple-tap logo to clear all data

## Usage

Once running:
- Set your nickname and start discovering nearby peers
- Use `/join #channel` for group chats
- Use `/msg @user` for private messages  
- Use `/who` to see connected peers
- Triple-tap the logo for emergency data wipe

The app creates a decentralized mesh network over Bluetooth LE that can span significant distances through multi-hop message relay.
