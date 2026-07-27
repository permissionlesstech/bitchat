#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR"
REPOSITORY_DIR="$(cd "$PACKAGE_DIR/../.." && pwd)"
SOURCE_DIR="${1:-${IRIS_CHAT_RS_DIR:-$REPOSITORY_DIR/vendor/iris-chat-rs}}"
CRATE_DIR="$SOURCE_DIR/protocol-ffi"
CRATE_MANIFEST="$CRATE_DIR/Cargo.toml"
BINDGEN_MANIFEST="$SOURCE_DIR/core/uniffi-bindgen/Cargo.toml"
EXPECTED_REVISION="$(tr -d '[:space:]' < "$PACKAGE_DIR/SOURCE_REVISION")"
EXPECTED_RUST="$(tr -d '[:space:]' < "$PACKAGE_DIR/RUST_TOOLCHAIN")"

# These are reproducibility inputs, not ambient build-machine preferences.
# Keep them aligned with the application's documented minimum OS versions.
MACOS_MIN="13.0"
IOS_MIN="16.0"
FRAMEWORK_NAME="ndr_ffiFFI"
INSTALL_NAME="@rpath/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"

if [[ ! -f "$CRATE_MANIFEST" ]]; then
    echo "error: expected iris-chat-rs protocol-ffi crate at $CRATE_MANIFEST" >&2
    exit 1
fi

if [[ ! -f "$BINDGEN_MANIFEST" ]]; then
    echo "error: expected UniFFI bindgen helper at $BINDGEN_MANIFEST" >&2
    exit 1
fi

ACTUAL_RUST="$(rustc --version | awk '{print $2}')"
if [[ "$ACTUAL_RUST" != "$EXPECTED_RUST" ]]; then
    echo "error: rustc $ACTUAL_RUST is active; NdrFfi is pinned to $EXPECTED_RUST" >&2
    echo "install/select it with rustup before rebuilding" >&2
    exit 1
fi

if [[ -d "$SOURCE_DIR/.git" ]] || git -C "$SOURCE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    ACTUAL_REVISION="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    if [[ "$ACTUAL_REVISION" != "$EXPECTED_REVISION" ]]; then
        echo "error: iris-chat-rs is at $ACTUAL_REVISION; expected $EXPECTED_REVISION" >&2
        echo "run: git submodule update --init --checkout vendor/iris-chat-rs" >&2
        exit 1
    fi
fi

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ndrffi-apple.XXXXXX")"
TARGET_DIR="${NDR_FFI_TARGET_DIR:-$REPOSITORY_DIR/.cache/ndr-ffi/apple/target}"
OUT_DIR="$WORK_ROOT/out"
BINDINGS_DIR="$OUT_DIR/bindings"
HEADERS_DIR="$OUT_DIR/headers"

