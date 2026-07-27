#!/bin/bash
#
# Build arti-bitchat for iOS/macOS with aggressive size optimization
#
# Output: Frameworks/arti.xcframework containing static libraries for:
#   - aarch64-apple-ios (iOS device)
#   - aarch64-apple-ios-sim (iOS simulator, Apple Silicon)
#   - x86_64-apple-ios (iOS simulator, Intel)
#   - aarch64-apple-darwin (macOS, Apple Silicon)
#   - x86_64-apple-darwin (macOS, Intel)
#
set -e

# rustup/cargo install tools here on standard setups; GUI/Xcode shells often
# omit it from PATH even though `cargo` itself is available elsewhere.
export PATH="$HOME/.cargo/bin:$PATH"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-1.96.0}"
RUSTC_VERSION="${RUSTC_VERSION:-1.96.0}"
CBINDGEN_VERSION="${CBINDGEN_VERSION:-0.29.4}"
export RUSTC="$(rustup which --toolchain "$RUST_TOOLCHAIN" rustc)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
CRATE_NAME="arti-bitchat"
LIB_NAME="libarti_bitchat.a"
FRAMEWORK_NAME="arti"
OUTPUT_DIR="$SCRIPT_DIR/Frameworks"

# Targets to build
TARGETS=(
    "aarch64-apple-ios"           # iOS device
    "aarch64-apple-ios-sim"       # iOS simulator (Apple Silicon)
    "x86_64-apple-ios"            # iOS simulator (Intel)
    "aarch64-apple-darwin"        # macOS (Apple Silicon)
    "x86_64-apple-darwin"         # macOS (Intel)
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v rustc &> /dev/null; then
        log_error "Rust is not installed. Please install via rustup."
        exit 1
    fi

    if ! rustup run "$RUST_TOOLCHAIN" cargo --version &> /dev/null; then
        log_error "Cargo is not installed in rustup toolchain $RUST_TOOLCHAIN."
        exit 1
    fi

    local actual_rustc
    actual_rustc="$(rustup run "$RUST_TOOLCHAIN" rustc --version)"
    if [[ "$actual_rustc" != "rustc $RUSTC_VERSION "* ]]; then
        log_error "Expected rustc $RUSTC_VERSION in $RUST_TOOLCHAIN; found $actual_rustc."
        exit 1
    fi

    # Check/install targets
    for target in "${TARGETS[@]}"; do
        if ! rustup target list --toolchain "$RUST_TOOLCHAIN" --installed | grep -q "$target"; then
            log_info "Installing target: $target"
            rustup target add --toolchain "$RUST_TOOLCHAIN" "$target"
        fi
    done

    # Install cbindgen if needed
    if ! command -v cbindgen &> /dev/null; then
        log_info "Installing cbindgen $CBINDGEN_VERSION..."
        rustup run "$RUST_TOOLCHAIN" cargo install cbindgen --version "$CBINDGEN_VERSION" --locked
    fi

    if [[ "$(cbindgen --version)" != "cbindgen $CBINDGEN_VERSION" ]]; then
        log_error "Expected cbindgen $CBINDGEN_VERSION; found $(cbindgen --version)."
        exit 1
    fi

    log_info "Prerequisites OK"
}

# Set up aggressive size optimization flags and deployment targets
setup_rustflags() {
    local target="$1"

    # Base flags for size optimization
    export RUSTFLAGS="-C opt-level=z -C lto=fat -C codegen-units=1 -C panic=abort -C strip=symbols"

    # Set deployment targets to suppress linker warnings about version mismatches
    case "$target" in
        *-apple-ios-sim*)
            export IPHONEOS_DEPLOYMENT_TARGET="16.0"
            # Simulator uses iPhone SDK but needs the sim target
            ;;
        *-apple-ios*)
            export IPHONEOS_DEPLOYMENT_TARGET="16.0"
            ;;
        *-apple-darwin*)
            export MACOSX_DEPLOYMENT_TARGET="13.0"
            ;;
    esac

    log_info "RUSTFLAGS: $RUSTFLAGS"
    log_info "Deployment target: MACOSX=$MACOSX_DEPLOYMENT_TARGET IPHONEOS=$IPHONEOS_DEPLOYMENT_TARGET"
}

