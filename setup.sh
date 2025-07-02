#!/bin/bash

echo "bitchat Setup Script"
echo "==================="

# Check if XcodeGen is installed
if command -v xcodegen &> /dev/null; then
    echo "✓ XcodeGen found"
    echo "Generating Xcode project..."
    xcodegen generate
    echo "✓ Project generated successfully"
    echo ""
    echo "To open the project, run:"
    echo "  open bitchat.xcodeproj"
else
    echo "⚠️  XcodeGen not found"
    echo ""
    echo "You have several options:"
    echo "1. Install XcodeGen:"
    echo "   brew install xcodegen"
    echo ""
    echo "2. Open with Swift Package Manager:"
    echo "   open Package.swift"
    echo ""
    echo "3. Create a new Xcode project manually and add the source files"
fi

echo ""
echo "Project Structure:"
echo "- bitchat/           Main source files"
echo "  - BitchatApp.swift    App entry point"
echo "  - Views/              SwiftUI views"
echo "  - ViewModels/         View models"
echo "  - Services/           Bluetooth and encryption"
echo "  - Protocols/          Protocol definitions"
echo ""
echo "Remember to:"
echo "1. Enable Bluetooth in device settings"
echo "2. Run on physical devices (Bluetooth doesn't work in simulator)"
echo "3. Test with multiple devices for mesh functionality"