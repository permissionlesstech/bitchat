# SatMesh Extension for BitChat

## Overview

SatMesh is a satellite networking extension for BitChat that enables global communication beyond the local Bluetooth mesh network. It provides emergency broadcasting, global messaging, and hybrid routing capabilities using satellite IoT networks.

## Architecture

### Core Components

```
BitChat Core (existing)
├── Bluetooth Mesh Protocol
├── End-to-End Encryption
├── Message Fragmentation
└── Privacy Mechanisms

SatMesh Extension (new)
├── Satellite Protocol Adapter
├── Multi-Path Routing Engine
├── Bandwidth Optimization
├── Store-and-Forward Satellite Queue
└── Emergency Broadcast System
```

### Key Services

1. **SatelliteProtocolAdapter** - Handles communication with satellite IoT modules
2. **MultiPathRoutingEngine** - Intelligent routing across Bluetooth and satellite networks
3. **BandwidthOptimizer** - Message compression and deduplication for satellite efficiency
4. **SatelliteQueueService** - Priority-based message queuing and store-and-forward
5. **EmergencyBroadcastSystem** - SOS messaging and emergency coordination
6. **SatMeshIntegrationService** - Main coordinator for all satellite services

## Features

### Message Prioritization

- **Emergency messages** get satellite priority (SOS, medical, disaster)
- **Regular messages** queue for next satellite pass
- **Local messages** stay in Bluetooth mesh when possible

### Bandwidth Optimization

- **Compression algorithms**: LZ4, ZLIB, LZFSE
- **Message deduplication** across network layers
- **Smart batching** for efficient transmission
- **Cost optimization** based on message size and priority

### Global Addressing

- **Extended peer ID system** for global routing
- **Location-aware message routing**
- **"Message postcards"** - short messages that travel via satellite

### Emergency Features

- **SOS broadcasting** via satellite
- **Disaster area mesh-to-satellite bridging**
- **Emergency contact synchronization** across regions
- **Multi-type emergency support** (medical, security, weather, etc.)

## Installation

### Prerequisites

- BitChat app (existing installation)
- Satellite IoT module (Iridium, Starlink, or Globalstar)
- iOS 15.0+ or macOS 12.0+

### Setup

1. **Enable SatMesh** in the app settings
2. **Configure satellite connection** (constellation, credentials)
3. **Set emergency contacts** for SOS functionality
4. **Adjust bandwidth settings** based on your data plan

## Usage

### Emergency Broadcasting

#### Send SOS
```swift
// Quick SOS with location
satMeshViewModel.sendSOS()

// Custom emergency message
let emergency = EmergencyMessage(
    emergencyType: .medical,
    senderID: "user123",
    senderNickname: "John",
    content: "Need medical assistance",
    location: currentLocation
)
satMeshService.sendEmergencyMessage(emergency)
```

#### Emergency Types
- `sos` - General SOS
- `medical` - Medical emergency
- `disaster` - Natural disaster
- `security` - Security threat
- `weather` - Weather emergency
- `fire`, `flood`, `earthquake`, `tsunami` - Specific disasters

### Global Messaging

#### Send Global Message
```swift
let globalMessage = BitchatMessage(
    sender: "User",
    content: "Hello world!",
    timestamp: Date(),
    isRelay: false,
    senderPeerID: "user123"
)

// Normal priority
satMeshService.sendGlobalMessage(globalMessage, priority: 1)

// High priority
satMeshService.sendGlobalMessage(globalMessage, priority: 2)

// Emergency priority
satMeshService.sendGlobalMessage(globalMessage, priority: 3)
```

### Configuration

#### SatMesh Configuration
```swift
let config = SatMeshConfig(
    enableSatellite: true,
    enableEmergencyBroadcast: true,
    enableGlobalRouting: true,
    maxMessageSize: 500,
    compressionEnabled: true,
    costLimit: 10.0,
    preferredSatellite: "iridium"
)

satMeshService.updateConfiguration(config)
```

