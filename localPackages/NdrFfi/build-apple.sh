#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR"
REPOSITORY_DIR="$(cd "$PACKAGE_DIR/../.." && pwd)"
SOURCE_DIR="${NOSTR_DOUBLE_RATCHET_DIR:-$REPOSITORY_DIR/vendor/nostr-double-ratchet}"
PLATFORM="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            [[ $# -ge 2 ]] || { echo "error: --platform requires macos, ios, or all" >&2; exit 1; }
            PLATFORM="$2"
            shift 2
            ;;
        --*) echo "error: unknown option $1" >&2; exit 1 ;;
        *) SOURCE_DIR="$1"; shift ;;
    esac
done
case "$PLATFORM" in
    macos|ios|all) ;;
    *) echo "error: --platform requires macos, ios, or all" >&2; exit 1 ;;
esac
CRATE_DIR="$SOURCE_DIR/rust/crates/ndr-pairwise-ffi"
CRATE_MANIFEST="$CRATE_DIR/Cargo.toml"
BINDGEN_MANIFEST="$CRATE_MANIFEST"
EXPECTED_REVISION="$(tr -d '[:space:]' < "$PACKAGE_DIR/SOURCE_REVISION")"
EXPECTED_RUST="$(tr -d '[:space:]' < "$PACKAGE_DIR/RUST_TOOLCHAIN")"
# A user-level Cargo config may point at a compiler cache unavailable to CI or
# the current sandbox, so this reproducible build does not use an ambient wrapper.
export RUSTC_WRAPPER=""

# These are reproducibility inputs, not ambient build-machine preferences.
# Keep them aligned with the application's documented minimum OS versions.
MACOS_MIN="13.0"
IOS_MIN="16.0"
FRAMEWORK_NAME="ndr_ffiFFI"
INSTALL_NAME="@rpath/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"

if [[ ! -f "$CRATE_MANIFEST" ]]; then
    echo "error: expected nostr-double-ratchet pairwise FFI crate at $CRATE_MANIFEST" >&2
    exit 1
fi

if [[ ! -f "$BINDGEN_MANIFEST" ]]; then
    echo "error: expected UniFFI bindgen manifest at $BINDGEN_MANIFEST" >&2
    exit 1
fi

ACTUAL_RUST="$(rustc +"$EXPECTED_RUST" --version | awk '{print $2}')"
if [[ "$ACTUAL_RUST" != "$EXPECTED_RUST" ]]; then
    echo "error: selected rustc is $ACTUAL_RUST; NdrFfi is pinned to $EXPECTED_RUST" >&2
    echo "install the pinned toolchain with rustup before rebuilding" >&2
    exit 1
fi

if ! git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: nostr-double-ratchet source must be the pinned Git submodule at $SOURCE_DIR" >&2
    exit 1
fi
SOURCE_WORKTREE="$(cd "$SOURCE_DIR" && pwd -P)"
SOURCE_GIT_ROOT="$(git -C "$SOURCE_DIR" rev-parse --show-toplevel)"
if [[ "$SOURCE_GIT_ROOT" != "$SOURCE_WORKTREE" ]]; then
    echo "error: nostr-double-ratchet Git root is $SOURCE_GIT_ROOT; expected $SOURCE_WORKTREE" >&2
    exit 1
fi
ACTUAL_REVISION="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$ACTUAL_REVISION" != "$EXPECTED_REVISION" ]]; then
    echo "error: nostr-double-ratchet is at $ACTUAL_REVISION; expected $EXPECTED_REVISION" >&2
    echo "run: git submodule update --init --checkout vendor/nostr-double-ratchet" >&2
    exit 1
fi
if [[ -n "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all)" ]]; then
    echo "error: nostr-double-ratchet source has local changes; refusing an unreproducible build" >&2
    exit 1
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

echo "==> Building the pairwise ndr_ffi artifacts from $CRATE_DIR"
echo "    macOS minimum: $MACOS_MIN"
echo "    iOS minimum:   $IOS_MIN"

cd "$CRATE_DIR"

echo "==> Generating Swift bindings"
env \
    CARGO_TARGET_DIR="$TARGET_DIR" \
    cargo +"$EXPECTED_RUST" build --locked --manifest-path "$CRATE_MANIFEST" --lib

env \
    CARGO_TARGET_DIR="$TARGET_DIR" \
    cargo +"$EXPECTED_RUST" run --locked --manifest-path "$BINDGEN_MANIFEST" --features bindgen --bin uniffi-bindgen -- \
        generate \
        --library "$TARGET_DIR/debug/libndr_ffi.dylib" \
        --language swift \
        --out-dir "$BINDINGS_DIR"

LC_ALL=C sed -E 's/[[:blank:]]+$//' \
    "$BINDINGS_DIR/ndr_ffi.swift" \
    > "$BINDINGS_DIR/ndr_ffi.swift.normalized"
