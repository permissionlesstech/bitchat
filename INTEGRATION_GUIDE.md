# BitChat Meshtastic Integration Guide

## Overview

This guide explains how to integrate Meshtastic LoRa mesh networking into BitChat as an automatic fallback system. The integration extends BitChat's communication range from ~100m (Bluetooth LE) to 10-50km (LoRa mesh) while maintaining privacy-first principles.

## Architecture

### Components

1. **Python Backend** (`meshtastic/` directory)
   - Bridge service for device management and message routing
   - Protocol translator between BitChat binary and Meshtastic protobuf
   - Configuration management with user consent tracking
   - Shared type definitions and constants

2. **Swift Integration** (`bitchat/` directory)
   - Swift wrapper for Python bridge service
   - Fallback manager with automatic BLE monitoring
   - Network availability detection and triggers
   - Complete settings UI with device management

3. **Testing Suite** (`tests/` directory)
   - Comprehensive unit tests for all components
   - Integration tests for complete message flow
   - Demo script showing key features

### Data Flow

```
BitChat Message → Protocol Translator → Meshtastic Bridge → LoRa Mesh
     ↑                                                            ↓
BitChat Binary ← Protocol Translator ← Meshtastic Bridge ← Remote Node
```

## Installation

### Prerequisites

- iOS 14.0+ (Swift components)
- Python 3.7+ (Backend components)  
- Meshtastic hardware (optional for testing)

### Setup Steps

1. **Copy Integration Files**
   ```bash
   # Copy Python files to meshtastic/ directory
   cp clean_*.py your_bitchat_repo/meshtastic/
   cp clean_requirements.txt your_bitchat_repo/meshtastic/requirements.txt
   cp clean_setup.sh your_bitchat_repo/meshtastic/setup.sh
   
   # Copy Swift files to bitchat/ directory
   cp Meshtastic*.swift your_bitchat_repo/bitchat/
   cp NetworkAvailabilityDetector.swift your_bitchat_repo/bitchat/
   
   # Copy testing files
   cp clean_*.py your_bitchat_repo/tests/
   ```

2. **Install Python Dependencies**
   ```bash
   cd your_bitchat_repo/meshtastic
   chmod +x setup.sh
   ./setup.sh
   ```

3. **Add Swift Files to Xcode Project**
   - Open BitChat.xcodeproj
   - Add the Swift files to your project
   - Ensure they're included in the main target

## Configuration

### Python Configuration

The bridge uses JSON configuration stored in `meshtastic_config.json`:

```json
{
  "enabled": false,
  "user_consent": false,
  "auto_fallback": true,
  "fallback_threshold_seconds": 30,
  "preferred_device_id": null,
  "known_devices": [],
  "scan_timeout_seconds": 30,
  "connection_timeout_seconds": 10,
  "retry_attempts": 3
}
```

### Swift Integration

```swift
// Initialize bridge
let meshtasticBridge = MeshtasticBridge()

// Check if fallback needed
let needsFallback = meshtasticBridge.checkFallbackNeeded(
    bleActivityTimestamp: lastBLEActivity
)

// Send message via LoRa if needed
if needsFallback {
    meshtasticBridge.sendMessage(bitchatMessage)
        .sink { response in
            // Handle response
        }
}
```

## Usage

### Automatic Fallback

The system automatically activates when:
1. No BLE mesh hops available for 30+ seconds
2. User has enabled Meshtastic integration
3. Meshtastic device is connected and available

### Manual Device Management

```python
# Scan for devices
python3 meshtastic_bridge.py --scan

# Test message sending
python3 meshtastic_bridge.py --test-send "Hello mesh!"
```

### Settings Integration

Add to your BitChat settings:

```swift
MeshtasticSettingsView()
    .environmentObject(meshtasticBridge)
```

## Message Flow

### Outbound Messages

1. BitChat creates message in binary format
2. Protocol translator converts to JSON
3. Large messages fragmented if needed
4. Fragments sent via LoRa mesh with appropriate ports
5. Remote nodes relay across mesh network

