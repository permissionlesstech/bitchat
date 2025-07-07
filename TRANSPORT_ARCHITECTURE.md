# Smart Transport Architecture

## Overview

The smart transport system enables bitchat to efficiently use multiple transport layers (Bluetooth and WiFi Direct) while optimizing for power consumption and range. The system automatically selects the best transport for each peer and enables bridging between networks.

## Design Principles

1. **Power Efficiency First**: Always prefer Bluetooth when available
2. **One Transport Per Peer**: Each peer pair uses exactly one transport method
3. **Automatic Bridging**: Devices with connections on multiple transports act as bridges
4. **Transparent Routing**: Message delivery is transport-agnostic from the user's perspective
5. **Unified Identity**: One device ID and signing key across all transports

## Architecture Components

### 1. DeviceIdentity (✓ Implemented)
- Singleton providing consistent device ID across all transports
- P256 signing keys for message authentication
- Persistent identity stored in keychain

### 2. PeerManager (New)
```swift
class PeerManager {
    // Maps peerID -> preferred transport type
    private var peerTransportMap: [String: TransportType] = [:]
    
    // Maps peerID -> last seen on each transport
    private var peerTransportVisibility: [String: [TransportType: Date]] = [:]
    
    // Determines best transport for a peer based on:
    // 1. Current availability
    // 2. Signal strength
    // 3. Power efficiency
    func selectTransport(for peerID: String) -> TransportType
    
    // Updates peer visibility when seen on a transport
    func updatePeerVisibility(peerID: String, on transport: TransportType)
}
```

### 3. TransportManager (Refactor)
Current issues:
- Global forceWiFiDirect flag affects all peers
- No per-peer transport selection
- Activation logic is too simplistic

Proposed changes:
```swift
class TransportManager {
    private let peerManager = PeerManager()
    
    // Smart activation based on peer count
    func updateTransportActivation() {
        let btPeerCount = transports[.bluetooth]?.currentPeers.count ?? 0
        
        if btPeerCount < 2 && !wifiDirectEnabled {
            // Few BT peers, activate WiFi to find more
            activateTransport(.wifiDirect)
        } else if btPeerCount > 5 && wifiDirectEnabled {
            // Many BT peers, can deactivate WiFi to save power
            deactivateTransport(.wifiDirect)
        }
    }
    
    // Route message to specific peer using best transport
    func sendMessage(_ packet: BitchatPacket, to peerID: String) {
        let transport = peerManager.selectTransport(for: peerID)
        transports[transport]?.send(packet, to: peerID)
    }
}
```

### 4. Bridge Routing
When a device has peers on multiple transports, it automatically bridges:

```
[BT Network A] <--BT--> [Bridge Device] <--WiFi--> [WiFi Network B]
```

Bridge logic:
1. If message received on BT for unknown peer, check WiFi peers
2. If message received on WiFi for unknown peer, check BT peers
3. Forward with decremented TTL to prevent loops

### 5. Unified Key Exchange

Current issues:
- Key size mismatch (160 vs 161 bytes)
- Different key formats on different transports
- P256 vs Curve25519 confusion

Solution:
```swift
struct UnifiedKeyExchange {
    // Fixed 161-byte format:
    // [0-31]: Curve25519 encryption key (32 bytes)
    // [32-63]: Curve25519 signing key (32 bytes) 
    // [64-95]: Curve25519 identity key (32 bytes)
    // [96-160]: P256 signing key (65 bytes, x963 format)
    
    static func encode(encryption: EncryptionService) -> Data {
        var data = Data()
        data.append(encryption.publicKey.rawRepresentation) // 32
        data.append(encryption.signingPublicKey.rawRepresentation) // 32
        data.append(encryption.identityPublicKey.rawRepresentation) // 32
        data.append(DeviceIdentity.shared.publicKeyData) // 65 (x963)
        return data // Total: 161
    }
}
```

## Implementation Plan

### Phase 1: Fix Immediate Issues
1. Fix key exchange to use consistent 161-byte format
2. Ensure P256 keys use x963Representation (65 bytes)
3. Fix crash on iPhone

### Phase 2: Implement PeerManager
1. Create PeerManager class
2. Track peer visibility across transports
3. Implement transport selection algorithm

### Phase 3: Refactor TransportManager
1. Remove global forceWiFiDirect
2. Implement per-peer routing
3. Add smart activation logic

### Phase 4: Implement Bridging
1. Add bridge detection logic
2. Implement cross-transport forwarding
3. Test multi-hop scenarios

### Phase 5: Optimization
1. Add RSSI-based transport selection
2. Implement connection quality monitoring
3. Add power usage tracking

## Message Flow

### Direct Communication (Same Transport)
```
Device A (BT) --> Device B (BT)
```

### Bridged Communication (Cross Transport)
```
Device A (BT) --> Bridge (BT) --> Bridge (WiFi) --> Device C (WiFi)
```

### Transport Selection Algorithm
```
1. Check if peer is visible on any transport
2. If visible on multiple:
   - Prefer Bluetooth (lower power)
   - Unless RSSI is very poor (<-80 dBm)
3. If not visible:
   - Try last known transport
   - Broadcast on all active transports
4. Update peer transport map based on successful delivery
```

## Testing Scenarios

1. **Two devices, Bluetooth only**: Should work as before
2. **Two devices, no Bluetooth peers**: Should activate WiFi Direct
3. **Three devices in line**: Middle device should bridge
4. **Mixed network**: Some on BT, some on WiFi, bridges connect them
5. **Power efficiency**: Verify BT preferred when available

## Success Metrics

- Messages delivered reliably across all scenarios
- Bluetooth used when available (power efficiency)
- WiFi Direct activates automatically when needed
- Seamless bridging between networks
- No duplicate messages
- Consistent identity across transports