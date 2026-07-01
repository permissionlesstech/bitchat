# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build macOS (no signing)
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" -configuration Debug CODE_SIGNING_ALLOWED=NO build

# Build iOS for simulator
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (iOS)" -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' build

# Run all tests (iOS simulator)
xcodebuild -project bitchat.xcodeproj -scheme bitchat -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' test

# Run tests via Swift Package Manager (used in CI)
swift build && swift test --parallel

# Clean build
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" clean

# Quick dev build and run (macOS only, requires `just`)
just run
```

### Running Specific Tests

```bash
# Run a single test class
xcodebuild test -project bitchat.xcodeproj -scheme bitchat -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:bitchatTests/IntegrationTests

# Run a single test method
xcodebuild test -project bitchat.xcodeproj -scheme bitchat -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:bitchatTests/NoiseProtocolTests/testHandshake
```

## Architecture Overview

BitChat is a **dual-transport P2P messaging app**: Bluetooth mesh for offline local communication, Nostr protocol for internet-based global messaging.

### Local Packages (`localPackages/`)

- **BitFoundation**: Shared foundation types — `BinaryProtocol` (compact binary packet format for BLE), `BitchatPacket`, `BitchatMessage`, `PeerID`, hex/SHA256/compression utilities. Has its own test suite under `localPackages/BitFoundation/Tests` (run `swift test` inside the package).
- **BitLogger**: `SecureLogger` logging.
- **Arti**: Tor integration (exposes the `Tor` product).

### Transport Layer

- **BLEService** (`bitchat/Services/BLE/BLEService.swift`): Core Bluetooth LE mesh networking - peer discovery, connection management, multi-hop relay (max 7 hops), packet fragmentation. The BLE directory contains ~40 focused collaborators (handlers, policies, buffers): `BLEReceivePipeline` dispatches inbound packets to `BLEAnnounceHandler` / `BLENoisePacketHandler` / `BLEPublicMessageHandler` / `BLEFragmentHandler` etc.; outbound planning lives in the `BLEOutbound*` types; peer state in `BLEPeerRegistry`.
- **NostrTransport** (`bitchat/Services/NostrTransport.swift`): Internet transport via Nostr relays with NIP-17 encryption
- **Transport protocol** (`bitchat/Services/Transport.swift`): Common interface both transports implement

### Encryption Layer

- **NoiseProtocol** (`bitchat/Noise/`): Noise XX pattern for end-to-end encryption with forward secrecy
  - `NoiseEncryptionService`: Main encryption/decryption API
  - `NoiseSessionManager`: Thread-safe per-peer session management
  - `NoiseSession`: Individual peer session state (handshake, send/receive ciphers)
- **NostrProtocol** (`bitchat/Nostr/NostrProtocol.swift`): NIP-17 gift-wrapped encryption for Nostr messages

### Protocol Layer

- **BinaryProtocol** (`localPackages/BitFoundation/Sources/BitFoundation/BinaryProtocol.swift`): Compact binary packet format for BLE (lives in BitFoundation, not `bitchat/Protocols/`)
- **BitchatProtocol** (`bitchat/Protocols/BitchatProtocol.swift`): Message types and packet structures
- **LocationChannel/Geohash** (`bitchat/Protocols/`): Geographic channel routing

### Application Layer

- **AppRuntime** (`bitchat/App/AppRuntime.swift`): Composition root. Owns `ChatViewModel`, `ConversationStore`, the feature models (`PublicChatModel`, `PeerListModel`, `LocationPresenceStore`, `PeerIdentityStore`, ...), and the app event stream.
- **ConversationStore** (`bitchat/App/ConversationStore.swift`): Single-writer, single source of truth for conversation message state and selection (see `docs/CONVERSATION-STORE-DESIGN.md`). Feature models and `ChatViewModel` observe it and mutate it through its intent API.
- **ChatViewModel** (`bitchat/ViewModels/ChatViewModel.swift`, ~1,600 lines): Central coordinator that wires and delegates to ~25 focused coordinator/pipeline types in `bitchat/ViewModels/`, e.g.:
  - `ChatPrivateConversationCoordinator` / `ChatPublicConversationCoordinator`: DM and public chat flows
  - `ChatNostrCoordinator` → `GeohashSubscriptionManager`, `NostrInboundPipeline`, `GeoPresenceTracker`, `GeoChannelCoordinator`: Nostr/geohash channel logic
  - `ChatOutgoingCoordinator`, `ChatDeliveryCoordinator`, `PublicMessagePipeline`: send paths and delivery tracking
  - `ChatMediaTransferCoordinator`, `ChatMediaPreparation`: media transfers
  - `ChatLifecycleCoordinator`, `ChatTransportEventCoordinator`, `ChatPeerListCoordinator`, `ChatPeerIdentityCoordinator`, `ChatVerificationCoordinator`: lifecycle, transport events, peer state
  - `bitchat/ViewModels/Extensions/` (`ChatViewModel+Nostr/+PrivateChat/+Tor`): thin delegation shims kept for call-site stability; the real logic lives in the coordinators
- **MessageRouter** (`bitchat/Services/MessageRouter.swift`): Intelligent transport selection (BLE → Nostr fallback)
- **PrivateChatManager** (`bitchat/Services/PrivateChatManager.swift`): DM session management

## Test Infrastructure

Tests use an **in-memory networking harness** for deterministic, race-free testing:

- **MockBLEService** (`bitchatTests/Mocks/MockBLEService.swift`): Simulated BLE mesh with configurable topology
  - `MockBLEService.resetTestBus()` - Clear state in setUp()
  - `simulateConnectedPeer(_:)` / `simulateDisconnectedPeer(_:)` - Configure topology
  - `autoFloodEnabled` - Enable broadcast flooding for Integration tests only

- **Test categories**:
  - `bitchatTests/EndToEnd/`: Full message flow tests with explicit routing
  - `bitchatTests/Integration/`: Multi-node topology tests with auto-flooding
  - Unit tests: Individual component tests

## Key Patterns

- **Threading**: Use `@MainActor` for UI, `Task { @MainActor in ... }` for main thread dispatch
- **Delegation**: `BitchatDelegate`, `TransportPeerEventsDelegate` for event propagation
- **Session recovery**: On decrypt failure, clear local session and re-initiate Noise handshake (no NACK)

## Device Setup

To run on physical devices:
1. Copy `Configs/Local.xcconfig.example` to `Configs/Local.xcconfig`
2. Add your Developer Team ID to `Local.xcconfig`
3. Replace `group.chat.bitchat` with `group.<your_bundle_id>` in entitlements