# Build for a single target
build_target() {
    local target="$1"
    log_info "Building for target: $target"

    setup_rustflags "$target"

    # Build release
    rustup run "$RUST_TOOLCHAIN" cargo build --release --target "$target" -p "$CRATE_NAME"

    # Check output
    local lib_path="target/$target/release/$LIB_NAME"
    if [[ -f "$lib_path" ]]; then
        local size=$(du -h "$lib_path" | cut -f1)
        log_info "Built $lib_path ($size)"
    else
        log_error "Build failed: $lib_path not found"
        exit 1
    fi
}

# Create xcframework from built libraries
create_xcframework() {
    log_info "Creating xcframework..."

    local xcframework_path="$OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"

    # Remove existing xcframework
    rm -rf "$xcframework_path"
    mkdir -p "$OUTPUT_DIR"

    # Normalize each architecture before combining the universal slices.
    for target in "${TARGETS[@]}"; do
        local lib_path="$SCRIPT_DIR/target/$target/release/$LIB_NAME"
        if [[ -f "$lib_path" ]]; then
            # Strip the library for additional size reduction
            log_info "Stripping $target library..."
            strip -x "$lib_path" 2>/dev/null || true

            # Normalize archive metadata so repeated rebuilds are byte-stable.
            local normalized_path="$lib_path.normalized"
            xcrun libtool -static -D -no_warning_for_no_symbols "$lib_path" -o "$normalized_path"
            mv "$normalized_path" "$lib_path"

        else
            log_error "Missing required library: $lib_path"
            exit 1
        fi
    done

    local simulator_dir="$SCRIPT_DIR/target/ios-universal-simulator/release"
    local simulator_lib="$simulator_dir/$LIB_NAME"
    mkdir -p "$simulator_dir"
    xcrun lipo -create \
        "$SCRIPT_DIR/target/aarch64-apple-ios-sim/release/$LIB_NAME" \
        "$SCRIPT_DIR/target/x86_64-apple-ios/release/$LIB_NAME" \
        -output "$simulator_lib"

    # Normalize the universal archive after lipo so repeated rebuilds remain
    # byte-stable just like the single-architecture inputs.
    local normalized_simulator="$simulator_lib.normalized"
    xcrun libtool -static -D -no_warning_for_no_symbols "$simulator_lib" -o "$normalized_simulator"
    mv "$normalized_simulator" "$simulator_lib"

    local macos_dir="$SCRIPT_DIR/target/macos-universal/release"
    local macos_lib="$macos_dir/$LIB_NAME"
    mkdir -p "$macos_dir"
    xcrun lipo -create \
        "$SCRIPT_DIR/target/aarch64-apple-darwin/release/$LIB_NAME" \
        "$SCRIPT_DIR/target/x86_64-apple-darwin/release/$LIB_NAME" \
        -output "$macos_lib"

    local normalized_macos="$macos_lib.normalized"
    xcrun libtool -static -D -no_warning_for_no_symbols "$macos_lib" -o "$normalized_macos"
    mv "$normalized_macos" "$macos_lib"

    local header_dir="$OUTPUT_DIR/include"
    local cmd="xcodebuild -create-xcframework"
    cmd="$cmd -library $SCRIPT_DIR/target/aarch64-apple-ios/release/$LIB_NAME -headers $header_dir"
    cmd="$cmd -library $simulator_lib -headers $header_dir"
    cmd="$cmd -library $macos_lib -headers $header_dir"
    cmd="$cmd -output $xcframework_path"

    log_info "Running: $cmd"
    eval "$cmd"

    if [[ -d "$xcframework_path" ]]; then
        cat > "$xcframework_path/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>libarti_bitchat.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>libarti_bitchat.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
		<dict>
			<key>BinaryPath</key>
			<string>libarti_bitchat.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64_x86_64-simulator</string>
			<key>LibraryPath</key>
			<string>libarti_bitchat.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
			<key>SupportedPlatformVariant</key>
			<string>simulator</string>
		</dict>
		<dict>
			<key>BinaryPath</key>
			<string>libarti_bitchat.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64_x86_64</string>
			<key>LibraryPath</key>
			<string>libarti_bitchat.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF
        local size=$(du -sh "$xcframework_path" | cut -f1)
        log_info "Created $xcframework_path ($size)"
    else
        log_error "Failed to create xcframework"
        exit 1
    fi
}

