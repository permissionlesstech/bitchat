#!/bin/bash
#
# Rebuild Arti's iOS slices: physical-iOS arm64 and the arm64/x86_64 simulator
# pair. Both export the transport FFI, so the app links on a device and in the
# simulator where CI builds and runs the tests. The macOS slice remains
# unchanged; its Swift callers compile only on iOS.
#
set -euo pipefail

export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-1.96.0}"
RUSTC_VERSION="${RUSTC_VERSION:-1.96.0}"
CBINDGEN_VERSION="${CBINDGEN_VERSION:-0.29.4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_TARGET="aarch64-apple-ios"
SIMULATOR_TARGETS=("aarch64-apple-ios-sim" "x86_64-apple-ios")
FRAMEWORK="$SCRIPT_DIR/Frameworks/arti.xcframework"
NORMALIZED="$(mktemp)"
SIMULATOR_FAT="$(mktemp)"
GENERATED_HEADER="$(mktemp)"

cleanup() {
    rm -f "$NORMALIZED" "$SIMULATOR_FAT" "$GENERATED_HEADER"
}
trap cleanup EXIT

actual_rustc="$(rustup run "$RUST_TOOLCHAIN" rustc --version)"
if [[ "$actual_rustc" != "rustc $RUSTC_VERSION "* ]]; then
    echo "expected rustc $RUSTC_VERSION; found $actual_rustc"
    exit 2
fi
if [[ "$(cbindgen --version)" != "cbindgen $CBINDGEN_VERSION" ]]; then
    echo "expected cbindgen $CBINDGEN_VERSION"
    exit 3
fi

build_target() {
    local target="$1"
    rustup target add --toolchain "$RUST_TOOLCHAIN" "$target"
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    IPHONEOS_DEPLOYMENT_TARGET=16.0 \
    RUSTFLAGS="-C opt-level=z -C lto=fat -C codegen-units=1 -C panic=abort -C strip=symbols" \
    rustup run "$RUST_TOOLCHAIN" cargo build \
        --manifest-path "$SCRIPT_DIR/Cargo.toml" \
        --release \
        --target "$target" \
        -p arti-bitchat
}

# Normalize archive metadata so the installed library depends only on its
# object contents, not on build paths or timestamps.
install_library() {
    local source="$1"
    local destination="$2"
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcrun libtool -static -D -no_warning_for_no_symbols "$source" -o "$NORMALIZED"
    cp "$NORMALIZED" "$destination"
}

build_target "$DEVICE_TARGET"
install_library \
    "$SCRIPT_DIR/target/$DEVICE_TARGET/release/libarti_bitchat.a" \
    "$FRAMEWORK/ios-arm64/libarti_bitchat.a"

simulator_libraries=()
for target in "${SIMULATOR_TARGETS[@]}"; do
    build_target "$target"
    simulator_libraries+=("$SCRIPT_DIR/target/$target/release/libarti_bitchat.a")
done

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcrun lipo -create "${simulator_libraries[@]}" -output "$SIMULATOR_FAT"
install_library \
    "$SIMULATOR_FAT" \
    "$FRAMEWORK/ios-arm64_x86_64-simulator/libarti_bitchat.a"

(cd "$SCRIPT_DIR" && cbindgen \
    --config arti-bitchat/cbindgen.toml \
    --crate arti-bitchat \
    --output "$GENERATED_HEADER")
cp "$GENERATED_HEADER" "$SCRIPT_DIR/Frameworks/include/arti.h"
cp "$GENERATED_HEADER" "$FRAMEWORK/ios-arm64/Headers/arti.h"
cp "$GENERATED_HEADER" "$FRAMEWORK/ios-arm64_x86_64-simulator/Headers/arti.h"

echo "installed iOS device and simulator Arti slices"