cleanup() {
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

mkdir -p "$TARGET_DIR" "$BINDINGS_DIR" "$HEADERS_DIR"

echo "==> Building ndr_ffi compatibility artifacts from $CRATE_DIR"
echo "    macOS minimum: $MACOS_MIN"
echo "    iOS minimum:   $IOS_MIN"

cd "$CRATE_DIR"

echo "==> Generating Swift bindings"
env \
    CARGO_TARGET_DIR="$TARGET_DIR" \
    cargo build --locked --manifest-path "$CRATE_MANIFEST" --lib

env \
    CARGO_TARGET_DIR="$TARGET_DIR" \
    cargo run --locked --manifest-path "$BINDGEN_MANIFEST" -- \
        generate \
        --library "$TARGET_DIR/debug/libndr_ffi.dylib" \
        --language swift \
        --out-dir "$BINDINGS_DIR"

cp "$BINDINGS_DIR/ndr_ffiFFI.h" "$HEADERS_DIR/ndr_ffiFFI.h"

echo "==> Building dynamic macOS slices"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    env \
        CARGO_TARGET_DIR="$TARGET_DIR" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
        CFLAGS_aarch64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        CXXFLAGS_aarch64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        CFLAGS_x86_64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        CXXFLAGS_x86_64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        RUSTFLAGS="-C panic=abort -C strip=debuginfo -C link-arg=-mmacosx-version-min=$MACOS_MIN -C link-arg=-Wl,-install_name,$INSTALL_NAME" \
        cargo build --locked --manifest-path "$CRATE_MANIFEST" --lib --release --target "$target"
done

echo "==> Building dynamic iOS slices"
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    env \
        CARGO_TARGET_DIR="$TARGET_DIR" \
        IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN" \
        RUSTFLAGS="-C panic=abort -C strip=debuginfo -C link-arg=-Wl,-install_name,$INSTALL_NAME" \
        cargo build --locked --manifest-path "$CRATE_MANIFEST" --lib --release --target "$target"
done

MACOS_DYLIB="$OUT_DIR/libndr_ffi_macos.dylib"
SIM_DYLIB="$OUT_DIR/libndr_ffi_sim.dylib"
lipo -create \
    "$TARGET_DIR/aarch64-apple-darwin/release/libndr_ffi.dylib" \
    "$TARGET_DIR/x86_64-apple-darwin/release/libndr_ffi.dylib" \
    -output "$MACOS_DYLIB"
lipo -create \
    "$TARGET_DIR/aarch64-apple-ios-sim/release/libndr_ffi.dylib" \
    "$TARGET_DIR/x86_64-apple-ios/release/libndr_ffi.dylib" \
    -output "$SIM_DYLIB"

make_framework() {
    local binary="$1"
    local destination="$2"
    local supported_platform="$3"
    local minimum_version="$4"
    local framework="$destination/$FRAMEWORK_NAME.framework"
    local contents="$framework"
    local plist="$framework/Info.plist"

    if [[ "$supported_platform" == "MacOSX" ]]; then
        contents="$framework/Versions/A"
        plist="$contents/Resources/Info.plist"
        mkdir -p "$contents/Headers" "$contents/Modules" "$contents/Resources"
    else
        mkdir -p "$contents/Headers" "$contents/Modules"
    fi

    cp "$binary" "$contents/$FRAMEWORK_NAME"
    chmod +x "$contents/$FRAMEWORK_NAME"
    cp "$HEADERS_DIR/ndr_ffiFFI.h" "$contents/Headers/ndr_ffiFFI.h"

    cat > "$contents/Modules/module.modulemap" <<EOF
framework module $FRAMEWORK_NAME {
    header "ndr_ffiFFI.h"
    export *
}
EOF

    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>chat.bitchat.ndrffi</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$FRAMEWORK_NAME</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>$minimum_version</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>$supported_platform</string>
    </array>
</dict>
</plist>
EOF

    if [[ "$supported_platform" == "MacOSX" ]]; then
        ln -s A "$framework/Versions/Current"
        ln -s "Versions/Current/$FRAMEWORK_NAME" "$framework/$FRAMEWORK_NAME"
        ln -s Versions/Current/Headers "$framework/Headers"
        ln -s Versions/Current/Modules "$framework/Modules"
        ln -s Versions/Current/Resources "$framework/Resources"
    fi
}

DEVICE_ROOT="$OUT_DIR/iphoneos"
SIM_ROOT="$OUT_DIR/iphonesimulator"
MACOS_ROOT="$OUT_DIR/macos"
make_framework \
    "$TARGET_DIR/aarch64-apple-ios/release/libndr_ffi.dylib" \
    "$DEVICE_ROOT" \
    "iPhoneOS" \
    "$IOS_MIN"
make_framework "$SIM_DYLIB" "$SIM_ROOT" "iPhoneSimulator" "$IOS_MIN"
make_framework "$MACOS_DYLIB" "$MACOS_ROOT" "MacOSX" "$MACOS_MIN"

echo "==> Assembling dynamic XCFramework"
xcodebuild -create-xcframework \
    -framework "$DEVICE_ROOT/$FRAMEWORK_NAME.framework" \
    -framework "$SIM_ROOT/$FRAMEWORK_NAME.framework" \
    -framework "$MACOS_ROOT/$FRAMEWORK_NAME.framework" \
    -output "$OUT_DIR/NdrFfi.xcframework"

echo "==> Updating generated package outputs"
LC_ALL=C sed -E 's/[[:blank:]]+$//' \
    "$BINDINGS_DIR/ndr_ffi.swift" \
    > "$BINDINGS_DIR/ndr_ffi.swift.normalized"
mv "$BINDINGS_DIR/ndr_ffi.swift.normalized" "$BINDINGS_DIR/ndr_ffi.swift"
cp "$BINDINGS_DIR/ndr_ffi.swift" "$PACKAGE_DIR/Sources/NdrFfi/NdrFfi.swift"
rm -rf "$PACKAGE_DIR/Frameworks/NdrFfi.xcframework"
cp -R "$OUT_DIR/NdrFfi.xcframework" "$PACKAGE_DIR/Frameworks/NdrFfi.xcframework"

echo "==> Verifying dynamic framework install names"
for binary in "$PACKAGE_DIR"/Frameworks/NdrFfi.xcframework/*/"$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"; do
    otool -D "$binary" | grep -F "$INSTALL_NAME" >/dev/null
done

echo "==> Done"
echo "    Updated $PACKAGE_DIR/Sources/NdrFfi/NdrFfi.swift"
echo "    Updated $PACKAGE_DIR/Frameworks/NdrFfi.xcframework"
