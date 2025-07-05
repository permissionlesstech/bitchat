# WiFi Direct Integration Plan for BitChat

## Overview

WiFi Direct enables peer-to-peer WiFi connections without requiring an access point, offering significantly higher bandwidth and range compared to Bluetooth Low Energy.

### Key Specifications
- **Range**: 100-200 meters (vs BLE's 10-30m)
- **Speed**: 250+ Mbps (vs BLE's 1-3 Mbps)
- **Power**: Higher consumption than BLE
- **Platform Support**: 
  - iOS: MultipeerConnectivity framework
  - Android: WiFi P2P API
  - macOS: Network.framework with Bonjour

## Alternative Transport Technologies

### Ultrasonic Communication
- **What**: Uses sound waves above human hearing (>20kHz) to transmit data
- **Range**: 1-10 meters typically
- **Speed**: ~1-10 kbps
- **Pros**: Works through thin walls, no radio interference, very low power
- **Cons**: Limited range, sensitive to noise, low bandwidth
- **Use case**: Secret communication in meetings, data transfer when radio is jammed

### LoRa (Long Range)
- **What**: Low-power, wide-area network protocol using sub-GHz frequencies
- **Range**: 2-15 km in rural areas, 2-5 km in urban
- **Speed**: 0.3-50 kbps
- **Pros**: Incredible range, very low power, penetrates buildings well
- **Cons**: Very low bandwidth, requires special hardware, regulated frequencies
- **Use case**: Disaster relief, rural communities, sensor networks

## Architecture Design

### Transport Protocol Interface

```swift
protocol TransportProtocol {
    var transportType: TransportType { get }
    var isAvailable: Bool { get }
    var currentPeers: [PeerInfo] { get }
    
    func startDiscovery()
    func stopDiscovery()
    func send(_ packet: BitchatPacket, to peer: PeerID?) 
    func setDelegate(_ delegate: TransportDelegate)
}

enum TransportType {
    case bluetooth
    case wifiDirect
    case ultrasonic  // future
    case lora        // future
}

// Transport Manager to coordinate multiple transports
class TransportManager {
    private var transports: [TransportProtocol] = []
    private var routingTable: [PeerID: TransportType] = [:]
    
    func sendOptimal(_ packet: BitchatPacket, to peer: PeerID?) {
        // Choose best transport based on:
        // 1. Message size
        // 2. Battery level
        // 3. Available transports
        // 4. Peer capabilities
    }
}
```

## Implementation Phases

### Phase 1: Abstract Transport Layer
1. Create `TransportProtocol` interface
2. Refactor `BluetoothMeshService` to implement protocol
3. Create `TransportManager` to coordinate transports
4. Update `ChatViewModel` to use transport abstraction

### Phase 2: WiFi Direct Transport
1. Create `WiFiDirectTransport` class
2. iOS: Use MultipeerConnectivity framework
3. macOS: Use Network.framework with Bonjour
4. Handle transport handoff (BLE → WiFi when available)

### Phase 3: Intelligent Routing
1. Implement bandwidth detection
2. Create routing algorithm:
   - Small messages (< 1KB): Use BLE (lower power)
   - Large messages/files: Use WiFi Direct
   - Emergency/broadcast: Use all transports
3. Add transport negotiation protocol

### Phase 4: Advanced Features
1. File transfer with resumption
2. Video/audio streaming support
3. Hybrid mesh (some nodes BLE-only, some WiFi-capable)
4. Transport bonding (use multiple simultaneously)

## Key Considerations

### Battery Impact
- WiFi Direct uses significantly more power than BLE
- Only activate when:
  - Large file transfer needed
  - User explicitly enables
  - Device is charging
  - Battery > 50%

### Discovery Strategy
- Use BLE for initial discovery (low power)
- Exchange WiFi Direct capabilities
- Establish WiFi Direct only when needed
- Fall back to BLE if WiFi fails

### Security
- Use same encryption (X25519 + AES-256-GCM)
- Pin WiFi Direct connections with BLE-exchanged keys
- Prevent WiFi Direct spoofing attacks

### User Experience
- Automatic transport selection
- Visual indicator showing active transport
- Manual override option
- Seamless handoff between transports

## Proposed File Structure

```
bitchat/
├── Transports/
│   ├── TransportProtocol.swift
│   ├── TransportManager.swift
│   ├── BluetoothTransport.swift  (refactored from BluetoothMeshService)
│   ├── WiFiDirectTransport.swift  (new)
│   └── TransportDelegate.swift
├── Services/
│   └── RoutingService.swift       (intelligent message routing)
```

## Benefits

1. **10-100x faster** file transfers
2. **Longer range** for fixed installations  
3. **Video chat** capability
4. **Backwards compatible** (BLE-only devices still work)
5. **Future-proof** (easy to add more transports)

## Implementation Notes

### iOS MultipeerConnectivity Example

```swift
import MultipeerConnectivity

class WiFiDirectTransport: NSObject, TransportProtocol {
    private let serviceType = "bitchat-wifi"
    private var peerID: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser: MCNearbyServiceBrowser
    
    func startDiscovery() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }
}
```

### Message Size Routing Logic

```swift
func selectTransport(for message: Data) -> TransportType {
    let size = message.count
    let batteryLevel = BatteryOptimizer.shared.batteryLevel
    
    if size > 10_000 && batteryLevel > 0.5 {
        return .wifiDirect
    } else if size < 1_000 || batteryLevel < 0.3 {
        return .bluetooth
    } else {
        // Medium size, good battery - use faster if available
        return wifiAvailable ? .wifiDirect : .bluetooth
    }
}
```

## Testing Strategy

1. **Unit Tests**: Mock transport implementations
2. **Integration Tests**: BLE + WiFi handoff scenarios
3. **Performance Tests**: Throughput comparison
4. **Battery Tests**: Power consumption analysis
5. **Field Tests**: Real-world range and reliability

## Future Considerations

- **Transport Plugins**: Allow third-party transport implementations
- **SDN Integration**: Software-defined networking for complex topologies
- **QoS**: Quality of Service for different message types
- **Compression**: Different algorithms per transport
- **Multi-path**: Send redundant copies over multiple transports