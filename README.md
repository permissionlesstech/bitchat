<div align="center">

![ChatGPT Image Jul 5, 2025 at 06_07_31 PM](https://github.com/user-attachments/assets/2660f828-49c7-444d-beca-d8b01854667a)

# bitchat

**Decentralized Peer-to-Peer Messaging**

<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%20%7C%20macOS-blue?style=for-the-badge&logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Language-Swift-orange?style=for-the-badge&logo=swift" alt="Language">
  <img src="https://img.shields.io/badge/License-Public%20Domain-green?style=for-the-badge" alt="License">
  <img src="https://img.shields.io/badge/Network-Bluetooth%20Mesh-purple?style=for-the-badge&logo=bluetooth" alt="Network">
</p>

<p align="center">
  <strong>No Internet Required</strong> • <strong>No Servers</strong> • <strong>No Phone Numbers</strong> • <strong>End-to-End Encrypted</strong>
</p>

</div>

---

> [!WARNING]
> Private message and channel features have not received external security review and may contain vulnerabilities. Do not use for sensitive use cases, and do not rely on its security until it has been reviewed. Work in progress. Public local chat (the main feature) has no security concerns.

A decentralized peer-to-peer messaging app that works over Bluetooth mesh networks. No internet required, no servers, no phone numbers. It's the side-groupchat.

--- 

## Features

| Core Feature | Description |
|--------------|-------------|
| **Decentralized Mesh Network** | Automatic peer discovery and multi-hop message relay over Bluetooth LE |
| **End-to-End Encryption** | X25519 key exchange + AES-256-GCM for private messages and channels |
| **Channel-Based Chats** | Topic-based group messaging with optional password protection |
| **Store & Forward** | Messages cached for offline peers and delivered when they reconnect |
| **Privacy First** | No accounts, no phone numbers, no persistent identifiers |
| **IRC-Style Commands** | Familiar `/join`, `/msg`, `/who` style interface |
| **Message Retention** | Optional channel-wide message saving controlled by channel owners |
| **Universal App** | Native support for iOS and macOS |
| **Cover Traffic** | Timing obfuscation and dummy messages for enhanced privacy |
| **Emergency Wipe** | Triple-tap to instantly clear all data |
| **Performance Optimizations** | LZ4 message compression, adaptive battery modes, and optimized networking |

---

## Setup

### Option 1: XcodeGen (Recommended)

```bash
# Install XcodeGen
brew install xcodegen

# Generate and open project
cd bitchat
xcodegen generate
open bitchat.xcodeproj
```

### Option 2: Swift Package Manager

```bash
cd bitchat
open Package.swift
# Select your target device and run
```

### Option 3: Manual Xcode Project

1. Open Xcode and create a new iOS/macOS App
2. Copy all Swift files from the `bitchat` directory into your project
3. Update Info.plist with Bluetooth permissions
4. Set deployment target to iOS 16.0 / macOS 13.0

### macOS Quick Start

```bash
just run    # Set up and run from source
just clean  # Restore to original state
```

---

## Usage

### Getting Started

1. Launch bitchat on your device
2. Set your nickname (or use the auto-generated one)
3. You'll automatically connect to nearby peers
4. Join a channel with `/j #general` or start chatting in public
5. Messages relay through the mesh network to reach distant peers

### Basic Commands

| Command | Description | Command | Description |
|---------|-------------|---------|-------------|
| `/j #channel` | Join or create a channel | `/m @name message` | Send a private message |
| `/w` | List online users | `/channels` | Show all discovered channels |
| `/block @name` | Block a peer from messaging | `/unblock @name` | Unblock a peer |
| `/clear` | Clear chat messages | `/pass [password]` | Set channel password (owner) |
| `/transfer @name` | Transfer channel ownership | `/save` | Toggle message retention (owner) |

### Channel Features

- **Password Protection**: Channel owners can set passwords with `/pass`
- **Message Retention**: Owners can enable mandatory message saving with `/save`
- **@ Mentions**: Use `@nickname` to mention users (with autocomplete)
- **Ownership Transfer**: Pass control to trusted users with `/transfer`

---

## Security & Technical Details

**Encryption**: X25519 key exchange + AES-256-GCM • Ed25519 signatures • Argon2id key derivation  
**Privacy**: No registration • Ephemeral messaging • Emergency wipe (triple-tap) • Local-first  
**Performance**: LZ4 compression • Adaptive battery modes • Optimized Bloom filters  
**Protocol**: Binary protocol over Bluetooth LE • TTL-based routing • Store-and-forward  

**Service UUID**: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`

---

## Resources

- **[Technical Whitepaper](WHITEPAPER.md)** - Detailed protocol specification
- **[Privacy Policy](PRIVACY_POLICY.md)** - Data handling practices
- **[License](LICENSE)** - Public domain license

**Version**: 1.0.0 • **iOS**: 16.0+ • **macOS**: 13.0+ • **License**: Public Domain
