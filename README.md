![ChatGPT Image Jul 5, 2025 at 06_07_31 PM](https://github.com/user-attachments/assets/2660f828-49c7-444d-beca-d8b01854667a)
# bitchat

A secure, end-to-end encrypted Bluetooth mesh chat application with an IRC-style interface.

## License

This project is released into the public domain. See the [LICENSE](LICENSE) file for details.

## Features

- End-to-end encryption using Curve25519 and AES-GCM
- Bluetooth mesh networking with automatic peer discovery
- Message relay capability (TTL-based flooding)
- IRC-style terminal interface
- Persistent nickname storage
- Universal app (iOS and macOS)
- No internet connection required

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

1. Launch the app on multiple devices
2. Choose or modify your nickname
3. The app will automatically discover nearby peers
4. Start chatting! Messages are relayed through the mesh network

## Security

- All messages are end-to-end encrypted
- Public key exchange happens automatically on connection
- Messages are signed to prevent tampering
- TTL prevents infinite message loops

## Protocol

The bitchat protocol uses JSON-encoded packets with the following structure:
- Packet versioning for future compatibility
- Message types: handshake, message, ack, relay, announce, keyExchange
- TTL-based flooding for mesh relay
- Signature verification for authenticity

## Building for Production

1. Set your development team in project settings
2. Configure code signing
3. Archive and distribute through App Store or TestFlight

## Android Compatibility

The protocol is designed to be platform-agnostic. An Android client can be built using:
- Bluetooth LE APIs
- Same packet structure and encryption
- Compatible service/characteristic UUIDs
