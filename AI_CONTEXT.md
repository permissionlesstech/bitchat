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
│                       Security Layer                              │
│     (NoiseEncryptionService, SecureIdentityStateManager)         │
└─────────────────────────────────────────────────────────────────┘
                                   │
┌─────────────────────────────────────────────────────────────────┐
│                      Protocol Layer                               │
│        (BitchatProtocol, BinaryProtocol, NoiseProtocol)         │
└─────────────────────────────────────────────────────────────────┘
                                   │
┌─────────────────────────────────────────────────────────────────┐
│                      Transport Layer                              │
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
- **Cover Traffic**: Optional dummy messages
- **Timing Obfuscation**: Randomized delays
- **Emergency Wipe**: Triple-tap to clear all data

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
2. **Follow the data flow**: BLE → Binary → Protocol → ViewModel → View
3. **Respect security boundaries**: Never mix trusted and untrusted data
4. **Test thoroughly**: This is critical infrastructure for users
5. **Ask about design decisions**: Many choices have non-obvious reasons

When in doubt, prioritize security and privacy over features. BitChat users depend on this app in situations where traditional communication has failed them.