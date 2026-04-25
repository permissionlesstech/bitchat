#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR"
SOURCE_DIR="${1:-${NDR_SOURCE_DIR:-$HOME/src/nostr-double-ratchet}}"
RUST_ROOT="$SOURCE_DIR/rust"

MACOS_MIN="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
IOS_MIN="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"

if [[ ! -d "$RUST_ROOT" ]]; then
    echo "error: expected nostr-double-ratchet checkout at $SOURCE_DIR" >&2
    exit 1
fi

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ndrffi-apple.XXXXXX")"
TARGET_DIR="$WORK_ROOT/target"
OUT_DIR="$WORK_ROOT/out"
BINDINGS_DIR="$OUT_DIR/bindings"
HEADERS_DIR="$OUT_DIR/headers"

cleanup() {
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

mkdir -p "$BINDINGS_DIR" "$HEADERS_DIR"

echo "==> Building ndr-ffi from $SOURCE_DIR"
echo "    macOS minimum: $MACOS_MIN"
echo "    iOS minimum:   $IOS_MIN"

cd "$RUST_ROOT"

echo "==> Generating Swift bindings"
env \
    CARGO_TARGET_DIR="$TARGET_DIR" \
    cargo build -p ndr-ffi --lib

env \
    CARGO_TARGET_DIR="$TARGET_DIR" \
    cargo run -p ndr-ffi --features bindgen-cli --bin uniffi-bindgen -- \
        generate \
        --library "$TARGET_DIR/debug/libndr_ffi.dylib" \
        --language swift \
        --out-dir "$BINDINGS_DIR"

cp "$BINDINGS_DIR/ndr_ffiFFI.h" "$HEADERS_DIR/ndr_ffiFFI.h"

cat > "$HEADERS_DIR/module.modulemap" <<'EOF'
module ndr_ffiFFI {
    header "ndr_ffiFFI.h"
    export *
}
EOF

echo "==> Building macOS slices"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    env \
        CARGO_TARGET_DIR="$TARGET_DIR" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
        CFLAGS_aarch64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        CXXFLAGS_aarch64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        CFLAGS_x86_64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        CXXFLAGS_x86_64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        RUSTFLAGS="-C link-arg=-mmacosx-version-min=$MACOS_MIN" \
        cargo build -p ndr-ffi --lib --release --target "$target"
done

echo "==> Building iOS slices"
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    env \
        CARGO_TARGET_DIR="$TARGET_DIR" \
        IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN" \
        cargo build -p ndr-ffi --lib --release --target "$target"
done

MACOS_ARM64_LIB="$TARGET_DIR/aarch64-apple-darwin/release/libndr_ffi.a"
MACOS_X64_LIB="$TARGET_DIR/x86_64-apple-darwin/release/libndr_ffi.a"
MACOS_FAT_LIB="$OUT_DIR/libndr_ffi_macos.a"
if [[ -f "$MACOS_ARM64_LIB" ]] && [[ -f "$MACOS_X64_LIB" ]]; then
    lipo -create "$MACOS_ARM64_LIB" "$MACOS_X64_LIB" -output "$MACOS_FAT_LIB"
elif [[ -f "$MACOS_ARM64_LIB" ]]; then
    cp "$MACOS_ARM64_LIB" "$MACOS_FAT_LIB"
elif [[ -f "$MACOS_X64_LIB" ]]; then
    cp "$MACOS_X64_LIB" "$MACOS_FAT_LIB"
fi

SIM_ARM64_LIB="$TARGET_DIR/aarch64-apple-ios-sim/release/libndr_ffi.a"
SIM_X64_LIB="$TARGET_DIR/x86_64-apple-ios/release/libndr_ffi.a"
SIM_FAT_LIB="$OUT_DIR/libndr_ffi_sim.a"
if [[ -f "$SIM_ARM64_LIB" ]] && [[ -f "$SIM_X64_LIB" ]]; then
    lipo -create "$SIM_ARM64_LIB" "$SIM_X64_LIB" -output "$SIM_FAT_LIB"
elif [[ -f "$SIM_ARM64_LIB" ]]; then
    cp "$SIM_ARM64_LIB" "$SIM_FAT_LIB"
elif [[ -f "$SIM_X64_LIB" ]]; then
    cp "$SIM_X64_LIB" "$SIM_FAT_LIB"
fi

echo "==> Assembling XCFramework"
xcodebuild -create-xcframework \
    -library "$MACOS_FAT_LIB" -headers "$HEADERS_DIR" \
    -library "$TARGET_DIR/aarch64-apple-ios/release/libndr_ffi.a" -headers "$HEADERS_DIR" \
    -library "$SIM_FAT_LIB" -headers "$HEADERS_DIR" \
    -output "$OUT_DIR/NdrFfi.xcframework"

echo "==> Updating vendored package"
cp "$BINDINGS_DIR/ndr_ffi.swift" "$PACKAGE_DIR/Sources/NdrFfi/NdrFfi.swift"
rm -rf "$PACKAGE_DIR/Frameworks/NdrFfi.xcframework"
cp -R "$OUT_DIR/NdrFfi.xcframework" "$PACKAGE_DIR/Frameworks/NdrFfi.xcframework"

echo "==> Stripping debug info from vendored static libraries"
for lib in "$PACKAGE_DIR"/Frameworks/NdrFfi.xcframework/*/libndr_ffi*.a; do
    [[ -f "$lib" ]] && xcrun strip -S "$lib"
done

echo "==> Done"
echo "    Updated $PACKAGE_DIR/Sources/NdrFfi/NdrFfi.swift"
echo "    Updated $PACKAGE_DIR/Frameworks/NdrFfi.xcframework"
