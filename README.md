# BitChat: Now with Extra Bits of Security™

**The original BitChat, but we flipped all the security bits from 0 to 1**

**Author**: Lance James, Unit 221B  
**Contact**: lancejames@unit221b.com

## IMPORTANT SECURITY NOTICE

This is a security-hardened fork of the original BitChat application. We took BitChat and added a few more bits - specifically, the security bits that were missing. During our audit, we found the app was transmitting security in cleartext (aka not at all). This fork implements essential fixes because every bit counts, especially the secure ones.

**See [SECURITY_DISCLOSURE.md](SECURITY_DISCLOSURE.md) for full vulnerability details.**

**🔗 Our Pull Request with Fixes**: https://github.com/jackjackbits/bitchat/pull/77

## Why This Fork Exists

The original BitChat, while innovative in concept, contains several critical security flaws:

- **No Bluetooth Authentication**: Automatic connection to any device advertising the service UUID
- **Insecure Key Storage**: Private keys stored in UserDefaults instead of Keychain
- **Buffer Overflows**: Multiple unchecked array operations causing crashes
- **No Session Management**: Complete absence of authentication enabling impersonation
- **Weak Peer IDs**: Only 32-bit entropy allowing collision attacks
- **Extended Replay Window**: 5-minute window for message replay attacks

This fork addresses ALL of these vulnerabilities to create a truly secure messaging platform.

## Security Improvements Implemented

### 1. Bluetooth Authentication (FIXED)
- ✅ Added device pairing with PIN verification
- ✅ Implemented mutual authentication protocol
- ✅ User confirmation required before connections
- ✅ Identity verification during key exchange

### 2. Secure Key Storage (FIXED)
- ✅ Moved all keys to iOS Keychain
- ✅ Hardware encryption with Secure Enclave
- ✅ Biometric authentication for key access
- ✅ Automatic key rotation mechanism

### 3. Protocol Security (FIXED)
- ✅ Comprehensive bounds checking
- ✅ Safe parsing with length validation
- ✅ Graceful error handling
- ✅ Protocol fuzzing tests

### 4. Session Management (NEW)
- ✅ Secure session establishment
- ✅ Message authentication codes (MAC)
- ✅ Anti-replay sequence numbers
- ✅ Session timeout and renewal

### 5. Enhanced Security (NEW)
- ✅ 256-bit peer IDs (was 32-bit)
- ✅ 30-second replay window (was 5 minutes)
- ✅ Rate limiting (10 msg/sec per peer)
- ✅ Connection throttling (max 50 peers)
- ✅ Automatic resource cleanup

## License

This project is released into the public domain. See the [LICENSE](LICENSE) file for details.

## Features

- **Decentralized Mesh Network**: Automatic peer discovery and multi-hop message relay over Bluetooth LE
- **End-to-End Encryption**: X25519 key exchange + AES-256-GCM for private messages
- **Channel-Based Chats**: Topic-based group messaging with optional password protection
- **Store & Forward**: Messages cached for offline peers and delivered when they reconnect
- **Privacy First**: No accounts, no phone numbers, no persistent identifiers
- **IRC-Style Commands**: Familiar `/join`, `/msg`, `/who` style interface
- **Message Retention**: Optional channel-wide message saving controlled by channel owners
- **Universal App**: Native support for iOS and macOS
- **Cover Traffic**: Timing obfuscation and dummy messages for enhanced privacy
- **Emergency Wipe**: Triple-tap to instantly clear all data
- **Performance Optimizations**: LZ4 message compression, adaptive battery modes, and optimized networking

## Setup

### Option 1: Using XcodeGen (Recommended)

1. Install XcodeGen if you haven't already:
   ```bash
   brew install xcodegen
   ```

2. Generate the Xcode project:
   ```bash
   cd bitchat
   xcodegen generate
   ```

3. Open the generated project:
   ```bash
   open bitchat.xcodeproj
   ```

### Option 2: Using Swift Package Manager

1. Open the project in Xcode:
   ```bash
   cd bitchat
   open Package.swift
   ```

2. Select your target device and run

### Option 3: Manual Xcode Project

1. Open Xcode and create a new iOS/macOS App
2. Copy all Swift files from the `bitchat` directory into your project
3. Update Info.plist with Bluetooth permissions
4. Set deployment target to iOS 16.0 / macOS 13.0

## Usage

### Basic Commands

