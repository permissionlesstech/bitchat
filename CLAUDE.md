# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BitChat is a decentralized peer-to-peer messaging iOS/macOS app that works over Bluetooth mesh networks without requiring internet, servers, or phone numbers. It implements end-to-end encryption using the Noise Protocol Framework and integrates Nostr as a fallback transport for mutual favorites.

**Core Value Proposition**: Side-groupchat for scenarios where traditional communication infrastructure is unavailable or untrusted. Security and reliability are paramount over features.

## Common Development Commands

### Building the Project

```bash
# Option 1: Generate Xcode project with XcodeGen (preferred)
xcodegen generate
open bitchat.xcodeproj

# Option 2: Open with Swift Package Manager
open Package.swift

# Option 3: Quick macOS build and run using Just
just run        # Build and run macOS app
just build      # Build only
just clean      # Clean and restore original files
just dev-run    # Quick development build
```

### Testing

```bash
# Run iOS tests
xcodebuild test -project bitchat.xcodeproj -scheme "bitchat (iOS)" -destination "platform=iOS Simulator,name=iPhone 15"

# Run macOS tests  
xcodebuild test -project bitchat.xcodeproj -scheme "bitchat (macOS)" -destination "platform=macOS"

# Run specific test file
xcodebuild test -project bitchat.xcodeproj -scheme "bitchat (iOS)" -only-testing:bitchatTests_iOS/NoiseProtocolTests

# Run all tests with verbose output
xcodebuild test -project bitchat.xcodeproj -scheme "bitchat (iOS)" -destination "platform=iOS Simulator,name=iPhone 15" -verbose
```

### Building for Device

