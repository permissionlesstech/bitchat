#!/bin/bash

# Install BitChat on iPhone via USB Development
# Usage: ./install_on_iphone.sh

echo "📱 BitChat iPhone Installation Helper"
echo "====================================="

# Check if iPhone is connected
echo "1. Checking for connected iPhone..."
if system_profiler SPUSBDataType | grep -q -i iphone; then
    echo "✅ iPhone detected via USB"
    system_profiler SPUSBDataType | grep -A 3 -i iphone | head -4
else
    echo "❌ iPhone not detected"
    echo ""
    echo "Please:"
    echo "  1. Connect iPhone via USB-C cable"
    echo "  2. Unlock iPhone"
    echo "  3. Trust this computer when prompted"
    echo "  4. Run this script again"
    exit 1
fi

echo ""
echo "2. Checking Xcode setup..."
if command -v xcodebuild >/dev/null 2>&1; then
    echo "✅ Xcode installed"
    xcodebuild -version | head -1
else
    echo "❌ Xcode not found"
    echo "Please install Xcode from the App Store"
    exit 1
fi

echo ""
echo "3. Opening project in Xcode..."
if [ -f "bitchat.xcodeproj/project.pbxproj" ]; then
    echo "✅ Project found"
    open bitchat.xcodeproj
    echo ""
    echo "🎯 Next steps in Xcode:"
    echo "  1. Sign in: Xcode → Preferences → Accounts → Add Apple ID"
    echo "  2. Select target: Click 'bitchat' project → 'bitchat' target"
    echo "  3. Enable signing: Signing & Capabilities → ✓ Automatically manage signing"
    echo "  4. Choose team: Select your Apple ID from dropdown"
    echo "  5. Update bundle ID: Change to com.yourname.bitchat.dev"
    echo "  6. Select device: Choose your iPhone from device selector"
    echo "  7. Build & run: Press ⌘+R"
    echo ""
    echo "📱 On your iPhone after install:"
    echo "  • Settings → General → VPN & Device Management"
    echo "  • Trust your Apple ID developer certificate"
    echo ""
    echo "🔄 App expires in 7 days (rebuild to refresh)"
else
    echo "❌ bitchat.xcodeproj not found"
    echo "Make sure you're in the BitChat project directory"
    exit 1
fi

echo ""
echo "💡 Tips:"
echo "  • Keep iPhone unlocked during first install"
echo "  • Use a unique bundle identifier"
echo "  • Delete any existing BitChat app first"
echo "  • Try different USB-C cable if connection fails"