mv "$BINDINGS_DIR/ndr_ffi.swift.normalized" "$BINDINGS_DIR/ndr_ffi.swift"
EXPECTED_BINDINGS_SHA256="$(tr -d '[:space:]' < "$PACKAGE_DIR/SWIFT_BINDINGS_SHA256")"
ACTUAL_BINDINGS_SHA256="$(shasum -a 256 "$BINDINGS_DIR/ndr_ffi.swift" | awk '{print $1}')"
if [[ "$ACTUAL_BINDINGS_SHA256" != "$EXPECTED_BINDINGS_SHA256" ]]; then
    echo "error: generated Swift bindings differ from the pinned digest" >&2
    exit 1
fi

cp "$BINDINGS_DIR/ndr_ffiFFI.h" "$HEADERS_DIR/ndr_ffiFFI.h"

targets=()
if [[ "$PLATFORM" != "ios" ]]; then
    targets+=(aarch64-apple-darwin x86_64-apple-darwin)
fi
if [[ "$PLATFORM" != "macos" ]]; then
    targets+=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
fi
for target in "${targets[@]}"; do
    echo "==> Building dynamic $target slice"
    link_flags="-C panic=abort -C strip=debuginfo -C link-arg=-Wl,-install_name,$INSTALL_NAME"
    if [[ "$target" == *-darwin ]]; then
        link_flags+=" -C link-arg=-mmacosx-version-min=$MACOS_MIN"
    fi
    env \
        CARGO_TARGET_DIR="$TARGET_DIR" \
        MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
        IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN" \
        CFLAGS_aarch64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        CXXFLAGS_aarch64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        CFLAGS_x86_64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        CXXFLAGS_x86_64_apple_darwin="-mmacosx-version-min=$MACOS_MIN" \
        RUSTFLAGS="$link_flags" \
        cargo +"$EXPECTED_RUST" build --locked --manifest-path "$CRATE_MANIFEST" --lib --release --target "$target"
done

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

framework_args=()
if [[ "$PLATFORM" != "macos" ]]; then
    SIM_DYLIB="$OUT_DIR/libndr_ffi_sim.dylib"
    lipo -create \
        "$TARGET_DIR/aarch64-apple-ios-sim/release/libndr_ffi.dylib" \
        "$TARGET_DIR/x86_64-apple-ios/release/libndr_ffi.dylib" \
        -output "$SIM_DYLIB"
    make_framework \
        "$TARGET_DIR/aarch64-apple-ios/release/libndr_ffi.dylib" \
        "$OUT_DIR/iphoneos" "iPhoneOS" "$IOS_MIN"
    make_framework "$SIM_DYLIB" "$OUT_DIR/iphonesimulator" "iPhoneSimulator" "$IOS_MIN"
    framework_args+=(-framework "$OUT_DIR/iphoneos/$FRAMEWORK_NAME.framework")
    framework_args+=(-framework "$OUT_DIR/iphonesimulator/$FRAMEWORK_NAME.framework")
fi
if [[ "$PLATFORM" != "ios" ]]; then
    MACOS_DYLIB="$OUT_DIR/libndr_ffi_macos.dylib"
    lipo -create \
        "$TARGET_DIR/aarch64-apple-darwin/release/libndr_ffi.dylib" \
        "$TARGET_DIR/x86_64-apple-darwin/release/libndr_ffi.dylib" \
        -output "$MACOS_DYLIB"
    make_framework "$MACOS_DYLIB" "$OUT_DIR/macos" "MacOSX" "$MACOS_MIN"
    framework_args+=(-framework "$OUT_DIR/macos/$FRAMEWORK_NAME.framework")
fi

echo "==> Assembling dynamic XCFramework ($PLATFORM)"
xcodebuild -create-xcframework \
    "${framework_args[@]}" \
    -output "$OUT_DIR/NdrFfi.xcframework"

echo "==> Updating generated package outputs"
mkdir -p "$PACKAGE_DIR/Sources/NdrFfi"
cp "$BINDINGS_DIR/ndr_ffi.swift" "$PACKAGE_DIR/Sources/NdrFfi/NdrFfi.swift"
mkdir -p "$PACKAGE_DIR/Frameworks"
rm -rf "$PACKAGE_DIR/Frameworks/NdrFfi.xcframework"
cp -R "$OUT_DIR/NdrFfi.xcframework" "$PACKAGE_DIR/Frameworks/NdrFfi.xcframework"

echo "==> Verifying dynamic framework install names"
for binary in "$PACKAGE_DIR"/Frameworks/NdrFfi.xcframework/*/"$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"; do
    otool -D "$binary" | grep -F "$INSTALL_NAME" >/dev/null
done

echo "==> Done"
echo "    Updated $PACKAGE_DIR/Sources/NdrFfi/NdrFfi.swift"
echo "    Updated $PACKAGE_DIR/Frameworks/NdrFfi.xcframework"
