# Bitchat Deployment Guide

## Web Version (Running) ✅

### Access the Web IRC Chat

The web version of Bitchat is now **RUNNING** and can be accessed at:

**🌐 http://localhost:8080**

### Features Available in Web Version

✅ **IRC-style Commands**
- `/help` - Show all commands
- `/j #channel [password]` - Join/create channels
- `/m @user message` - Private messaging
- `/w` - List online users
- `/channels` - Show channels
- `/clear` - Clear messages
- `/nick nickname` - Change nickname
- `/block/@unblock` - User management
- `/favorite` - Mark favorite users

✅ **Real-time Communication**
- Cross-tab messaging via BroadcastChannel API
- Persistent peer discovery using localStorage
- Message relay simulation (mesh-like behavior)
- Automatic peer cleanup and presence detection

✅ **Terminal-style Interface**
- Green-on-black aesthetic matching original app
- Responsive design for mobile and desktop
- Sidebar with quick commands and peer list
- Autocomplete for @mentions, #channels, and /commands

✅ **Encryption Support**
- AES-GCM encryption for channel passwords
- Simple encryption for private messages
- Key derivation using PBKDF2
- Secure key storage

### Demo Features

The web version includes simulated bot peers that will join automatically:
- `alice_bot` - joins #general and #tech
- `bob_helper` - joins #general and #random  
- `charlie_dev` - joins #tech and #dev

### Testing Multi-User

1. **Open multiple tabs** in Safari to simulate multiple users
2. **Each tab** gets a unique peer ID and can have different nicknames
3. **Messages propagate** between tabs automatically
4. **Try commands** like `/j #general` to join channels
5. **Send private messages** with `/m @username hello`

## Original Swift Version

### System Requirements

The original Bitchat app requires:
- **macOS 13.0+** or **iOS 16.0+**
- **Xcode 14+** 
- **Physical devices** (Bluetooth doesn't work in simulator)
- **Bluetooth LE** enabled

### Building on macOS

```bash
# Option 1: Using XcodeGen (Recommended)
brew install xcodegen
cd bitchat
xcodegen generate
open bitchat.xcodeproj

# Option 2: Using Swift Package Manager
open Package.swift

# Option 3: Manual Xcode Project
# Create new iOS/macOS app and copy source files
```

### Linux/Alternative Environments

The original Swift app uses:
- **CoreBluetooth** (macOS/iOS only)
- **SwiftUI** (requires Xcode)
- **CryptoKit** (Apple platforms)

For non-Apple platforms, you would need to:
1. Replace CoreBluetooth with alternative Bluetooth LE library
2. Replace SwiftUI with alternative UI framework
3. Replace CryptoKit with cross-platform crypto library

## Architecture Comparison

### Original Swift App
- **Platform**: iOS/macOS native
- **Networking**: Bluetooth LE mesh
- **UI**: SwiftUI with terminal aesthetic
- **Encryption**: CryptoKit (X25519, AES-256-GCM)
- **Storage**: UserDefaults + Keychain

### Web Version
- **Platform**: Web browsers (Safari compatible)
- **Networking**: BroadcastChannel + localStorage simulation
- **UI**: HTML/CSS/JS with terminal aesthetic
- **Encryption**: Web Crypto API (AES-GCM, PBKDF2)
- **Storage**: localStorage + sessionStorage

## Key Features Implemented

Both versions support:

### 🔐 **Security & Privacy**
- End-to-end encryption for private messages
- Password-protected channels
- No servers or central authority
- Ephemeral peer IDs
- User blocking and favorites

### 💬 **IRC-style Communication**
- Channel-based messaging with # prefix
- Private messaging with @ mentions
- Command-line interface with / commands
- Real-time user presence
- Message relay/forwarding

### 🌐 **Mesh-like Networking**
- Automatic peer discovery
- Message TTL and deduplication
- Store-and-forward capability
- Adaptive connection management

### 🎨 **Retro Terminal Interface**
- Green-on-black color scheme
- Monospace fonts
- Minimal, functional design
- Keyboard shortcuts and autocomplete

## Usage Examples

### Basic Commands
```
/help                    # Show help
/nick alice              # Set nickname to alice
/j #general              # Join general channel
Hello everyone!          # Send message to current channel/public
/m @bob Hey there!       # Send private message to bob
/w                       # List online users
/channels                # Show joined channels
/clear                   # Clear messages
```

### Channel Management
```
/j #secure mypassword    # Join password-protected channel
/pass newpassword        # Set channel password (creator only)
/leave                   # Leave current channel
/back                    # Return to public chat
```

### User Management
```
/block @spammer          # Block a user
/unblock @spammer        # Unblock a user  
/favorite @alice         # Mark user as favorite
/favorite                # List favorites
```

## Next Steps

1. **Test the web version** at http://localhost:8080
2. **Try multi-tab** communication
3. **Experiment with channels** and private messaging
4. **For Swift version**: Set up macOS/Xcode environment
5. **For production**: Deploy web version to hosting service

## Notes

- **Web version** is a simulation of the mesh networking concepts
- **Real mesh networking** requires the Swift version on physical devices
- **Both versions** demonstrate the same user interface and command concepts
- **Safari compatibility** ensures the web version works on Apple devices