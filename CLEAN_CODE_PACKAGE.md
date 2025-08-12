# BitChat Meshtastic Integration - Clean Code Package

This package contains production-ready code for integrating Meshtastic LoRa mesh networking into BitChat as an automatic fallback system.

## Integration Overview

The integration adds seamless LoRa mesh networking that automatically activates when Bluetooth LE connections have no available hops, extending communication range from ~100m to 10-50km while maintaining BitChat's privacy-first principles.

## Package Contents

### Python Backend (meshtastic/ directory)
- `bitchat_meshtastic_types.py` - Shared type definitions and protocol constants
- `meshtastic_bridge.py` - Main bridge service for device management and message routing  
- `meshtastic_config.py` - Configuration management and device preferences
- `protocol_translator.py` - Protocol conversion between BitChat binary and Meshtastic protobuf
- `requirements.txt` - Python dependencies
- `setup.sh` - Installation script

### Swift Integration (bitchat/ directory)
- `MeshtasticBridge.swift` - Swift wrapper for Python bridge service
- `MeshtasticFallbackManager.swift` - Fallback logic and message queue management
- `NetworkAvailabilityDetector.swift` - BLE activity monitoring and fallback triggers
- `MeshtasticSettingsView.swift` - Complete settings UI with device management

### Testing Suite (tests/ directory)
- `integration_tests.py` - Comprehensive test suite
- `demo.py` - Basic functionality demonstration
- `README.md` - Testing instructions

### Documentation (docs/ directory)
- `INTEGRATION_GUIDE.md` - Implementation guide
- `API_REFERENCE.md` - API documentation
- `USER_GUIDE.md` - User-facing documentation

## Key Features

- **Automatic Fallback**: Detects BLE connectivity issues and seamlessly switches to LoRa
- **Device Discovery**: Supports Serial (USB), TCP (WiFi), and BLE Meshtastic connections
- **Protocol Translation**: Converts between BitChat binary format and Meshtastic protobuf
- **Privacy-First**: Opt-in system with explicit user consent required
- **Range Extension**: Extends communication from 100m (BLE) to 10-50km (LoRa mesh)
- **Complete UI**: Full settings interface with device selection and status monitoring

## Installation

1. Copy files to your BitChat repository according to directory structure
2. Run `meshtastic/setup.sh` to install Python dependencies
3. Add Swift files to your Xcode project
4. Enable Meshtastic integration in BitChat settings

## Usage

The integration works transparently:
1. Normal BLE mesh operation continues as usual
2. System monitors BLE connectivity in background
3. When no BLE hops available for 30+ seconds, Meshtastic activates
4. Messages automatically route through LoRa mesh network
5. Users see seamless communication with extended range

## Compatibility

- iOS 14.0+ (Swift components)
- Python 3.7+ (Backend components)
- Meshtastic firmware 2.0+ (Hardware)
- Compatible with T-Beam, Heltec, RAK, and other ESP32-based Meshtastic devices

This integration requires no breaking changes to existing BitChat functionality and can be completely disabled if not needed.