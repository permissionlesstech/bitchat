# Noise Protocol Migration Guide for BitChat

## Overview

This guide provides step-by-step instructions for integrating the Noise Protocol Framework into BitChat's existing encryption infrastructure while maintaining backward compatibility.

## Prerequisites

1. **Dependencies**
   - Swift 5.5+
   - CryptoKit framework
   - CommonCrypto (for BLAKE2b until CryptoKit adds support)
   - Optional: swift-noise package for production use

2. **Testing Environment**
   - Two or more iOS devices for mesh testing
   - Xcode 14+ with iOS 16+ SDK
   - Unit test framework configured

## Migration Steps

### Step 1: Add Noise Protocol Files

1. Add the following files to your Xcode project:
   ```
   NoiseProtocolImplementation.swift
   NoiseProtocolService.swift (from architecture doc)
   NoiseKeychainManager.swift (from architecture doc)
   CompatibilityService.swift (from architecture doc)
   ```

2. Update your Podfile or Package.swift if using external Noise libraries:
   ```swift
   // Package.swift
   dependencies: [
       .package(url: "https://github.com/swift-libp2p/swift-noise.git", from: "1.0.0")
   ]
   ```

### Step 2: Modify EncryptionService

Add Noise Protocol support to the existing EncryptionService:

```swift
// EncryptionService+Noise.swift
extension EncryptionService {
    
    /// Check if Noise Protocol should be used for peer
    func shouldUseNoiseProtocol(for peerID: String) -> Bool {
        // Check compatibility service
        guard let compatibilityService = BluetoothMeshService.shared.compatibilityService else {
            return false
        }
        
        return compatibilityService.peerSupportsNoise(peerID)
    }
    
    /// Get static key pair for Noise Protocol
    func getNoiseStaticKeyPair() throws -> (privateKey: Data, publicKey: Data) {
        // Use existing identity key infrastructure
        guard let identityKey = self.identityKey else {
            throw EncryptionError.keychainError(NoiseError.missingKey)
        }
        
        // Convert signing key to key agreement key
        // Note: In production, maintain separate keys for signing and Noise
        let keyData = identityKey.rawRepresentation
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
        
        return (privateKey.rawRepresentation, privateKey.publicKey.rawRepresentation)
    }
    
    /// Store Noise session keys
    func storeNoiseSessionKeys(for peerID: String, sendKey: Data, receiveKey: Data) throws {
        // Store in existing sharedSecrets structure
        // In production, use separate storage for Noise keys
        let combinedKey = sendKey + receiveKey
        let symmetricKey = SymmetricKey(data: combinedKey)
        
        cryptoQueue.sync(flags: .barrier) {
            sharedSecrets[peerID] = symmetricKey
        }
    }
}
```

### Step 3: Update BluetoothMeshService

Integrate Noise Protocol handshakes into the mesh service:

