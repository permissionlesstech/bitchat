# Smart Transport Testing Guide

## Overview

This guide provides test scenarios to verify the smart transport system is working correctly.

## Pre-Test Setup

1. Ensure devices have unique IDs (check in Settings)
2. Enable WiFi and Bluetooth on all test devices
3. Clear any existing peer connections by restarting the app

## Test Scenarios

### 1. Basic Bluetooth Communication (2 devices)

**Setup:** Two devices within Bluetooth range (< 10m)

**Expected behavior:**
- Both devices discover each other via Bluetooth
- Messages are delivered reliably
- WiFi Direct remains inactive
- Transport info shows "Bluetooth"

**Verification:**
- Check logs for "Using Bluetooth for peer"
- No "Activating WiFi Direct" messages

### 2. Smart WiFi Activation (1 device initially)

**Setup:** Start with one device, no peers nearby

**Expected behavior:**
- After 5 seconds with < 2 Bluetooth peers, WiFi Direct activates
- Log shows "Only X Bluetooth peers, will activate WiFi Direct in 5s"
- Transport info changes to show WiFi Direct active

**Verification:**
- Monitor logs for smart activation messages
- Check transport info UI shows WiFi icon

### 3. Bridge Node Testing (3+ devices)

**Setup:** 
- Device A and B connected via Bluetooth
- Device C only reachable via WiFi Direct from Device B
- Device B acts as bridge

**Test:**
1. Send message from Device A
2. Device B should bridge to Device C

**Expected behavior:**
- Device B shows "Bridge active" in transport info
- Logs show "🌉 Bridging message from bluetooth to wifiDirect"
- Device C receives message from Device A

### 4. Transport Selection Per Peer

**Setup:** Device with both Bluetooth and WiFi peers

**Expected behavior:**
- Each peer uses only one transport
- Bluetooth preferred when available
- PeerManager tracks visibility per transport

**Verification:**
- Check logs for transport selection per peer
- No duplicate messages

### 5. Power Efficiency Test

**Setup:** Multiple devices with good Bluetooth coverage

**Expected behavior:**
- Once 5+ Bluetooth peers found, WiFi Direct deactivates
- Log shows "deactivating WiFi Direct to save power"
- Unless device is bridging networks

### 6. Crash Recovery Test

**Setup:** Force quit app on one device while connected

**Expected behavior:**
- Other devices detect disconnection
- Peer removed from list after timeout
- No crashes on remaining devices

## Debug Commands

View PeerManager state:
```swift
PeerManager.shared.debugPrintState()
```

Check transport statistics:
```swift
let stats = TransportManager.shared.getTransportStatistics()
print(stats)
```

## Common Issues

1. **No peers discovered**
   - Check Bluetooth/WiFi permissions
   - Verify devices are not in airplane mode
   - Check device IDs are different

2. **Messages not delivered**
   - Verify key exchange completed (161 bytes)
   - Check for signature verification errors
   - Ensure P256 keys using x963Representation

3. **WiFi Direct not activating**
   - Check autoSelectTransport is enabled
   - Verify Bluetooth peer count < 2
   - Wait full 5 seconds for activation

4. **Bridge not working**
   - Ensure bridge device sees peers on both transports
   - Check TTL > 1 on packets
   - Verify canBridge() returns true

## Log Patterns to Watch

Success indicators:
- `[KEY_EXCHANGE] Stored 65-byte P256 key`
- `📡 Sending message to X via bluetooth`
- `🌉 Bridging broadcast from X to Y`
- `TransportManager: Smart activation triggered`

Error indicators:
- `Failed to add peer keys: invalidPublicKey`
- `Signature verification failed`
- `No transport available for peer`
- `Key data size mismatch`