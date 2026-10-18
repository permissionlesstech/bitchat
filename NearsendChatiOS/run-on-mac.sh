#!/bin/bash
# Builds Nearsend Chat, runs it in an iPhone simulator, and opens the project in Xcode.
set -e
cd "$(dirname "$0")"
SIM="${1:-iPhone 15 Pro}"
xcodebuild -project NearsendChat.xcodeproj -scheme NearsendChat \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build | tail -5
UDID=$(xcrun simctl list devices available | grep "$SIM (" | head -1 | grep -oE '[0-9A-F-]{36}')
[ -n "$UDID" ] || { echo "No simulator named '$SIM'. Run: xcrun simctl list devices available"; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator
xcrun simctl install "$UDID" build/Build/Products/Debug-iphonesimulator/NearsendChat.app
xcrun simctl launch "$UDID" app.nearsend.chat
open NearsendChat.xcodeproj