```swift
// BluetoothMeshService+Noise.swift
extension BluetoothMeshService {
    
    /// Initialize Noise Protocol support
    func initializeNoiseProtocol() {
        self.noiseProtocolService = NoiseProtocolService(encryptionService: encryptionService)
        self.compatibilityService = CompatibilityService()
    }
    
    /// Override processPacket to handle Noise messages
    func processPacketWithNoise(_ packet: BitchatPacket) {
        // Check if this is a Noise Protocol message
        if packet.type >= 0x10 && packet.type <= 0x13 {
            processNoiseMessage(packet)
            return
        }
        
        // Handle regular messages
        switch MessageType(rawValue: packet.type) {
        case .announce:
            // Include Noise capability in announcements
            var announceData = packet.payload
            let capabilities = compatibilityService.createCapabilityAnnouncement()
            announceData.append(capabilities)
            processAnnouncement(announceData, from: packet.senderID)
            
        case .keyExchange:
            // Check if peer supports Noise
            let senderID = String(data: packet.senderID, encoding: .utf8) ?? ""
            if compatibilityService.peerSupportsNoise(senderID) {
                // Upgrade to Noise Protocol
                initiateNoiseHandshake(with: senderID)
            } else {
                // Use legacy key exchange
                processLegacyKeyExchange(packet)
            }
            
        default:
            // Process normally
            processPacket(packet)
        }
    }
    
    /// Send message with Noise encryption if available
    override func sendMessage(_ content: String, to recipient: String?) {
        guard let recipientID = recipient else {
            // Broadcast message - use legacy encryption
            super.sendMessage(content, to: nil)
            return
        }
        
        // Check if we have Noise session
        if noiseProtocolService?.hasActiveSession(with: recipientID) == true {
            sendNoiseEncryptedMessage(content, to: recipientID)
        } else if compatibilityService?.peerSupportsNoise(recipientID) == true {
            // Initiate Noise handshake first
            initiateNoiseHandshake(with: recipientID)
            // Queue message for sending after handshake
            queueMessageForHandshake(content, to: recipientID)
        } else {
            // Use legacy encryption
            super.sendMessage(content, to: recipientID)
        }
    }
    
    private func sendNoiseEncryptedMessage(_ content: String, to recipientID: String) {
        guard let messageData = content.data(using: .utf8),
              let encrypted = try? noiseProtocolService?.encryptMessage(messageData, for: recipientID) else {
            return
        }
        
        let packet = BitchatPacket(
            type: NoiseMessageType.transportMessage.rawValue,
            senderID: myPeerID.data(using: .utf8)!,
            recipientID: recipientID.data(using: .utf8),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: encrypted,
            signature: nil,
            ttl: adaptiveTTL
        )
        
        sendPacket(packet, to: recipientID)
    }
}
```

### Step 4: Update BitchatProtocol

Add Noise Protocol message types:

```swift
// In MessageType enum
enum MessageType: UInt8 {
    // ... existing types ...
    
    // Noise Protocol messages (0x10-0x1F reserved)
    case noiseHandshakeInit = 0x10
    case noiseHandshakeResp = 0x11
    case noiseHandshakeComplete = 0x12
    case noiseTransport = 0x13
    case noiseRekey = 0x14
    case noiseCapabilityAnnounce = 0x15
}
```

### Step 5: Implement Gradual Rollout

Create a feature flag system for gradual deployment:

```swift
// FeatureFlags.swift
struct FeatureFlags {
    static var noiseProtocolEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: "NoiseProtocolEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "NoiseProtocolEnabled")
        }
    }
    
    static var noiseProtocolPercentage: Int {
        get {
            UserDefaults.standard.integer(forKey: "NoiseProtocolPercentage")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "NoiseProtocolPercentage")
        }
    }
    
    static func shouldUseNoiseProtocol(for peerID: String) -> Bool {
        guard noiseProtocolEnabled else { return false }
        
        // Use peer ID hash for deterministic rollout
        let hash = peerID.hash
        let percentage = abs(hash) % 100
        
        return percentage < noiseProtocolPercentage
    }
}
```

### Step 6: Update UI for User Control

Add settings for Noise Protocol:

```swift
// SettingsView+Noise.swift
struct NoiseProtocolSettings: View {
    @State private var noiseEnabled = FeatureFlags.noiseProtocolEnabled
    @State private var preferredPattern = "XX"
    @State private var showAdvanced = false
    
    var body: some View {
        Section(header: Text("Enhanced Encryption (Beta)")) {
            Toggle("Enable Noise Protocol", isOn: $noiseEnabled)
                .onChange(of: noiseEnabled) { value in
                    FeatureFlags.noiseProtocolEnabled = value
                }
            
            if noiseEnabled {
                Picker("Handshake Pattern", selection: $preferredPattern) {
                    Text("XX - Mutual Authentication").tag("XX")
                    Text("IK - Known Peers").tag("IK")
                    Text("NK - Anonymous Mode").tag("NK")
                }
                
                if showAdvanced {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Active Sessions: \(activeSessionCount)")
                            .font(.caption)
                        Text("Protocol Version: Noise_*_25519_ChaChaPoly_BLAKE2b")
                            .font(.caption)
                        Button("Clear All Sessions") {
                            clearAllNoiseSessions()
                        }
                        .foregroundColor(.red)
                    }
                }
                
                Button(showAdvanced ? "Hide Advanced" : "Show Advanced") {
                    showAdvanced.toggle()
                }
            }
        }
    }
}
```