# Generate C header using cbindgen
generate_header() {
    log_info "Generating C header..."

    local header_dir="$OUTPUT_DIR/include"
    local header_path="$header_dir/arti.h"

    mkdir -p "$header_dir"

    # Create cbindgen.toml if it doesn't exist
    if [[ ! -f "$CRATE_NAME/cbindgen.toml" ]]; then
        cat > "$CRATE_NAME/cbindgen.toml" << 'EOF'
language = "C"
include_guard = "ARTI_H"
no_includes = true
sys_includes = ["stdint.h", "stdbool.h"]

[export]
include = ["arti_start", "arti_stop", "arti_is_running", "arti_bootstrap_progress", "arti_bootstrap_summary", "arti_go_dormant", "arti_wake"]

[fn]
args = "Auto"

[parse]
parse_deps = false
EOF
    fi

    cbindgen --config "$CRATE_NAME/cbindgen.toml" \
             --crate "$CRATE_NAME" \
             --output "$header_path"

    if [[ -f "$header_path" ]]; then
        log_info "Generated $header_path"
        cat "$header_path"
    else
        log_warn "cbindgen did not generate header, creating manually..."
        # Fallback: create header manually
        cat > "$header_path" << 'EOF'
#ifndef ARTI_H
#define ARTI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Start Arti with a SOCKS5 proxy.
 *
 * @param data_dir Path to data directory for Tor state (C string)
 * @param socks_port Port for SOCKS5 proxy (e.g., 39050)
 * @return 0 on success, negative on error
 */
int32_t arti_start(const char *data_dir, uint16_t socks_port);

/**
 * Stop Arti gracefully.
 *
 * @return 0 on success, -1 if not running
 */
int32_t arti_stop(void);

/**
 * Check if Arti is currently running.
 *
 * @return 1 if running, 0 if not running
 */
int32_t arti_is_running(void);

/**
 * Get the current bootstrap progress (0-100).
 *
 * @return Progress percentage
 */
int32_t arti_bootstrap_progress(void);

/**
 * Get the current bootstrap summary string.
 *
 * @param buf Buffer to write the summary into
 * @param len Length of the buffer
 * @return Number of bytes written, -1 on error
 */
int32_t arti_bootstrap_summary(char *buf, int32_t len);

/**
 * Signal Arti to go dormant (reduce resource usage).
 *
 * @return 0 on success, -1 if not running
 */
int32_t arti_go_dormant(void);

/**
 * Signal Arti to wake from dormant mode.
 *
 * @return 0 on success, -1 if not running
 */
int32_t arti_wake(void);

#ifdef __cplusplus
}
#endif

#endif /* ARTI_H */
EOF
        log_info "Created manual header at $header_path"
    fi
}

# Print size report
print_size_report() {
    log_info "=== Size Report ==="
    for target in "${TARGETS[@]}"; do
        local lib_path="$SCRIPT_DIR/target/$target/release/$LIB_NAME"
        if [[ -f "$lib_path" ]]; then
            local size=$(du -h "$lib_path" | cut -f1)
            echo "  $target: $size"
        fi
    done

    local xcframework_path="$OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"
    if [[ -d "$xcframework_path" ]]; then
        local total_size=$(du -sh "$xcframework_path" | cut -f1)
        echo "  xcframework total: $total_size"
    fi
}

# Main
main() {
    log_info "Building arti-bitchat for iOS/macOS"
    log_info "=================================="

    check_prerequisites
    generate_header

    for target in "${TARGETS[@]}"; do
        build_target "$target"
    done

    create_xcframework
    print_size_report

    log_info "Build complete!"
    log_info "xcframework: $OUTPUT_DIR/$FRAMEWORK_NAME.xcframework"
}

# Run
main "$@"
