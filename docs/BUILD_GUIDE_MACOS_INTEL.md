# BitChat Intel macOS 13 Build Guide

This guide provides step-by-step instructions to enable **Intel x86_64** compilation support for macOS 13 (Ventura) on the BitChat project. The current GitHub repository only includes Apple Silicon (ARM64) support. This document explains what changes are needed.

## Problem

The `bitchat` repository from GitHub currently **does not support Intel x86_64 architecture** for macOS. The project only builds for:
- iOS (ARM64 device + ARM64 simulator)
- macOS ARM64 (Apple Silicon only)

Users on Intel-based Macs will encounter build failures because:
1. The Arti Rust dependency only compiles for `aarch64-apple-darwin` (Apple Silicon)
2. The Justfile does not provide Intel build targets
3. The xcframework lacks the Intel macOS slice

## Prerequisites

Before applying these changes, ensure you have:

-- **Xcode 15+** installed (full installation, not just command-line tools)
- **Rust/Cargo** installed via [rustup](https://rustup.rs/)
- **Target support**: The build script will automatically add required Rust targets
- **macOS 13+** (for building AND deployment target)

Verify your setup:
```zsh
xcodebuild -version
rustc --version
```

## Changes Required

### 1. Update `Justfile` with Intel Build Recipes

**File**: `Justfile`

**Changes**: Add three new recipes to the Justfile:

#### A. Update the default recipe help text

Find the `default:` recipe and add two new echo lines:

```justfile
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
```

#### B. Add Arti Intel preparation recipe

After the existing `build` recipe, add:

```justfile
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
```

#### C. Add Intel macOS 13 build recipe

```justfile
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
```

#### D. Add convenience alias

```justfile
# Friendly alias for one-command Intel build
intel13: build-intel-macos13
```

#### E. Add packaging recipe (optional but recommended)

```justfile
# Build Intel macOS 13 app and package as zip for transfer
package-intel-macos13: build-intel-macos13
    @echo "Packaging Intel macOS app..."
    @test -f build/DerivedData-Intel/Build/Products/Release/bitchat.app/Contents/MacOS/bitchat
    @lipo -archs build/DerivedData-Intel/Build/Products/Release/bitchat.app/Contents/MacOS/bitchat | grep -q "x86_64"
    @mkdir -p dist
    @rm -f dist/bitchat-macos13-intel.zip
    @ditto -c -k --sequesterRsrc --keepParent build/DerivedData-Intel/Build/Products/Release/bitchat.app dist/bitchat-macos13-intel.zip
    @echo "Created dist/bitchat-macos13-intel.zip"
```

### 2. Update `localPackages/Arti/build-ios.sh` to Include Intel Targets

**File**: `localPackages/Arti/build-ios.sh`

**Change**: Update the `TARGETS` array (around line 23-26) to include Intel x86_64 targets:

**Before** (current, Apple Silicon only):
```zsh
TARGETS=(
    "aarch64-apple-ios"           # iOS device
    "aarch64-apple-ios-sim"       # iOS simulator (Apple Silicon)
    "aarch64-apple-darwin"        # macOS
)
```

**After** (with Intel support):
```zsh
TARGETS=(
    "aarch64-apple-ios"           # iOS device
    "aarch64-apple-ios-sim"       # iOS simulator (Apple Silicon)
    "x86_64-apple-ios"            # iOS simulator (Intel) - optional
    "x86_64-apple-darwin"         # macOS (Intel)
)
```

### 3. Verify Other Files (No Changes Needed)

The following files are already correct and require **no modifications**:
- `Package.swift` (Swift Package Manager manifest) — already targets macOS 13
- `Configs/Release.xcconfig` — already supports Intel architecture
- `localPackages/Arti/Package.swift` — already references the xcframework correctly
- All other Xcode project files

## Implementation Steps

### Option A: Automatic (if `just` is installed)

```zsh
cd ~/src/bitchat
# Install just if needed: brew install just

# Just build for Intel macOS 13
just intel13

# Or build and package as zip
just package-intel-macos13
```

### Option B: Manual Build Commands

If you don't have `just` installed:

```zsh
cd ~/src/bitchat

# Step 1: Prepare Arti for Intel
cd localPackages/Arti
rustup target add x86_64-apple-darwin
cargo build --release --target x86_64-apple-darwin -p arti-bitchat
rm -rf Frameworks/arti.xcframework
xcodebuild -create-xcframework \
  -library target/x86_64-apple-darwin/release/libarti_bitchat.a \
  -headers Frameworks/include \
  -output Frameworks/arti.xcframework

# Step 2: Build BitChat for Intel macOS 13
cd ~/src/bitchat
xcodebuild -project bitchat.xcodeproj \
  -scheme "bitchat (macOS)" \
  -configuration Release \
  -derivedDataPath build/DerivedData-Intel \
  -destination 'platform=macOS,arch=x86_64' \
  ARCHS=x86_64 \
  MACOSX_DEPLOYMENT_TARGET=13.0 \
  CODE_SIGNING_ALLOWED=NO \
  build

# Step 3: Verify the build (optional)
lipo -archs build/DerivedData-Intel/Build/Products/Release/bitchat.app/Contents/MacOS/bitchat
# Should output: x86_64
```

### Option C: Package as ZIP for Transfer

After the build completes:

```zsh
cd ~/src/bitchat
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent \
  build/DerivedData-Intel/Build/Products/Release/bitchat.app \
  dist/bitchat-macos13-intel.zip

# Verify
ls -lh dist/bitchat-macos13-intel.zip
```

## Verification

After building, verify the binary is actually x86_64:

```zsh
# Check architecture
file build/DerivedData-Intel/Build/Products/Release/bitchat.app/Contents/MacOS/bitchat
# Output should be: Mach-O 64-bit executable x86_64

# Verify minimum OS requirement
otool -l build/DerivedData-Intel/Build/Products/Release/bitchat.app/Contents/MacOS/bitchat | grep "minos" -A1
# Should show version 13.0 or lower
```

## Building the Full Multi-Architecture Framework (Optional)

If you want to build a complete xcframework with both ARM64 and x86_64 slices:

The `localPackages/Arti/build-ios.sh` script (with the updated TARGETS array) will build all four slices:
1. `aarch64-apple-ios` (iOS device)
2. `aarch64-apple-ios-sim` (iOS simulator on Apple Silicon)
3. `x86_64-apple-ios` (iOS simulator on Intel)
4. `x86_64-apple-darwin` (macOS Intel)

**Note**: The current script has a limitation where it fails when creating an xcframework with duplicate iOS simulator definitions (arm64-sim and x86_64-sim both claiming different platforms). If you need full multi-arch support including iOS, use the Intel-only xcframework approach documented above, or modify the script to handle the iOS slice combinations separately.

## Troubleshooting

### Build fails with "does not contain a binary artifact"

This means the Arti xcframework is missing or invalid.

**Solution**: Clean and rebuild Arti:
```zsh
cd localPackages/Arti
rm -rf target Frameworks/arti.xcframework
cargo build --release --target x86_64-apple-darwin -p arti-bitchat
xcodebuild -create-xcframework \
  -library target/x86_64-apple-darwin/release/libarti_bitchat.a \
  -headers Frameworks/include \
  -output Frameworks/arti.xcframework
```

### Xcode complains about `aarch64-apple-darwin` missing

The fresh clone only has the ARM64 macOS slice. Rebuild with Intel support following the steps above.

### "CODE_SIGNING_REQUIRED" errors

The build command explicitly disables code signing (`CODE_SIGNING_ALLOWED=NO`). If you want to sign the app:

1. Remove `CODE_SIGNING_ALLOWED=NO` from the xcodebuild command
2. Add your Development Team ID: `-DDEVELOPMENT_TEAM=XXXXX` (or configure in Xcode)
3. Ensure entitlements are properly configured

### Build takes very long for Arti

The Rust build with aggressive optimizations (`-C opt-level=z -C lto=fat`) can take 5-15 minutes. This is normal. Subsequent builds will be faster thanks to incremental compilation.

## Build Performance Notes

- **First build**: 10-20 minutes (Rust compilation, full Xcode build)
- **Incremental builds**: 2-5 minutes (if source unchanged)
- **Arti binary size**: ~12 MB (heavily optimized)
- **Final app size**: ~50+ MB (includes assets, localization, Arti)

## How to Distribute

### For Users on Intel Macs:

1. **Zipped App** (recommended):
   ```zsh
   ditto -c -k --sequesterRsrc --keepParent bitchat.app dist/bitchat-macos13-intel.zip
   # Transfer to Intel Mac
   # Extract: unzip bitchat-macos13-intel.zip
   # Run: open bitchat.app
   ```

2. **Direct Execution**:
   - Copy `bitchat.app` directly to `/Applications`
   - Run from Finder or command line

3. **Deployment Requirements**:
   - Intel Mac with macOS 13.0 or later
   - Bluetooth LE capability
   - ~100 MB free disk space

## Integration into Repository

To permanently integrate Intel support into the BitChat repository:

1. Apply changes from Justfile (adds new recipes, backward compatible)
2. Apply changes to `localPackages/Arti/build-ios.sh` (updates TARGETS array)
3. Commit changes to main branch
4. Update CI/CD pipeline to build Intel targets
5. Optional: Update documentation to mention Intel macOS 13 support

## Additional Resources

- [Apple Silicon vs Intel Macs](https://www.apple.com/apple-silicon/)
- [Rust Cross-Compilation Guide](https://rust-lang.github.io/rustup/cross-compilation.html)
- [Xcode Build Settings Reference](https://help.apple.com/xcode/mac/current/#/itunes974235871)

---

**Tested On**: macOS 26.3.1 (Tahoe) with Intel x86_64 architecture  
**BitChat Version**: 1.5.1+
