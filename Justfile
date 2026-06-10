# BitChat macOS Build Justfile
# Handles temporary modifications needed to build and run on macOS

# Default recipe - shows available commands
default:
    @echo "BitChat macOS Build Commands:"
    @echo "  just run     - Build and run the macOS app"
    @echo "  just build   - Build the macOS app only"
    @echo "  just intel13 - Build for Intel macOS 13 (x86_64)"
    @echo "  just package-intel-macos13 - Build Intel macOS 13 and create zip in dist/"
    @echo "  just clean   - Clean build artifacts and restore original files"
    @echo "  just check   - Check prerequisites"
    @echo ""
    @echo "Original files are preserved - modifications are temporary for builds only"

# Check prerequisites
check:
    @echo "Checking prerequisites..."
    @command -v xcodebuild >/dev/null 2>&1 || (echo "❌ xcodebuild not found. Install Xcode from App Store" && exit 1)
    @xcode-select -p | grep -q "Xcode.app" || (echo "❌ Full Xcode required, not just command line tools. Install from App Store and run:\n   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" && exit 1)
    @test -d "/Applications/Xcode.app" || (echo "❌ Xcode.app not found in Applications folder. Install from App Store" && exit 1)
    @xcodebuild -version >/dev/null 2>&1 || (echo "❌ Xcode not properly configured. Try:\n   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" && exit 1)
    @security find-identity -v -p codesigning | grep -q "Apple Development\|Developer ID" || (echo "⚠️  No Developer ID found - code signing may fail" && exit 0)
    @echo "✅ All prerequisites met"

# Backup original files
backup:
    @echo "Backing up original project configuration..."
    @if [ -f bitchat.xcodeproj/project.pbxproj ]; then cp bitchat.xcodeproj/project.pbxproj bitchat.xcodeproj/project.pbxproj.backup; fi
    @if [ -f bitchat/Info.plist ]; then cp bitchat/Info.plist bitchat/Info.plist.backup; fi

# Restore original files
restore:
    @echo "Restoring original project configuration..."
    @if [ -f project.yml.backup ]; then mv project.yml.backup project.yml; fi
    @# Restore iOS-specific files
    @if [ -f bitchat/LaunchScreen.storyboard.ios ]; then mv bitchat/LaunchScreen.storyboard.ios bitchat/LaunchScreen.storyboard; fi
    @# Use git to restore all modified files except Justfile
    @git checkout -- project.yml bitchat.xcodeproj/project.pbxproj bitchat/Info.plist 2>/dev/null || echo "⚠️  Could not restore some files with git"
    @# Remove any backup files
    @rm -f bitchat.xcodeproj/project.pbxproj.backup bitchat/Info.plist.backup 2>/dev/null || true

# Apply macOS-specific modifications
patch-for-macos: backup
    @echo "Temporarily hiding iOS-specific files for macOS build..."
    @# Move iOS-specific files out of the way temporarily
    @if [ -f bitchat/LaunchScreen.storyboard ]; then mv bitchat/LaunchScreen.storyboard bitchat/LaunchScreen.storyboard.ios; fi

# Build the macOS app
build: #check generate
    @echo "Building BitChat for macOS..."
    @xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" -configuration Debug CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" build

# Build the local Arti dependency for Intel macOS and package it as xcframework
prepare-arti-intel:
    @echo "Preparing local Arti xcframework (x86_64 macOS slice)..."
    @cd localPackages/Arti && rustup target add x86_64-apple-darwin >/dev/null 2>&1 || true
    @cd localPackages/Arti && cargo build --release --target x86_64-apple-darwin -p arti-bitchat
    @cd localPackages/Arti && rm -rf Frameworks/arti.xcframework
    @cd localPackages/Arti && xcodebuild -create-xcframework \
        -library target/x86_64-apple-darwin/release/libarti_bitchat.a \
        -headers Frameworks/include \
        -output Frameworks/arti.xcframework

# Build specifically for Intel x86_64 on macOS 13
build-intel-macos13: prepare-arti-intel
    @echo "Building BitChat for Intel macOS 13 (x86_64)..."
    @xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" -configuration Release \
        -derivedDataPath build/DerivedData-Intel \
        -destination 'platform=macOS,arch=x86_64' \
        ARCHS=x86_64 \
        MACOSX_DEPLOYMENT_TARGET=13.0 \
        CODE_SIGNING_ALLOWED=NO \
        build

