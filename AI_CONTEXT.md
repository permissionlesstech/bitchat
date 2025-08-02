# AI Context for BitChat

This document provides essential context for AI assistants working on the BitChat codebase. Read this first to understand the project's architecture, design decisions, and key concepts.

## Project Overview

BitChat is a decentralized, peer-to-peer messaging application that works over Bluetooth mesh networks without requiring internet connectivity, servers, or phone numbers. It's designed for scenarios where traditional communication infrastructure is unavailable or untrusted.

### Key Features
- **Bluetooth Mesh Networking**: Multi-hop message relay over BLE
- **Privacy-First Design**: No accounts, no persistent identifiers
- **End-to-End Encryption**: Uses Noise Protocol Framework for private messages
- **Store & Forward**: Messages cached for offline peers
- **IRC-Style Commands**: Familiar `/msg`, `/who` interface
- **Cross-Platform**: Native iOS and macOS support
- **Nostr Integration**: Seamless fallback for mutual favorites when out of Bluetooth range
- **Hybrid Transport**: Automatic switching between Bluetooth and Nostr

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Interface                             │
│                    (ContentView, ChatViewModel)                   │
└─────────────────────────────────────────────────────────────────┘
                                   │
┌─────────────────────────────────────────────────────────────────┐
│                     Application Services                          │
│  (MessageRetryService, DeliveryTracker, NotificationService)     │
└─────────────────────────────────────────────────────────────────┘
                                   │
┌─────────────────────────────────────────────────────────────────┐
│                      Message Router                               │
│         (Transport selection, Favorites integration)              │
└─────────────────────────────────────────────────────────────────┘
                    │                            │
┌───────────────────────────────┐ ┌────────────────────────────────┐
│        Security Layer         │ │      Nostr Protocol Layer      │
│ (NoiseEncryptionService,      │ │  (NostrProtocol, NIP-17,      │
│  SecureIdentityStateManager)  │ │   NostrRelayManager)          │
└───────────────────────────────┘ └────────────────────────────────┘
                    │                            │
┌───────────────────────────────┐ ┌────────────────────────────────┐
│       Protocol Layer          │ │         Transport              │
│ (BitchatProtocol, Binary-     │ │    (WebSocket to Nostr        │
│  Protocol, NoiseProtocol)     │ │      relay servers)           │
└───────────────────────────────┘ └────────────────────────────────┘
                    │
┌─────────────────────────────────────────────────────────────────┐
│                   Bluetooth Transport Layer                       │
│                   (BluetoothMeshService)                          │
└─────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. BluetoothMeshService (Transport Layer)
- **Location**: `bitchat/Services/BluetoothMeshService.swift`
- **Purpose**: Manages BLE connections and implements mesh networking
- **Key Responsibilities**:
  - Peer discovery (scanning and advertising simultaneously)
  - Connection management (acts as both central and peripheral)
  - Message routing and relay
  - Version negotiation with peers
  - Automatic reconnection and topology management

### 2. BitchatProtocol (Protocol Layer)
- **Location**: `bitchat/Protocols/BitchatProtocol.swift`
- **Purpose**: Defines the application-level messaging protocol
- **Key Features**:
  - Binary packet format for efficiency
  - Message types: Chat, Announcement, PrivateMessage, etc.
  - TTL-based routing (max 7 hops)
  - Message deduplication via unique IDs
  - Privacy features: padding, timing obfuscation

### 3. NoiseProtocol Implementation
- **Locations**: 
  - `bitchat/Noise/NoiseProtocol.swift` - Core protocol implementation
  - `bitchat/Noise/NoiseSession.swift` - Session management
  - `bitchat/Services/NoiseEncryptionService.swift` - High-level encryption API
- **Purpose**: Provides end-to-end encryption for private messages
- **Implementation Details**:
  - Uses Noise_XX_25519_AESGCM_SHA256 pattern
  - Mutual authentication via static keys
  - Forward secrecy via ephemeral keys
  - Integrated with identity management

### 4. Identity System
- **Location**: `bitchat/Identity/`
- **Three-Layer Model**:
  1. **Ephemeral Identity**: Short-lived, rotates frequently
  2. **Cryptographic Identity**: Long-term Noise static keypair
  3. **Social Identity**: User-chosen nickname and metadata
