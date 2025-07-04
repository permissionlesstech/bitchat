# App Store Submission Checklist

## Pre-Submission Preparation ✓

### Code Quality
- [x] All debug print statements removed
- [x] No TODOs or FIXMEs in code
- [x] Public domain headers added to all source files
- [x] Unit tests included and passing
- [x] No hardcoded values or test data

### App Configuration
- [x] Bundle ID: com.bitchat.app
- [x] Version: 1.0.0 (build 1)
- [x] Deployment targets: iOS 16.0, macOS 13.0
- [x] App category: Social Networking
- [x] App icons included (all required sizes)
- [x] Launch screen configured (black background)

### Privacy & Security
- [x] Bluetooth permissions descriptions added
- [x] ITSAppUsesNonExemptEncryption = NO (using standard crypto)
- [x] No third-party tracking or analytics
- [x] No personal data collection
- [x] End-to-end encryption implemented

### Features Complete
- [x] Bluetooth mesh networking
- [x] End-to-end encrypted messaging
- [x] Private messaging
- [x] @mentions with autocomplete
- [x] Favorites system
- [x] Message relay (TTL-based)
- [x] Store-and-forward for offline delivery
- [x] Panic mode (triple-tap to clear data)
- [x] Battery-optimized scanning
- [x] Background Bluetooth support

## App Store Connect Setup

### App Information
**App Name:** bitchat
**Subtitle:** Secure Bluetooth mesh chat
**Primary Category:** Social Networking

### Description
```
bitchat is a secure, decentralized chat app that works without internet. Create a mesh network with nearby devices using Bluetooth.

Features:
• No account or signup required
• End-to-end encrypted messages
• Works completely offline
• Private messaging
• @mentions and favorites
• Messages auto-expire for privacy
• Public domain software

Perfect for:
• Events and conferences
• Emergency communication
• Privacy-conscious users
• Areas without internet
• Group coordination

Your messages stay local and encrypted. No servers, no tracking, no data collection.
```

### Keywords
`bluetooth, mesh, chat, offline, encrypted, secure, private, local, decentralized, messaging`

### Privacy Policy
```
bitchat does not collect, store, or transmit any personal data. 
All communication is local, encrypted, and ephemeral.
No analytics, no tracking, no servers.
```

### Screenshots Required
1. Main chat interface
2. Private messaging
3. Peer list/connected users
4. @mention autocomplete
5. Dark mode view

### Review Notes
- App uses Bluetooth for local communication only
- No internet connection required or used
- Messages are ephemeral and encrypted
- Standard iOS encryption (no export compliance needed)

## Testing Checklist
- [ ] Test on iPhone (multiple models)
- [ ] Test on iPad
- [ ] Test on macOS
- [ ] Test Bluetooth connectivity between devices
- [ ] Test message delivery and relay
- [ ] Test background operation
- [ ] Test battery usage over extended period
- [ ] Test with 10+ devices in mesh

## Final Steps
1. Generate project with XcodeGen: `xcodegen generate`
2. Open in Xcode and set development team
3. Archive for App Store
4. Upload to App Store Connect
5. Submit for review

## Post-Launch
- Monitor crash reports
- Respond to user feedback
- Consider adding:
  - Custom themes
  - Message reactions
  - File sharing
  - Voice notes (removed for v1)