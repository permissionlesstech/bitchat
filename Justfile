# BitChat macOS Build Justfile
# Handles temporary modifications needed to build and run on macOS

# Default recipe - shows available commands
default:
    @echo "BitChat macOS Build Commands:"
    @echo "  just run     - Build and run the macOS app"
    @echo "  just build   - Build the macOS app only"
    @echo "  just clean   - Clean build artifacts and restore original files"
    @echo "  just check   - Check prerequisites"
    @echo ""
    @echo "Original files are preserved - modifications are temporary for builds only"

# Check prerequisites
check:
    @echo "Checking prerequisites..."
    @command -v xcodegen >/dev/null 2>&1 || (echo "❌ XcodeGen not found. Install with: brew install xcodegen" && exit 1)
    @command -v xcodebuild >/dev/null 2>&1 || (echo "❌ Xcode not found. Install Xcode from App Store" && exit 1)
    @security find-identity -v -p codesigning | grep -q "Developer ID" || (echo "⚠️  No Developer ID found - code signing may fail" && exit 0)
    @echo "✅ All prerequisites met"

# Backup original files
backup:
    @echo "Backing up original project configuration..."
    @cp project.yml project.yml.backup 2>/dev/null || true
    @# Backup other files that get modified by xcodegen
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

# Generate Xcode project with patches
generate: patch-for-macos
    @echo "Generating Xcode project..."
    @xcodegen generate

# Build the macOS app
build: check generate
    @echo "Building BitChat for macOS..."
    @xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" -configuration Debug CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" build

# Run the macOS app
run: build
    @echo "Launching BitChat..."
    @find ~/Library/Developer/Xcode/DerivedData -name "bitchat.app" -path "*/Debug/*" | head -1 | xargs -I {} open "{}"

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
    @if [ ! -f project.yml.backup ]; then just patch-for-macos; fi
    @xcodegen generate
    @xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" -configuration Debug CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" build
    @find ~/Library/Developer/Xcode/DerivedData -name "bitchat.app" -path "*/Debug/*" | head -1 | xargs -I {} open "{}"

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
    @rm -f project.yml.backup 2>/dev/null || true
    @rm -f project-macos.yml 2>/dev/null || true
    @rm -f bitchat.xcodeproj/project.pbxproj.backup 2>/dev/null || true
    @rm -f bitchat/Info.plist.backup 2>/dev/null || true
    @# Restore iOS-specific files if they were moved
    @if [ -f bitchat/LaunchScreen.storyboard.ios ]; then mv bitchat/LaunchScreen.storyboard.ios bitchat/LaunchScreen.storyboard; fi
    @git checkout -- project.yml bitchat.xcodeproj/project.pbxproj bitchat/Info.plist 2>/dev/null || echo "⚠️  Not a git repo or no changes to restore"
    @echo "✅ Nuclear clean complete"