- **Trust Levels**: Untrusted → Verified → Trusted → Blocked

### 5. ChatViewModel
- **Location**: `bitchat/ViewModels/ChatViewModel.swift`
- **Purpose**: Central state management and business logic
- **Responsibilities**:
  - Message handling and batching
  - Command processing (/msg, /who, etc.)
  - UI state management
  - Private chat coordination

### 6. Nostr Integration
- **Locations**:
  - `bitchat/Nostr/NostrProtocol.swift` - NIP-17 private message implementation
  - `bitchat/Nostr/NostrRelayManager.swift` - WebSocket relay connections
  - `bitchat/Nostr/NostrIdentity.swift` - Nostr key management
  - `bitchat/Services/MessageRouter.swift` - Transport selection logic
- **Purpose**: Enables communication with mutual favorites when out of Bluetooth range
- **Key Features**:
  - NIP-17 gift-wrapped private messages for metadata privacy
  - Automatic relay connection management
  - Seamless transport switching between Bluetooth and Nostr
  - Integrated with favorites system for mutual authentication

### 7. MessageRouter
- **Location**: `bitchat/Services/MessageRouter.swift`
- **Purpose**: Intelligent routing between Bluetooth mesh and Nostr transports
- **Transport Selection Logic**:
  1. Always prefer Bluetooth mesh when peer is connected
  2. Use Nostr for mutual favorites when peer is offline
  3. Fail gracefully when no transport is available
- **Message Types Routed**:
  - Regular chat messages
  - Favorite/unfavorite notifications
  - Delivery acknowledgments
  - Read receipts

## Key Design Decisions

### 1. Protocol Design
- **Binary Protocol**: Chosen for efficiency over BLE's limited bandwidth
- **No JSON**: Reduces parsing overhead and message size
- **Custom Framing**: Handles BLE's 512-byte MTU limitations

### 2. Security Architecture
- **Noise Protocol**: Industry-standard, well-analyzed framework
- **XX Pattern**: Provides mutual authentication and forward secrecy
- **No Long-Term Identifiers**: Enhances privacy and deniability

### 3. Mesh Networking
- **Store & Forward**: Essential for intermittent connectivity
- **TTL-Based Routing**: Prevents infinite loops in mesh
- **Bloom Filters**: Efficient duplicate detection

### 4. Privacy Features
- **Message Padding**: Obscures message length
- **Timing Obfuscation**: Randomized delays
- **Emergency Wipe**: Triple-tap to clear all data

### 5. Nostr Integration
- **NIP-17 Gift Wraps**: Maximum metadata privacy
- **Ephemeral Keys**: Each message uses unique ephemeral keys
- **Mutual Favorites Only**: Requires bidirectional trust
- **Transport Abstraction**: Users don't need to know about Nostr

## Code Organization

### Services (`/bitchat/Services/`)
Application-level services that coordinate between layers:
- `BluetoothMeshService`: Core networking
- `NoiseEncryptionService`: Encryption coordination
- `MessageRetryService`: Reliability layer
- `DeliveryTracker`: Acknowledgment handling
- `NotificationService`: System notifications

### Protocols (`/bitchat/Protocols/`)
Protocol definitions and implementations:
- `BitchatProtocol`: Application protocol
- `BinaryProtocol`: Low-level encoding
- `BinaryEncodingUtils`: Helper functions

### Noise (`/bitchat/Noise/`)
Noise Protocol Framework implementation:
- `NoiseProtocol`: Core cryptographic operations
- `NoiseSession`: Session state management
- `NoiseHandshakeCoordinator`: Handshake orchestration
- `NoiseSecurityConsiderations`: Security validations

### Views & ViewModels
MVVM architecture for UI:
- `ContentView`: Main chat interface
- `ChatViewModel`: Business logic and state
- Supporting views for settings, identity, etc.

## Nostr Protocol Implementation

### Overview
BitChat integrates Nostr as a secondary transport for communicating with mutual favorites when Bluetooth connectivity is unavailable. This integration is transparent to users - messages automatically route through Nostr when needed.