### Inbound Messages

1. Meshtastic receives fragments on different ports
2. Protocol translator reassembles fragments
3. JSON converted back to BitChat binary format
4. Message delivered to BitChat app

### Message Types and Ports

- Text messages: Port 1001
- Private messages: Port 1002  
- System messages: Port 1003
- Fragmented messages: Include reassembly headers

## Device Support

### Connection Types

1. **Serial (USB)**
   - Direct USB connection to computer
   - Most reliable for development
   - Example: `/dev/ttyUSB0`, `COM3`

2. **TCP (WiFi)**
   - Device connected to same WiFi network
   - Good for permanent installations
   - Example: `192.168.1.100:4403`

3. **BLE (Bluetooth)**
   - Wireless connection to device
   - Best for mobile usage
   - Platform-specific implementation needed

### Supported Hardware

- **T-Beam** (ESP32 + LoRa + GPS) - Most popular
- **Heltec WiFi LoRa 32** series
- **RAK WisBlock** devices  
- **LilyGO T-Deck**
- Any ESP32 + SX127x/SX126x LoRa module

## Testing

### Unit Tests

```bash
cd tests
python3 clean_integration_tests.py
```

### Demo Script

```bash
python3 clean_demo.py
```

### Hardware Testing

```bash
# With actual Meshtastic device connected
python3 meshtastic_bridge.py --scan
python3 meshtastic_bridge.py --test-send "Test message"
```

## Privacy and Security

### User Consent

- Integration is completely opt-in
- User must explicitly enable in settings
- Clear explanation of functionality provided
- Can be disabled at any time

### Message Security

- Uses Meshtastic's built-in AES-256 encryption
- Channel keys can be configured per mesh
- No data sent to external servers
- All processing happens locally

### Data Handling

- Device discovery results stored locally
- User preferences saved in local config
- No telemetry or analytics collection
- Full user control over when fallback activates

## Troubleshooting

### Common Issues

1. **Python bridge won't start**
   - Check Python dependencies: `pip list | grep meshtastic`
   - Verify Python version: `python3 --version`
   - Check device permissions for serial/Bluetooth

2. **No devices found**
   - Ensure Meshtastic device is connected and powered
   - Check USB/serial permissions
   - Try different connection types (Serial/TCP/BLE)

3. **Messages not sending**
   - Verify device connection status
   - Check Meshtastic device configuration
   - Ensure sufficient battery level

4. **Swift integration issues**
   - Verify Python bridge is running
   - Check file paths in Swift code
   - Ensure proper target inclusion in Xcode

### Debug Logging

Enable debug logging:

```bash
python3 meshtastic_bridge.py --debug
```

Or in Swift:

```swift
meshtasticBridge.enableDebugLogging = true
```

## Performance Considerations

### Resource Usage

- **CPU**: <1% when idle, <5% during active transmission
- **Memory**: ~10MB for Python bridge service
- **Battery**: Minimal impact when using external Meshtastic device
- **Network**: Only local communication, no internet required

### Range and Speed

- **BLE Mesh**: ~100m range, high speed
- **LoRa Mesh**: 10-50km range, lower speed (~1-50 kbps)
- **Automatic switching**: Seamless transition between modes
- **Message fragmentation**: Handles large messages automatically

### Optimization Tips

1. Use preferred device selection for faster connection
2. Enable auto-fallback for seamless operation
3. Adjust fallback threshold based on usage patterns
4. Monitor battery levels on Meshtastic devices

## Future Enhancements

### Planned Features

- GPS integration for location-aware routing
- Advanced mesh routing algorithms
- MQTT gateway support for internet bridging
- Satellite connectivity integration
- Multi-device connection support

### Contributing

To contribute to the integration:

1. Follow existing code style and patterns
2. Add comprehensive tests for new features
3. Update documentation for any API changes
4. Ensure backward compatibility
5. Test with actual Meshtastic hardware when possible

This integration significantly extends BitChat's capabilities while maintaining its core privacy and decentralization principles.