- `/j #channel` - Join or create a channel
- `/m @name message` - Send a private message
- `/w` - List online users
- `/channels` - Show all discovered channels
- `/block @name` - Block a peer from messaging you
- `/block` - List all blocked peers
- `/unblock @name` - Unblock a peer
- `/clear` - Clear chat messages
- `/pass [password]` - Set/change channel password (owner only)
- `/transfer @name` - Transfer channel ownership
- `/save` - Toggle message retention for channel (owner only)

### Getting Started

1. Launch bitchat on your device
2. Set your nickname (or use the auto-generated one)
3. You'll automatically connect to nearby peers
4. Join a channel with `/j #general` or start chatting in public
5. Messages relay through the mesh network to reach distant peers

### Channel Features

- **Password Protection**: Channel owners can set passwords with `/pass`
- **Message Retention**: Owners can enable mandatory message saving with `/save`
- **@ Mentions**: Use `@nickname` to mention users (with autocomplete)
- **Ownership Transfer**: Pass control to trusted users with `/transfer`

## Security & Privacy

### Encryption
- **Private Messages**: X25519 key exchange + AES-256-GCM encryption
- **Channel Messages**: Argon2id password derivation + AES-256-GCM
- **Digital Signatures**: Ed25519 for message authenticity
- **Forward Secrecy**: New key pairs generated each session

### Privacy Features
- **No Registration**: No accounts, emails, or phone numbers required
- **Ephemeral by Default**: Messages exist only in device memory
- **Cover Traffic**: Random delays and dummy messages prevent traffic analysis
- **Emergency Wipe**: Triple-tap logo to instantly clear all data
- **Local-First**: Works completely offline, no servers involved

## Performance & Efficiency

### Message Compression
- **LZ4 Compression**: Automatic compression for messages >100 bytes
- **30-70% bandwidth savings** on typical text messages
- **Smart compression**: Skips already-compressed data

### Battery Optimization
- **Adaptive Power Modes**: Automatically adjusts based on battery level
  - Performance mode: Full features when charging or >60% battery
  - Balanced mode: Default operation (30-60% battery)
  - Power saver: Reduced scanning when <30% battery
  - Ultra-low power: Emergency mode when <10% battery
- **Background efficiency**: Automatic power saving when app backgrounded
- **Configurable scanning**: Duty cycle adapts to battery state

### Network Efficiency
- **Optimized Bloom filters**: Faster duplicate detection with less memory
- **Message aggregation**: Batches small messages to reduce transmissions
- **Adaptive connection limits**: Adjusts peer connections based on power mode

## Technical Architecture

### Binary Protocol
bitchat uses an efficient binary protocol optimized for Bluetooth LE:
- Compact packet format with 1-byte type field
- TTL-based message routing (max 7 hops)
- Automatic fragmentation for large messages
- Message deduplication via unique IDs

### Mesh Networking
- Each device acts as both client and peripheral
- Automatic peer discovery and connection management
- Store-and-forward for offline message delivery
- Adaptive duty cycling for battery optimization

For detailed protocol documentation, see the [Technical Whitepaper](WHITEPAPER.md).

## Building for Production

1. Set your development team in project settings
2. Configure code signing
3. Archive and distribute through App Store or TestFlight

## Android Compatibility

The protocol is designed to be platform-agnostic. An Android client can be built using:
- Bluetooth LE APIs
- Same packet structure and encryption
- Compatible service/characteristic UUIDs

## Community Contribution

We discovered these vulnerabilities and immediately created a PR with comprehensive security patches to help the community. This security-hardened fork implements all the necessary fixes to create a truly secure messaging platform.

**🔗 Pull Request**: https://github.com/jackjackbits/bitchat/pull/77

## Security Recommendations

### For Users
- **DO NOT use the original BitChat** for sensitive communications
- Use this security-hardened fork instead
- Enable iOS passcode/biometric authentication
- Keep your device updated with latest iOS security patches
- Be cautious of devices within Bluetooth range

### For Developers
- Review our security fixes and implement similar protections
- Conduct regular security audits
- Implement defense-in-depth strategies
- Follow secure coding practices

## Contributing

Security is our top priority. If you discover any vulnerabilities:
1. **DO NOT** open a public issue
2. Email security@unit221b.com with details
3. We'll respond within 48 hours
4. Responsible reporters will be credited

## Contact

**Security Issues**: security@unit221b.com  
**General Inquiries**: lancejames@unit221b.com  
**Company**: Unit 221B

## Acknowledgments

- Original BitChat developers for the innovative concept
- The iOS security community for best practices
- Security researchers who helped verify our fixes

---

**⚠️ SECURITY WARNING**: The original BitChat (https://github.com/jackjackbits/bitchat) contains unpatched critical vulnerabilities. Use at your own risk.