# Friendly alias for one-command Intel build
intel13: build-intel-macos13

# Build Intel macOS 13 app and package as zip for transfer
package-intel-macos13: build-intel-macos13
    @echo "Packaging Intel macOS app..."
    @test -f build/DerivedData-Intel/Build/Products/Release/bitchat.app/Contents/MacOS/bitchat
    @lipo -archs build/DerivedData-Intel/Build/Products/Release/bitchat.app/Contents/MacOS/bitchat | grep -q "x86_64"
    @mkdir -p dist
    @rm -f dist/bitchat-macos13-intel.zip
    @ditto -c -k --sequesterRsrc --keepParent build/DerivedData-Intel/Build/Products/Release/bitchat.app dist/bitchat-macos13-intel.zip
    @echo "✅ Created dist/bitchat-macos13-intel.zip"

# Run the macOS app
run: build
    @echo "Launching BitChat..."
    @find ~/Library/Developer/Xcode/DerivedData -name "bitchat.app" -path "*/Debug/*" -not -path "*/Index.noindex/*" | head -1 | xargs -I {} open "{}"

# Clean build artifacts and restore original files
clean: restore
    @echo "Cleaning build artifacts..."
    @rm -rf ~/Library/Developer/Xcode/DerivedData/bitchat-* 2>/dev/null || true
    @# Only remove the generated project if we have a backup, otherwise use git
    @if [ -f bitchat.xcodeproj/project.pbxproj.backup ]; then \
        rm -rf bitchat.xcodeproj; \
    else \
        git checkout -- bitchat.xcodeproj/project.pbxproj 2>/dev/null || echo "⚠️  Could not restore project.pbxproj"; \
    fi
    @rm -f project-macos.yml 2>/dev/null || true
    @echo "✅ Cleaned and restored original files"

# Quick run without cleaning (for development)
dev-run: check
    @echo "Quick development build..."
    @xcodebuild -project bitchat.xcodeproj -scheme "bitchat_macOS" -configuration Debug CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" build
    @find ~/Library/Developer/Xcode/DerivedData -name "bitchat.app" -path "*/Debug/*" -not -path "*/Index.noindex/*" | head -1 | xargs -I {} open "{}"

# Show app info
info:
    @echo "BitChat - Decentralized Mesh Messaging"
    @echo "======================================"
    @echo "• Native macOS SwiftUI app"
    @echo "• Bluetooth LE mesh networking"
    @echo "• End-to-end encryption"
    @echo "• No internet required"
    @echo "• Works offline with nearby devices"
    @echo ""
    @echo "Requirements:"
    @echo "• macOS 13.0+ (Ventura)"
    @echo "• Bluetooth LE capable Mac"
    @echo "• Physical device (no simulator support)"
    @echo ""
    @echo "Usage:"
    @echo "• Set nickname and start chatting"
    @echo "• Use /join #channel for group chats"
    @echo "• Use /msg @user for private messages"
    @echo "• Triple-tap logo for emergency wipe"

# Force clean everything (nuclear option)
nuke:
    @echo "🧨 Nuclear clean - removing all build artifacts and backups..."
    @rm -rf ~/Library/Developer/Xcode/DerivedData/bitchat-* 2>/dev/null || true
    @rm -rf bitchat.xcodeproj 2>/dev/null || true
    @rm -f bitchat.xcodeproj/project.pbxproj.backup 2>/dev/null || true
    @rm -f bitchat/Info.plist.backup 2>/dev/null || true
    @# Restore iOS-specific files if they were moved
    @if [ -f bitchat/LaunchScreen.storyboard.ios ]; then mv bitchat/LaunchScreen.storyboard.ios bitchat/LaunchScreen.storyboard; fi
    @git checkout bitchat.xcodeproj/project.pbxproj bitchat/Info.plist 2>/dev/null || echo "⚠️  Not a git repo or no changes to restore"
    @echo "✅ Nuclear clean complete"
