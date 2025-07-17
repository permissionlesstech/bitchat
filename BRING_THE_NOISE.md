# Bringing the Noise: Secure Communication in BitChat

## Overview

BitChat implements the Noise Protocol Framework for end-to-end encryption, providing forward secrecy, identity hiding, and cryptographic authentication. This document details our Swift implementation and its integration with BitChat's decentralized mesh network.

## The Noise Protocol Framework

### Why Noise?

The Noise Protocol Framework offers:
- **Forward Secrecy**: Past messages remain secure even if keys are compromised
- **Identity Hiding**: Peer identities are encrypted during handshake
- **Simplicity**: Clean, auditable protocol with minimal complexity
- **Performance**: Efficient for resource-constrained mobile devices
- **Flexibility**: Supports various handshake patterns

### The XX Pattern

BitChat uses the Noise XX pattern:
```
XX:
  -> e
  <- e, ee, s, es
  -> s, se
```

This three-message pattern provides:
- Mutual authentication
- Identity encryption (identities revealed only after initial key exchange)
- Resistance to key-compromise impersonation

## Implementation Architecture

### Core Components

#### NoiseEncryptionService
The main service managing all Noise operations:
```swift
class NoiseEncryptionService {
    private let staticIdentityKey: Curve25519.KeyAgreement.PrivateKey
    private let sessionManager: NoiseSessionManager
    private let channelEncryption = NoiseChannelEncryption()
}
```

#### NoiseSession
Individual session state for each peer:
```swift
class NoiseSession {
    private var handshakeState: NoiseHandshakeState?
    private var sendCipher: NoiseCipherState?
    private var receiveCipher: NoiseCipherState?
    private let remoteStaticKey: Curve25519.KeyAgreement.PublicKey?
}
```

#### NoiseSessionManager
Thread-safe session management:
```swift
class NoiseSessionManager {
    private var sessions: [String: NoiseSession] = [:]
    private let sessionsQueue = DispatchQueue(label: "noise.sessions", attributes: .concurrent)
}
```

### Handshake Flow

1. **Initiator sends ephemeral key**
   ```swift
   let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
   let message = ephemeralKey.publicKey.rawRepresentation
   ```

2. **Responder sends ephemeral + encrypted static**
   ```swift
   // Generate ephemeral, perform DH, encrypt static key
   let encryptedStatic = encrypt(staticKey, using: sharedSecret)
   ```

3. **Initiator sends encrypted static**
   ```swift
   // Complete handshake, derive session keys
   let (sendKey, recvKey) = deriveSessionKeys(transcript)
   ```

### Session Management

Sessions are managed with automatic cleanup and rekey support:

```swift
// Session lookup by peer ID
func getSession(for peerID: String) -> NoiseSession?

// Automatic session removal on disconnect
func removeSession(for peerID: String)

// Rekey detection
func getSessionsNeedingRekey() -> [(String, Bool)]
```

## Integration with BitChat

### Peer ID Rotation

Noise sessions persist across peer ID rotations through fingerprint mapping:

```swift
// Identity announcement after handshake
struct NoiseIdentityAnnouncement {
    let peerID: String
    let publicKey: Data
    let nickname: String
    let previousPeerID: String?
    let signature: Data
}
```

### Message Encryption

All messages are encrypted using established Noise sessions:

```swift
// Encrypt message
let encrypted = try noiseService.encrypt(messageData, for: peerID)

// Decrypt message  
let decrypted = try noiseService.decrypt(encryptedData, from: peerID)
```

### Channel Encryption

Password-protected channels use Noise for key distribution:

```swift
// Share channel key securely
let keyPacket = createChannelKeyPacket(password: password, channel: channel)
let encrypted = try encrypt(keyPacket, for: peerID)
```

## Security Properties

### Forward Secrecy
- Ephemeral keys are generated for each handshake
- Past sessions cannot be decrypted with current keys
- Automatic rekey after 1 hour or 10,000 messages

### Authentication
- Static keys provide long-term identity
- Handshake ensures mutual authentication
- MAC tags prevent message tampering

### Privacy
- Peer identities encrypted during handshake
- Metadata minimization through padding
- No persistent session identifiers

## Implementation Details

### Key Derivation
```swift
// HKDF for key derivation
func hkdf(salt: Data, ikm: Data, info: Data, length: Int) -> Data

// Derive channel keys with PBKDF2
func deriveChannelKey(password: String, salt: Data) -> SymmetricKey
```

### Cryptographic Primitives
- **DH**: X25519 (Curve25519)
- **Cipher**: ChaChaPoly (AEAD)
- **Hash**: SHA-256
- **KDF**: HKDF-SHA256

### Error Handling
```swift
enum NoiseError: Error {
    case handshakeFailed
    case invalidMessage
    case sessionNotEstablished
    case decryptionFailed
}
```

## Performance Optimizations

### Connection Pooling
- Reuse established sessions
- Lazy handshake initiation
- Session caching with TTL

### Message Batching
- Combine small messages
- Reduce encryption overhead
- Optimize for BLE MTU

### Memory Management
- Bounded session cache
- Automatic cleanup of stale sessions
- Efficient key rotation

## Protocol Version Negotiation

BitChat implements protocol version negotiation to ensure compatibility between different client versions:

### Version Negotiation Flow
1. **Version Hello**: Upon connection, peers exchange supported protocol versions
2. **Version Agreement**: Peers agree on the highest common version
3. **Graceful Fallback**: Legacy peers without version negotiation assume protocol v1

### Message Types
```swift
case versionHello = 0x20    // Announce supported versions
case versionAck = 0x21      // Acknowledge and agree on version
```

### Backward Compatibility
- Peers that don't send version negotiation messages are assumed to support v1
- Future protocol versions can be added to `ProtocolVersion.supportedVersions`
- Incompatible peers receive a rejection message and disconnect gracefully

## Future Enhancements

### Post-Quantum Readiness
- Hybrid handshake patterns
- Kyber integration plans
- Graceful algorithm migration

### Advanced Features
- Multi-device support
- Session backup/restore
- Group messaging primitives

## Conclusion

BitChat's Noise implementation provides encryption while maintaining the simplicity and performance required for a peer-to-peer messaging application. The protocol's elegant design ensures that people's communications remain private, authenticated, and forward-secure without sacrificing usability.