### NIP-17 Private Direct Messages
BitChat implements NIP-17 (Private Direct Messages) for metadata-private communication:

1. **Gift Wrap Structure**:
   ```
   Gift Wrap (kind 1059) → Seal (kind 13) → Rumor (kind 1)
   ```
   - **Rumor**: The actual message content (unsigned)
   - **Seal**: Encrypted rumor, hides sender identity
   - **Gift Wrap**: Double-encrypted, tagged for recipient

2. **Ephemeral Keys**:
   - Each message uses TWO ephemeral key pairs
   - Seal uses one ephemeral key
   - Gift wrap uses a different ephemeral key
   - Provides sender anonymity and forward secrecy

3. **Timestamp Randomization**:
   - ±1 minute randomization (reduced from NIP-17's ±15 minutes)
   - Prevents timing correlation attacks
   - Configurable in `NostrProtocol.randomizedTimestamp()`

### Favorites Integration

The Nostr transport is only available for mutual favorites:

1. **Favorite Establishment**:
   - User favorites a peer via `/fav` command
   - Favorite notification sent via Bluetooth (if connected)
   - Peer's Nostr public key exchanged during favorite process
   - Stored in `FavoritesPersistenceService`

2. **Mutual Requirement**:
   - Both peers must favorite each other
   - Prevents spam and unwanted Nostr messages
   - Enforced by `MessageRouter` transport selection

3. **Nostr Key Management**:
   - Derived from Noise static key using BIP-32
   - Path: `m/44'/1237'/0'/0/0` (1237 = "NOSTR" in decimal)
   - Consistent npub across app reinstalls
   - Keys never leave the device

### Message Routing Logic

`MessageRouter` automatically selects transport:

```swift
if peerAvailableOnMesh {
    transport = .bluetoothMesh  // Always prefer mesh
} else if isMutualFavorite {
    transport = .nostr          // Use Nostr for offline favorites
} else {
    throw MessageRouterError.peerNotReachable
}
```

### Relay Configuration

Default relays (hardcoded for reliability):
- `wss://relay.damus.io`
- `wss://relay.primal.net`
- `wss://offchain.pub`
- `wss://nostr21.com`

Relay selection criteria:
- Geographic distribution
- High uptime
- No authentication required
- Support for ephemeral events

### Message Format

Structured content for different message types:
- Chat: `MSG:<messageID>:<content>`
- Favorite: `FAVORITED:<senderNpub>` or `UNFAVORITED:<senderNpub>`
- Delivery ACK: `DELIVERED:<messageID>`
- Read Receipt: `READ:<base64EncodedReceipt>`

### Implementation Details

1. **NostrRelayManager**:
   - Manages WebSocket connections to relays
   - Handles reconnection logic
   - Processes EVENT, EOSE, OK, NOTICE messages
   - Implements NIP-01 relay protocol

2. **NostrProtocol**:
   - Implements NIP-17 encryption/decryption
   - Handles gift wrap creation/unwrapping
   - Manages ephemeral key generation
   - Provides Schnorr signatures

3. **ProcessedMessagesService**:
   - Prevents duplicate message processing
   - Tracks last subscription timestamp
   - Persists across app launches
   - 30-day retention window

### Security Considerations

1. **Metadata Protection**:
   - Sender identity hidden via ephemeral keys
   - Recipient only visible in gift wrap p-tag
   - Timing correlation prevented via randomization
   - Message content double-encrypted

2. **Relay Trust**:
   - Relays cannot read message content
   - Relays can see recipient pubkey (gift wrap)
   - Relays cannot determine sender
   - Multiple relays used for redundancy

3. **Key Hygiene**:
   - Ephemeral keys used once and discarded
   - Static Nostr key derived from Noise key
   - No key reuse between messages
   - Keys cleared from memory after use

### Debugging Nostr Issues

1. **Check relay connections**:
   - Look for "Connected to Nostr relay" in logs
   - Verify WebSocket state in NostrRelayManager
   - Check for relay errors/notices

2. **Verify gift wrap creation**:
   - Enable debug logging in NostrProtocol
   - Check ephemeral key generation
   - Verify encryption steps

3. **Message delivery**:
   - Check ProcessedMessagesService for duplicates
   - Verify subscription filters
   - Look for EVENT messages in relay responses

## Development Guidelines

### 1. Security First
- Never log sensitive data (keys, message content)
- Use `SecureLogger` for security-aware logging
- Validate all inputs from network
- Follow principle of least privilege

### 2. Performance Considerations
- BLE has limited bandwidth (~20KB/s practical)
- Minimize protocol overhead
- Batch operations where possible
- Use compression for large messages

### 3. Testing
- Unit tests for protocol logic
- Integration tests for service interactions
- End-to-end tests for user flows
- Mock objects for BLE testing

### 4. Error Handling
- Graceful degradation for network issues
- Clear error messages for users
- Automatic retry with backoff
- Never expose internal errors

## Common Tasks

### Adding a New Message Type
1. Define in `MessageType` enum in `BitchatProtocol.swift`
2. Implement encoding/decoding logic
3. Add handling in `ChatViewModel`
4. Update UI if needed
5. Add tests

### Implementing a New Command
1. Add to `ChatViewModel.processCommand()`
2. Define any new message types needed
3. Implement command logic
4. Add autocomplete support
5. Update help text

### Debugging Bluetooth Issues
1. Check `BluetoothMeshService` logs
2. Verify peer states and connections
3. Monitor characteristic updates
4. Use Bluetooth debugging tools

### Working with Nostr Transport
1. Verify mutual favorite status in `FavoritesPersistenceService`
2. Check Nostr key derivation in `NostrIdentity`
3. Monitor relay connections in `NostrRelayManager`
4. Test gift wrap encryption/decryption
5. Verify transport selection in `MessageRouter`

### Adding Nostr Features
1. Understand NIP-17 gift wrap structure
2. Maintain ephemeral key hygiene
3. Test with multiple relays
4. Preserve metadata privacy
5. Handle relay disconnections gracefully

## Security Threat Model

### Assumptions
- Adversaries can intercept all Bluetooth traffic
- Devices may be compromised
- No trusted infrastructure available

### Protections
- End-to-end encryption for private messages
- Message authentication via HMAC
- Forward secrecy via ephemeral keys
- Deniability through lack of signatures

### Limitations
- Public messages are unencrypted by design
- Metadata (who talks to whom) partially visible
- Timing attacks possible on mesh network
- No protection against flooding/spam (yet)

## Performance Optimizations

### Implemented
- LZ4 compression for messages
- Adaptive duty cycling for battery
- Connection caching and reuse
- Bloom filters for deduplication

### Future Improvements
- Protocol buffer encoding
- Better mesh routing algorithms
- Predictive pre-connection
- Smarter retransmission

## Troubleshooting Guide

### Common Issues
1. **Peers not discovering**: Check Bluetooth permissions, ensure app is in foreground
2. **Messages not delivering**: Verify mesh connectivity, check TTL values
3. **Handshake failures**: Ensure identity state is consistent, check key storage
4. **Performance issues**: Monitor connection count, check for message loops

## External Dependencies

### Swift Packages
- CryptoKit: Apple's crypto framework
- Network.framework: For future internet support
- No third-party dependencies (by design)

### System Requirements
- iOS 14.0+ / macOS 11.0+
- Bluetooth LE hardware
- ~50MB storage for app + data

## Future Roadmap

### Planned Features
- Internet bridging for hybrid networks
- Group chat with forward secrecy
- Voice messages with Opus codec
- File transfer support

### Architecture Evolution
- Plugin system for transports
- Modular protocol stack
- Cross-platform core library
- Federation between networks

---

## Quick Start for AI Assistants

1. **Understand the layers**: Transport → Protocol → Security → Services → UI
2. **Follow the data flow**: BLE/Nostr → Binary/JSON → Protocol → ViewModel → View
3. **Respect security boundaries**: Never mix trusted and untrusted data
4. **Test thoroughly**: This is critical infrastructure for users
5. **Ask about design decisions**: Many choices have non-obvious reasons
6. **Dual Transport**: Remember that messages can flow over Bluetooth OR Nostr
7. **Favorites System**: Nostr only works between mutual favorites

When in doubt, prioritize security and privacy over features. BitChat users depend on this app in situations where traditional communication has failed them.