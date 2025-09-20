#!/bin/bash

# Test Bluetooth Discovery and Connectivity
# Usage: ./test_bluetooth_discovery.sh

echo "🔍 BitChat Bluetooth Testing Script"
echo "======================================"

# Check if Bluetooth is available
echo "1. Checking Bluetooth status..."
system_profiler SPBluetoothDataType | grep -E "(Status|Discoverable)" | head -5

echo ""
echo "2. Available Bluetooth devices:"
system_profiler SPBluetoothDataType | grep -A 5 "Device:"

echo ""
echo "3. Core Bluetooth capability check:"
if [[ -d "/System/Library/Frameworks/CoreBluetooth.framework" ]]; then
    echo "✅ Core Bluetooth framework available"
else
    echo "❌ Core Bluetooth framework not found"
fi

echo ""
echo "4. Network interfaces (for mesh testing):"
ifconfig | grep -E "^(en|awdl)" | head -5

echo ""
echo "🧪 Testing Recommendations:"
echo "- Use iPhone connected via USB for development install"
echo "- Enable Bluetooth on both devices"
echo "- Keep devices within 10 meters for reliable connection"
echo "- Check Console.app for BitChat logs during testing"
echo ""
echo "📱 Development Install Command:"
echo "   1. Connect iPhone via USB"
echo "   2. Open bitchat.xcodeproj in Xcode"
echo "   3. Select your iPhone as destination"
echo "   4. Press ⌘+R to build and install"