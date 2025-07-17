# BitChat Meshtastic Integration Testing Guide

## Overview

This guide shows you how to test the Meshtastic integration with BitChat. The system provides automatic fallback from Bluetooth LE to LoRa mesh networking when no BLE hops are available.

## Test Scenarios

### 1. Virtual Testing (No Hardware Required)

The integration includes comprehensive virtual testing that validates all components without needing physical Meshtastic devices.

#### Running the Demo
```bash
python3 simple_test.py
```

This demonstrates:
- ✅ Configuration management
- ✅ Device discovery simulation  
- ✅ Protocol translation
- ✅ Fallback logic
- ✅ User consent flow

#### Running the Bridge Scanner
```bash
python3 meshtastic_bridge.py --scan
```

Expected output: `Found 0 Meshtastic devices` (normal without hardware)

### 2. Hardware Testing (With Physical Devices)

#### Required Hardware
- **Meshtastic Device Options:**
  - T-Beam (ESP32 + LoRa + GPS) - Most popular
  - Heltec WiFi LoRa 32 V3
  - RAK WisBlock devices
  - LilyGO T-Deck
  - Any ESP32 + SX127x/SX126x LoRa module

#### Connection Methods
1. **Serial (USB):** Connect device via USB cable
2. **WiFi (TCP):** Device on same network as computer
3. **Bluetooth LE:** Wireless connection to device

#### Testing Steps

1. **Setup Meshtastic Device**
   ```bash
   # Flash latest firmware (if needed)
   # Configure device settings
   # Set channel and encryption
   ```

2. **Test Device Detection**
   ```bash
   python3 meshtastic_bridge.py --scan
   ```
   Should show: `Found 1 Meshtastic devices: [device details]`

3. **Test Connection**
   ```bash
   python3 meshtastic_bridge.py --connect
   ```
   Should show: `Successfully connected to [device name]`

4. **Test Message Send**
   ```bash
   python3 meshtastic_bridge.py --test-send "Hello from BitChat!"
   ```
   Should appear on other Meshtastic devices in the mesh

### 3. Integration Testing (With BitChat App)

#### Enable in BitChat Settings
1. Open BitChat app
2. Go to Settings → Meshtastic
3. Grant permission when prompted
4. Toggle "Enable Meshtastic Fallback" ON
5. Select preferred device (if multiple found)

#### Test Fallback Behavior
1. **Normal Operation:** BitChat uses BLE mesh as usual
2. **Trigger Fallback:** 
   - Move away from other BitChat devices
   - Wait 30 seconds (default threshold)
   - System automatically detects no BLE hops
3. **Fallback Activation:**
   - Status changes to "Checking Meshtastic"
   - Connects to Meshtastic device
   - Status shows "Meshtastic Active"
4. **Send Message:** Regular BitChat message automatically routes via LoRa

#### Verify on Meshtastic Network
- Other Meshtastic devices should receive the message
- Messages appear in Meshtastic apps/web interface
- Can be relayed across multiple LoRa hops

### 4. Network Coverage Testing

#### Range Testing
1. **BLE Range:** ~50-100 meters line of sight
2. **LoRa Range:** 
   - Urban: 2-5 km
   - Rural: 10-20 km  
   - Line of sight: 50+ km

#### Mesh Testing
1. Set up multiple Meshtastic nodes
2. Test message relay across hops
3. Verify BitChat messages traverse the mesh
4. Test with nodes at different distances

### 5. Performance Testing

#### Message Throughput
- LoRa is slower than BLE (by design)
- Small messages: ~1-2 seconds
- Large messages: May fragment across multiple packets

#### Battery Impact
- LoRa uses more power than BLE
- System monitors battery and adjusts behavior
- Auto-disables in ultra-low power mode

#### Reliability Testing
- Test in various weather conditions
- Test with network congestion
- Verify retry mechanisms work

## Test Configuration Files

### Enable Test Mode
Create `meshtastic_config.json`:
```json
{
  "enabled": true,
  "user_consented": true,
  "auto_fallback": true,
  "fallback_threshold": 30,
  "scan_timeout": 10,
  "connection_timeout": 5,
  "retry_attempts": 3
}
```

### Mock Device Testing
For development without hardware, the system includes mock device simulation that validates all functionality.

## Common Issues & Solutions

### "No Devices Found"
- **Cause:** No Meshtastic hardware connected
- **Solution:** Connect device via USB or ensure WiFi connectivity

### "Connection Failed"
- **Cause:** Device busy, wrong port, or permissions
- **Solution:** Check device isn't used by other apps, verify USB permissions

### "Translation Error"  
- **Cause:** Message format incompatibility
- **Solution:** Check BitChat message format, verify protocol version

### "Permission Denied"
- **Cause:** User hasn't granted Meshtastic consent
- **Solution:** Enable in BitChat settings, grant permissions

## Success Indicators

✅ **Configuration:** Settings save and load correctly  
✅ **Discovery:** Devices detected and listed  
✅ **Connection:** Successful connection to Meshtastic device  
✅ **Translation:** Messages convert between formats  
✅ **Fallback:** Automatic activation when BLE unavailable  
✅ **Messaging:** BitChat messages appear on Meshtastic network  
✅ **UI Integration:** Status updates in BitChat interface  

## Real-World Validation

### Emergency Scenarios
Test in situations where cellular/internet is unavailable:
- Remote hiking areas
- Natural disaster simulation
- Large event with network congestion

### Coverage Extension
Verify the system extends BitChat's range:
- Position nodes across wide areas
- Test message relay across multiple hops
- Confirm end-to-end delivery

## Next Steps

Once testing is complete:
1. **Deploy:** Enable for all BitChat users
2. **Monitor:** Track usage and performance metrics  
3. **Optimize:** Improve based on real-world usage
4. **Scale:** Add support for more Meshtastic features

The integration is designed to be seamless - users should barely notice the transition from BLE to LoRa, except for the extended range and reliability.