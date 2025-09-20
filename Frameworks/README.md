Tor binary bundle (tor-nolzma.xcframework)

This folder contains third-party frameworks used by the app.

Notes
- tor-nolzma.xcframework currently does not include an iOS Simulator slice.
- To build and run on iOS Simulator, the iOS target has been configured to avoid linking this framework.
- Device builds (iphoneos) can still link Tor when a device slice is available.

If you add a simulator slice later
- Re-add tor-nolzma.xcframework to the iOS target’s Link Binary With Libraries step.
- Ensure the xcframework contains: ios-arm64 and ios-arm64_x86_64-simulator (or equivalent) variants.

Troubleshooting
- If the build complains about missing tor-nolzma on Simulator: either remove the link phase for Simulator, or provide a simulator-compatible xcframework slice.