#### Bandwidth Optimization
```swift
// Set optimization strategy
bandwidthOptimizer.setOptimizationStrategy(.maximumCompression)

// Available strategies:
// - .maximumCompression - Best compression ratio
// - .balancedCompression - Good balance of speed and compression
// - .minimumLatency - Fastest compression
// - .costOptimized - Optimize for cost
// - .emergencyMode - Fastest for emergencies
```

## API Reference

### SatMeshIntegrationService

#### Main Interface
```swift
class SatMeshIntegrationService: ObservableObject {
    // Send messages
    func sendGlobalMessage(_ message: BitchatMessage, priority: UInt8)
    func sendEmergencyMessage(_ emergency: EmergencyMessage)
    func sendSOS(from location: CLLocationCoordinate2D?)
    
    // Configuration
    func updateConfiguration(_ config: SatMeshConfig)
    func restartServices()
    func clearAllData()
    
    // Status
    var status: SatMeshStatus
    var isConnected: Bool
    var stats: SatMeshStats
}
```

### EmergencyBroadcastSystem

#### Emergency Management
```swift
class EmergencyBroadcastSystem: ObservableObject {
    // Emergency operations
    func broadcastEmergency(_ emergency: EmergencyMessage)
    func sendSOS(from location: CLLocationCoordinate2D?)
    func acknowledgeEmergency(_ emergency: EmergencyMessage, responder: EmergencyResponder)
    func resolveEmergency(_ emergency: EmergencyMessage)
    
    // Contact management
    func addEmergencyContact(_ contact: EmergencyContact)
    func syncEmergencyContacts()
    
    // Status
    var activeEmergencies: [EmergencyMessage]
    var emergencyContacts: [EmergencyContact]
}
```

### MultiPathRoutingEngine

#### Routing Interface
```swift
class MultiPathRoutingEngine: ObservableObject {
    // Route calculation
    func routeMessage(_ request: RoutingRequest) -> RoutingDecision
    
    // Network management
    func addNode(_ node: NetworkNode)
    func removeNode(_ nodeID: String)
    
    // Statistics
    func getRoutingStatistics() -> RoutingStatistics
    func reportDeliverySuccess(for messageID: String)
    func reportDeliveryFailure(for messageID: String, reason: String)
}
```

## Network Topology

### Node Types
- `bluetoothMesh` - Standard BitChat nodes
- `satelliteGateway` - Satellite access points
- `hybridGateway` - Combined Bluetooth/satellite nodes
- `emergencyRelay` - Emergency response nodes

### Routing Strategies
- `singlePath` - Single optimal route
- `multiPath` - Multiple redundant routes
- `storeAndForward` - Cost-optimized delayed delivery
- `emergencyBypass` - Direct emergency routing
- `localOnly` - Bluetooth mesh only

## Cost Management

### Satellite Data Costs
- **Iridium SBD**: ~$0.10 per message
- **Starlink**: ~$0.01 per message
- **Globalstar**: ~$0.05 per message

### Optimization Features
- **Message compression** (30-70% size reduction)
- **Deduplication** (eliminates duplicate messages)
- **Smart queuing** (batches messages for efficiency)
- **Cost limits** (prevents excessive spending)

## Emergency Response

### SOS Protocol
1. **User sends SOS** via app or hardware button
2. **Location included** automatically (if enabled)
3. **Satellite broadcast** to all connected gateways
4. **Emergency services notified** via satellite network
5. **Response coordination** through emergency system

### Emergency Types and Response
- **SOS**: Immediate satellite broadcast, all responders
- **Medical**: Medical responders, hospitals, emergency services
- **Disaster**: Disaster response teams, government agencies
- **Security**: Law enforcement, security services
- **Weather**: Weather services, evacuation coordination

## Development

### Adding New Features

#### Custom Emergency Types
```swift
extension EmergencyType {
    case customEmergency = "custom"
    
    var displayName: String {
        switch self {
        case .customEmergency: return "Custom Emergency"
        default: return super.displayName
        }
    }
}
```

#### Custom Satellite Protocols
```swift
class CustomSatelliteModem: SatelliteModem {
    override func sendMessage(_ data: Data) {
        // Implement custom satellite protocol
    }
    
    override func connect() {
        // Custom connection logic
    }
}
```

