#!/bin/bash
#
# Rebuild the pinned IPtProxy dependency for iOS and install its iphoneos and
# iphonesimulator slices. No macOS or Mac Catalyst target is requested or
# installed. The simulator slice exists so CI can build and run the test suite;
# only the device slice carries transports the app uses in the field.
#
set -euo pipefail

IPTPROXY_VERSION="5.5.1"
IPTPROXY_COMMIT="d4878bf7729902c1fb5e319d3b043c81388e0720"
DNSTT_COMMIT="f1b9b97a269f83bad41d2ceef291b4d2c161cd11"
GOMOBILE_VERSION="v0.0.0-20260611195102-4dd8f1dbf5d2"
GO_VERSION="go1.25.10"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${1:-}"

if [[ -z "$SOURCE_DIR" ]]; then
    echo "usage: $0 <IPtProxy-${IPTPROXY_VERSION}-checkout>"
    exit 2
fi

if [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$IPTPROXY_COMMIT" ]]; then
    echo "IPtProxy checkout is not pinned commit $IPTPROXY_COMMIT"
    exit 3
fi
if [[ "$(git -C "$SOURCE_DIR/dnstt" rev-parse HEAD)" != "$DNSTT_COMMIT" ]]; then
    echo "DNSTT submodule is not pinned commit $DNSTT_COMMIT"
    exit 4
fi
if [[ "$(go version | awk '{print $3}')" != "$GO_VERSION" ]]; then
    echo "expected $GO_VERSION"
    exit 5
fi

BUILD_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

cp -a "$SOURCE_DIR/IPtProxy.go" "$BUILD_ROOT/"
cp -a "$SOURCE_DIR/dnstt" "$BUILD_ROOT/"

# gomobile derives the framework name, module name, and umbrella header from
# the -o basename, and Swift imports it as IPtProxy. Bind into its own
# directory so the staged output keeps that exact name.
BIND_ROOT="$BUILD_ROOT/bind"
mkdir -p "$BIND_ROOT"

pushd "$BUILD_ROOT/IPtProxy.go" >/dev/null
go run "golang.org/x/mobile/cmd/gomobile@${GOMOBILE_VERSION}" bind \
    -target=ios \
    -ldflags="-s -w -checklinkname=0" \
    -o "$BIND_ROOT/IPtProxy.xcframework" \
    -iosversion=16.0 \
    -tags=netcgo \
    -trimpath
popd >/dev/null

# -target=ios builds ios/arm64, iossimulator/arm64, and iossimulator/amd64.
# Install those two slices and nothing else.
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcodebuild -create-xcframework \
    -framework "$BIND_ROOT/IPtProxy.xcframework/ios-arm64/IPtProxy.framework" \
    -framework "$BIND_ROOT/IPtProxy.xcframework/ios-arm64_x86_64-simulator/IPtProxy.framework" \
    -output "$BUILD_ROOT/IPtProxy.xcframework"

# gomobile can derive an invalid deployment value from newer Xcode SDK version
# encodings. The static framework is built with -iosversion above; normalize
# its metadata to that same supported application target.
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    /usr/libexec/PlistBuddy \
        -c "Set :MinimumOSVersion 16.0" \
        -c "Set :CFBundleShortVersionString $IPTPROXY_VERSION" \
        -c "Set :CFBundleVersion $IPTPROXY_VERSION" \
        "$BUILD_ROOT/IPtProxy.xcframework/$slice/IPtProxy.framework/Info.plist"
done

DESTINATION="$SCRIPT_DIR/Frameworks/IPtProxy.xcframework"
rm -rf "$DESTINATION"
cp -R "$BUILD_ROOT/IPtProxy.xcframework" "$DESTINATION"

echo "installed iOS device and simulator IPtProxy $IPTPROXY_VERSION"