```bash
# Build for iOS device
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (iOS)" -configuration Release -destination "generic/platform=iOS" archive

# Build for macOS (unsigned)
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" -configuration Debug CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

## High-Level Architecture

BitChat uses a layered architecture with clear separation of concerns:

### Core Architecture Layers

1. **Transport Layer** (`SimplifiedBluetoothService`, `NostrRelayManager`)
   - Handles Bluetooth LE mesh networking and Nostr WebSocket connections
   - Manages peer discovery, connection lifecycle, and message routing
   - Implements automatic transport selection based on peer availability

2. **Protocol Layer** (`BitchatProtocol`, `NostrProtocol`)
   - Defines binary message format for efficient BLE transmission
   - Implements NIP-17 gift-wrapped messages for Nostr privacy
   - Handles message framing, fragmentation, and reassembly

3. **Security Layer** (`NoiseProtocol`, `NoiseEncryptionService`)
   - Implements Noise_XX_25519_AESGCM_SHA256 for E2E encryption
   - Manages cryptographic handshakes and session keys
   - Provides forward secrecy and mutual authentication

4. **Application Services** (`FavoritesPersistenceService`, `NotificationService`, `PeerStateManager`)
   - Manages favorites system and mutual trust relationships
   - Handles system notifications and peer state
   - Transport selection logic integrated in ChatViewModel (lines 653-665)

5. **UI Layer** (`ChatViewModel`, `ContentView`)
   - MVVM architecture with SwiftUI views
   - Manages chat state, commands, and user interactions
   - Handles private chats and channel management

### Key Design Patterns

- **Transport Abstraction**: Messages automatically route through available transports (Bluetooth when connected, Nostr for mutual favorites when offline)
- **Three-Layer Identity**: Ephemeral, Cryptographic, and Social identities
- **Mutual Favorites**: Nostr transport requires bidirectional trust and is fully functional
- **Binary Protocol**: Optimized for BLE's limited bandwidth (~20KB/s)
- **Efficient Message Deduplication**: Time-based LRU cache prevents loops in mesh network
- **TTL-Based Routing**: Maximum 7 hops to prevent infinite propagation
- **Consolidated Maintenance**: Single timer handles all periodic tasks (announces, cleanup, connectivity checks)

### Critical Files and Their Roles

- `Services/SimplifiedBluetoothService.swift` (~1860 lines): Core BLE mesh implementation
- `Services/FavoritesPersistenceService.swift`: Manages favorite relationships
- `Noise/NoiseProtocol.swift` (~900 lines): Cryptographic protocol implementation  
- `Nostr/NostrProtocol.swift`: NIP-17 private message implementation
- `ViewModels/ChatViewModel.swift` (~3100 lines): Central business logic and state
- `Protocols/BitchatProtocol.swift` (~1100 lines): Binary message format definitions
- `Protocols/BinaryProtocol.swift` (~580 lines): Low-level encoding/decoding

## Important Considerations

### Security
- Never log sensitive data (keys, message content)
- Use `SecureLogger` for security-aware logging
- All private messages use end-to-end encryption
- Identity keys stored in iOS Keychain

### Performance
- Bluetooth LE has ~512 byte MTU, messages are fragmented
- Use LZ4 compression for large messages
- Minimize protocol overhead for battery efficiency
- Batch UI updates to prevent performance issues

### Testing Requirements
- Physical devices required (Bluetooth doesn't work in simulator)
- Test with multiple devices for mesh functionality
- Enable Bluetooth permissions in device settings
- Test both transport modes (Bluetooth and Nostr)

### Platform Differences
- iOS: Full background Bluetooth support with proper entitlements
- macOS: Limited background support, may require app in foreground
- Share Extension: iOS only, for sharing content to BitChat

### Known Quirks
- XcodeGen may require temporary file moves for macOS builds (handled by Justfile)
- LaunchScreen.storyboard is iOS-only, needs hiding for macOS builds
- Nostr keys derived from Noise keys using BIP-32 path m/44'/1237'/0'/0/0

## Debugging Tips

### Bluetooth Issues
- Check `SimplifiedBluetoothService` state and peer connections
- Verify app has Bluetooth permissions enabled
- Ensure devices are in range (<50 meters typical)
- Monitor characteristic notifications and MTU

### Nostr Transport (Fully Functional)
- Verify mutual favorite status in `FavoritesPersistenceService`
- Check relay connections in `NostrRelayManager` logs
- Test gift wrap encryption/decryption in `NostrProtocol`
- Transport selection happens automatically in `ChatViewModel.sendPrivateMessage()` (lines 653-665)

### Message Delivery
- Check for message processing in `SimplifiedBluetoothService.handleReceivedPacket()`
- Verify handshake state for private messages in `NoiseEncryptionService`
- Efficient deduplication uses `MessageDeduplicator` class with time-based cleanup
- Monitor TTL values in mesh propagation (max 7 hops)

## Common Tasks

### Adding New Message Types
1. Define in `MessageType` enum in `BitchatProtocol.swift`
2. Implement encoding/decoding in `BinaryProtocol.swift`
3. Add handling in `ChatViewModel.processMessage()`
4. Update UI components if needed
5. Add unit tests for encoding/decoding in `bitchatTests/Protocol/`

### Implementing New Commands
1. Add to `ChatViewModel.processCommand()` (~line 2800)
2. Define required message types if needed
3. Implement command logic and validation
4. Add to autocomplete suggestions in `getCommandSuggestions()`
5. Update help text in `/help` command implementation

### Modifying Transports
1. Update transport-specific protocol implementations
2. Test failover between transports (automatic in ChatViewModel)
3. Verify message delivery in both modes
4. Nostr integration is complete and functional for mutual favorites

### Running Code Quality Checks
```bash
# SwiftLint (if configured)
swiftlint lint --path bitchat/

# Swift format check (if using swift-format)
swift-format lint -r bitchat/

# Build with strict warnings
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (iOS)" -configuration Debug SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
```

## Recent Optimizations

### Performance Improvements
- **Message Deduplication**: Replaced O(n) Set recreation with efficient time-based LRU cache
- **Timer Consolidation**: Single maintenance timer replaces multiple timers, reducing overhead
- **Main Thread Optimization**: Added `notifyUI()` helper to avoid unnecessary dispatches
- **didReceiveMessage Refactoring**: Split 300-line method into focused helper methods

### Architecture Clarifications
- Nostr transport is fully implemented and functional (not partial)
- Transport selection logic is integrated in ChatViewModel, not a separate service
- Peer state management could be further consolidated (3 systems track same data)

Remember: This app is designed for scenarios where traditional communication infrastructure is unavailable or untrusted. Security and reliability are paramount over features.