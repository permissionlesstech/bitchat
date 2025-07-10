# BitChat Security Fork

**A security-enhanced fork of BitChat with comprehensive vulnerability patches and Noise Protocol support**

**Author**: Lance James, Unit 221B  
**Contact**: lancejames@unit221b.com

## Overview

This fork addresses critical security vulnerabilities in the original BitChat while preserving its innovative mesh networking capabilities. We've implemented defense-in-depth security measures including mutual authentication, secure key storage, and the Noise Protocol Framework.

**Pull Request with Fixes**: https://github.com/jackjackbits/bitchat/pull/77  
**Security Disclosure**: See [SECURITY_DISCLOSURE.md](SECURITY_DISCLOSURE.md) for vulnerability details

## Key Security Enhancements

### Authentication & Access Control
- **Secure Mode Toggle**: Optional PIN-based pairing that preserves auto-connect when disabled
- **Device Whitelisting**: Manage trusted devices for automatic connections
- **Mutual Authentication**: Both peers verify identity during connection

### Cryptographic Improvements
- **Noise Protocol**: Complete implementation of Noise_XX pattern for enhanced security
- **Per-Message Forward Secrecy**: Unique keys for each message
- **Secure Key Storage**: All keys stored in iOS Keychain with hardware encryption
- **Enhanced Key Derivation**: Proper HKDF with unique salts

### Protocol Security
- **Buffer Overflow Protection**: Comprehensive bounds checking
- **Replay Attack Prevention**: Message number tracking with 30-second window
- **Rate Limiting**: 10 messages/second per peer
- **Connection Throttling**: Maximum 50 concurrent peers

### Privacy Features
- **Message Padding**: PKCS#7 padding to standard block sizes
- **Traffic Analysis Resistance**: Randomized timing and cover traffic
- **Emergency Data Wipe**: Triple-tap to clear all data
- **No Persistent Identifiers**: 256-bit ephemeral peer IDs

## Noise Protocol Integration

This fork includes a complete Noise Protocol implementation for enterprise-grade security:

- **Pattern**: Noise_XX_25519_ChaChaPoly_SHA256
- **Benefits**: Mutual authentication, forward secrecy, replay protection
- **Compatibility**: Graceful fallback for non-Noise peers
- **Performance**: ~50-100ms handshake, 1-2ms per message overhead

See [NOISE_PROTOCOL_README.md](NOISE_PROTOCOL_README.md) for implementation details.

## Building

### Requirements
- Xcode 14.0+
- iOS 16.0+ deployment target
- XcodeGen (install via: `brew install xcodegen`)

### Build Instructions

```bash
# Clone repository
git clone https://github.com/yourusername/bitchat-secure-fork.git
cd bitchat-secure-fork

# Generate Xcode project
xcodegen

# Build for iOS Simulator
xcodebuild -scheme bitchat_iOS -destination "platform=iOS Simulator,name=iPhone 16" build

# Or open in Xcode
open bitchat.xcodeproj
```

## Usage

### Secure Mode Configuration

Enable enhanced security features:

```swift
// Enable secure mode (requires PIN pairing)
authenticationService.isSecureModeEnabled = true

// Check Noise Protocol status
let isSecure = meshService.isNoiseHandshakeComplete(for: peerID)
```

### Chat Commands

- `/j #channel` - Join or create a channel
- `/m @name message` - Send private message
- `/w` - List online users
- `/channels` - Show discovered channels
- `/pass [password]` - Set channel password (owner only)
- `/save` - Toggle message retention (owner only)
- `/block @name` - Block a peer
- `/clear` - Clear chat messages

## Technical Architecture

### Bluetooth Mesh Network
- Automatic peer discovery via BLE advertisement
- Multi-hop message relay with TTL-based routing
- Store-and-forward for offline message delivery
- Adaptive duty cycling for battery optimization

### Encryption Stack
- **Transport Layer**: Noise Protocol (when secure mode enabled)
- **Message Layer**: X25519 + AES-256-GCM
- **Channel Encryption**: Argon2id + AES-256-GCM
- **Digital Signatures**: Ed25519

### Performance Optimizations
- LZ4 compression for messages >100 bytes
- Bloom filters for duplicate detection
- Message aggregation to reduce transmissions
- Battery-aware power modes

## Security Considerations

### Threat Model
- **Protected Against**: Local attackers, casual eavesdropping, message tampering
- **Not Protected Against**: Traffic analysis by sophisticated adversaries
- **Assumptions**: iOS platform security, Keychain integrity

### Best Practices
1. Enable secure mode for sensitive communications
2. Use strong iOS passcode/biometric authentication
3. Regularly update iOS for security patches
4. Be aware of devices within Bluetooth range

## Testing

Run the complete test suite:

```bash
xcodebuild test -scheme bitchat_iOS -destination "platform=iOS Simulator,name=iPhone 16"
```

Security-specific tests:
- `NoiseProtocolTests` - Noise Protocol implementation
- `BluetoothAuthenticationServiceTests` - Authentication logic
- `EncryptionServiceTests` - Cryptographic functions

## Contributing

### Security Issues
Report vulnerabilities privately to: security@unit221b.com

### Development
1. Fork the repository
2. Create a feature branch
3. Implement with tests
4. Submit pull request

## License

This project maintains the original Unlicense dedication to public domain.

## Acknowledgments

- Original BitChat concept by jackjackbits
- Security enhancements by Unit 221B
- Noise Protocol Framework by Trevor Perrin
- Community feedback on security improvements

---

**Company**: Unit 221B  
**Security Contact**: security@unit221b.com  
**General Inquiries**: lancejames@unit221b.com