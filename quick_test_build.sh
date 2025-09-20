#!/bin/bash

# Quick Build and Test Script for BitChat
# Usage: ./quick_test_build.sh [ios|macos|simulator]

PLATFORM=${1:-simulator}

echo "🚀 BitChat Quick Build & Test"
echo "=============================="
echo "Platform: $PLATFORM"
echo ""

case $PLATFORM in
    "ios")
        echo "📱 Building for iOS Device (requires connected iPhone)..."
        xcodebuild -project bitchat.xcodeproj \
                   -scheme bitchat \
                   -configuration Debug \
                   -sdk iphoneos \
                   CODE_SIGN_IDENTITY="" \
                   CODE_SIGNING_REQUIRED=NO \
                   build
        ;;
    "macos")
        echo "💻 Building for macOS..."
        xcodebuild -project bitchat.xcodeproj \
                   -scheme bitchat \
                   -configuration Debug \
                   -sdk macosx \
                   build
        ;;
    "simulator")
        echo "📲 Building for iOS Simulator..."
        xcodebuild -project bitchat.xcodeproj \
                   -scheme bitchat \
                   -configuration Debug \
                   -sdk iphonesimulator \
                   CODE_SIGN_IDENTITY="" \
                   CODE_SIGNING_REQUIRED=NO \
                   build
        
        echo ""
        echo "🧪 Starting iOS Simulator..."
        open -a Simulator
        
        echo ""
        echo "📋 Available Simulators:"
        xcrun simctl list devices | grep -E "(Booted|Shutdown)" | head -5
        ;;
    *)
        echo "❌ Unknown platform: $PLATFORM"
        echo "Usage: $0 [ios|macos|simulator]"
        exit 1
        ;;
esac

echo ""
echo "✅ Build complete!"
echo ""
echo "🔍 Next steps for testing file sharing:"
echo "1. For real Bluetooth testing, use 'ios' platform with connected iPhone"
echo "2. For UI testing, use 'simulator' platform"
echo "3. For macOS testing, use 'macos' platform"
echo ""
echo "💡 Pro tip: Run './test_bluetooth_discovery.sh' to check your Bluetooth setup"