### Step 7: Testing Strategy

1. **Unit Tests**
   ```swift
   func testNoiseXXHandshake() {
       // Test complete XX handshake
   }
   
   func testBackwardCompatibility() {
       // Ensure legacy encryption still works
   }
   
   func testMixedProtocolMesh() {
       // Test mesh with both Noise and legacy nodes
   }
   ```

2. **Integration Tests**
   - Set up test mesh with 3+ devices
   - Enable Noise on subset of devices
   - Verify message delivery across protocols
   - Test handshake failures and recovery

3. **Performance Tests**
   - Measure handshake completion time
   - Compare encryption/decryption speed
   - Monitor battery impact
   - Test with various message sizes

### Step 8: Monitoring and Rollback

Implement telemetry for production monitoring:

```swift
// NoiseProtocolTelemetry.swift
struct NoiseProtocolMetrics {
    static func recordHandshakeStart(pattern: String) {
        // Log to analytics
    }
    
    static func recordHandshakeComplete(pattern: String, duration: TimeInterval) {
        // Log success metrics
    }
    
    static func recordHandshakeFailure(pattern: String, error: Error) {
        // Log failure for monitoring
    }
    
    static func recordMessageEncrypted(size: Int) {
        // Track usage
    }
}
```

### Step 9: Migration Timeline

**Week 1-2**: Development
- Implement core Noise Protocol
- Add compatibility layer
- Update mesh service

**Week 3-4**: Testing
- Unit test coverage
- Integration testing
- Performance benchmarking

**Week 5-6**: Beta Release
- 10% rollout to beta users
- Monitor metrics
- Fix identified issues

**Week 7-8**: Gradual Rollout
- 25% -> 50% -> 75% -> 100%
- Monitor each stage for 48 hours
- Rollback capability ready

**Week 9-10**: Full Deployment
- Enable by default for new users
- Migration tools for existing users
- Documentation updates

## Troubleshooting

### Common Issues

1. **Handshake Timeouts**
   - Check Bluetooth connection stability
   - Verify packet size constraints
   - Review retry logic

2. **Key Mismatch**
   - Ensure proper key storage
   - Check keychain access
   - Verify key rotation timing

3. **Performance Degradation**
   - Profile handshake operations
   - Check for excessive retries
   - Monitor memory usage

### Debug Tools

```swift
// Enable verbose logging
NoiseProtocolService.debugLogging = true

// Dump session state
noiseService.dumpSessionState(for: peerID)

// Force protocol downgrade
compatibilityService.forceProtocol(.legacy, for: peerID)
```

## Security Considerations

1. **Key Storage**
   - Use iOS Keychain with biometric protection
   - Separate Noise keys from legacy keys
   - Implement secure key deletion

2. **Protocol Downgrade**
   - Prevent forced downgrades
   - Log protocol selection
   - Alert users of security changes

3. **Forward Secrecy**
   - Ephemeral keys per session
   - Regular key rotation
   - Secure key derivation

## Conclusion

This migration guide provides a comprehensive path to integrating Noise Protocol into BitChat while maintaining the core mesh networking functionality and ensuring backward compatibility. The phased approach allows for careful monitoring and rollback if needed.

**Author:** Unit 221B  
**Contact:** Lance James - lancejames@unit221b.com  
**Last Updated:** 2025-01-09