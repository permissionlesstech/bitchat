# Bitchat Issues Analysis

## Issue 1: Background Messages on iOS Stopped Working

### Root Cause
The Info.plist file is missing the required `UIBackgroundModes` configuration for Bluetooth background operation. Without this, iOS will suspend the app when it goes to background, preventing BLE message delivery.

### Required Info.plist Entries
```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
    <string>bluetooth-peripheral</string>
</array>
```

### Protocol Size Analysis
The binary protocol is significantly smaller than JSON:
- **Message packet**: 71 bytes (binary) vs 189 bytes (JSON) - 62% reduction
- **Announce packet**: 29 bytes (binary) vs 96 bytes (JSON) - 69% reduction

While the binary protocol is more efficient, the size reduction alone shouldn't break background delivery. The missing background modes configuration is the primary issue.

### Additional Considerations
- In `BluetoothMeshService.swift`, messages are sent with `.withResponse` type (line 281), which is good for reliability
- The app uses both central and peripheral modes, so both background modes are needed

## Issue 2: RSSI Indicator Dots Not Showing

### Analysis
The RSSI dots ARE implemented in `ContentView.swift` (lines 164-175), but there are several issues:

1. **RSSI Collection**: RSSI values are being collected and stored in the `peerRSSI` dictionary (line 504, 659)
2. **UI Implementation**: The dots are properly implemented with color coding based on signal strength
3. **Timing Issue**: The RSSI is read after connection (line 527) and periodically updated (line 665)

### Potential Issues
- The RSSI might not be available immediately when the peer list is displayed
- The peer ID mapping might be using temporary IDs initially (line 650-656 shows handling of temp IDs)
- The UI might not be updating when RSSI values are set

## Issue 3: Peer Nicknames Not Showing Until Message

### Analysis
The nickname flow works as follows:

1. **Connection**: When peers connect, they exchange keys first
2. **Announce Timing**: Announce packets are sent:
   - After key exchange as central (lines 599-617)
   - After key exchange as peripheral (lines 719-737)
   - Targeted announce when receiving key exchange (line 362)

3. **Display Logic**: In `ContentView.swift` (line 155), peers show as "person-[ID]" until nickname is received

### Issues Found
1. **Race Condition**: The announce packet is sent immediately after key exchange, but there's a 0.1s delay for the broadcast announce (line 602)
2. **Peer ID Mapping**: Temporary peripheral IDs are used until the real peer ID is received (lines 521-524)
3. **Announce Tracking**: The `announcedToPeers` set prevents re-announcing (line 221), which could be problematic if the first announce fails

### The Real Problem
Looking at lines 384-391 and 648-656, there's a complex mapping issue where peripherals are initially stored with their system UUID, then remapped when the real peer ID is learned. This remapping happens during announce or key exchange, but the UI might be showing peers before this remapping completes.

## Recommendations

### 1. Fix Background Modes (Priority 1)
Add the missing background modes to Info.plist to restore background BLE functionality.

### 2. Fix RSSI Display (Priority 2)
- Ensure RSSI reading starts immediately after getting the real peer ID
- Force UI update when RSSI values change
- Consider showing a placeholder dot (gray) while RSSI is being read

### 3. Fix Nickname Display (Priority 3)
- Send multiple announce packets with retries to ensure delivery
- Consider sending announce both as broadcast and targeted to ensure all peers receive it
- Improve the peer ID mapping to handle the transition from temp ID to real ID more smoothly
- Add debugging to track announce packet delivery success

### 4. Additional Improvements
- Add retry logic for critical packets (announce, key exchange)
- Implement packet acknowledgment for announce messages
- Add connection state tracking to better handle the peer discovery flow