### Testing

#### Unit Tests
```bash
# Run SatMesh tests
xcodebuild test -scheme bitchat -destination 'platform=iOS Simulator,name=iPhone 14'
```

#### Integration Tests
```swift
// Test emergency broadcasting
func testEmergencyBroadcast() {
    let emergency = EmergencyMessage(...)
    satMeshService.sendEmergencyMessage(emergency)
    
    // Verify satellite transmission
    XCTAssertTrue(satelliteAdapter.isConnected)
    XCTAssertEqual(satelliteAdapter.sentMessages.count, 1)
}
```

## Deployment

### Hardware Requirements

#### Satellite Gateway Device
- **Satellite modem** (Iridium 9603, Starlink terminal, etc.)
- **Bluetooth module** for local mesh connectivity
- **GPS module** for location services
- **Battery backup** for emergency power
- **Solar panels** for remote deployment

#### Mobile Device
- **iOS 15.0+** or **macOS 12.0+**
- **Bluetooth 5.0+** for mesh networking
- **GPS** for location services
- **Internet connection** for initial setup

### Deployment Phases

#### Phase 1: Proof of Concept
- [x] Integrate satellite IoT module with BitChat
- [x] Implement basic message bridging
- [x] Create gateway device prototype

#### Phase 2: Protocol Development
- [x] Develop hybrid routing algorithms
- [x] Implement bandwidth optimization
- [x] Add encryption for satellite segments

#### Phase 3: Hardware Integration
- [ ] Design compact satellite gateway devices
- [ ] Optimize power consumption
- [ ] Create mobile/portable solutions

#### Phase 4: Global Network
- [ ] Deploy satellite gateways in key locations
- [ ] Implement global message routing
- [ ] Add emergency response features

## Troubleshooting

### Common Issues

#### Satellite Connection Problems
1. **Check modem status** in satellite panel
2. **Verify antenna connection** and orientation
3. **Check account status** and data plan
4. **Restart satellite services** via configuration

#### Message Delivery Issues
1. **Check queue status** for pending messages
2. **Verify routing decisions** in satellite panel
3. **Check bandwidth optimization** settings
4. **Review cost limits** and billing status

#### Emergency System Issues
1. **Verify emergency contacts** are configured
2. **Check location services** are enabled
3. **Test SOS functionality** in safe environment
4. **Review emergency broadcast** settings

### Debug Information

#### Enable Debug Logging
```swift
// Add to app configuration
UserDefaults.standard.set(true, forKey: "satmesh.debug")
```

#### View Debug Information
- **Satellite Status Panel**: Connection details, signal strength
- **Queue Status**: Message counts, transmission history
- **Routing Statistics**: Success rates, latency metrics
- **Bandwidth Stats**: Compression ratios, cost tracking

## Security

### Encryption
- **End-to-end encryption** for all messages
- **Satellite segment encryption** for transmission
- **Key management** via existing BitChat system
- **Privacy-preserving routing** to prevent tracking

### Privacy
- **No message content logging** on satellite servers
- **Minimal metadata** for routing purposes only
- **User-controlled data retention** settings
- **Emergency override** for critical situations

## License

This SatMesh extension is released into the public domain, following the same license as the original BitChat project.

## Contributing

### Development Setup
1. **Fork the repository**
2. **Create feature branch** for your changes
3. **Implement and test** your feature
4. **Submit pull request** with detailed description

### Code Style
- Follow existing Swift style guidelines
- Add comprehensive documentation
- Include unit tests for new features
- Update README for user-facing changes

## Support

### Documentation
- **API Reference**: See inline code documentation
- **User Guide**: Check app help system
- **Developer Guide**: This README file

### Community
- **GitHub Issues**: Report bugs and feature requests
- **Discussions**: General questions and support
- **Wiki**: Additional documentation and guides

---

**SatMesh Extension** - Global communication for BitChat
*Built for emergency response, remote operations, and privacy-critical scenarios* 