# Tor Binary Provenance

This repository vendors two source-built binary dependencies under
`localPackages/Arti/Frameworks`:

- `arti.xcframework` provides the in-process Tor client.
- `IPtProxy.xcframework` provides obfs4 and Snowflake on physical iOS devices.

SwiftPM links them through `localPackages/Arti/Package.swift`. Treat changes to
either artifact like dependency updates. Review the source pins, lockfiles,
build scripts, generated headers, licenses, and hashes together.

## Source inputs

Arti inputs:

- Rust workspace: `localPackages/Arti/Cargo.toml`
- Crate: `localPackages/Arti/arti-bitchat`
- Dependency lockfile: `localPackages/Arti/Cargo.lock`
- Physical-iOS build script: `localPackages/Arti/build-arti-ios-device.sh`
- Full legacy build script: `localPackages/Arti/build-ios.sh`
- Exported C header: `localPackages/Arti/Frameworks/include/arti.h`

The crate uses Arti 0.38 with `pt-client`, Tokio, and Rustls. It configures
IPtProxy as an unmanaged pluggable transport and does not launch a transport
executable. iOS runs IPtProxy in-process, and Arti connects directly to its
loopback SOCKS listener with the original bridge identity and parameters. A
byte-transparent loopback monitor reports whether Arti opened the transport and
whether the handoff reached IPtProxy without reading or changing SOCKS traffic.

IPtProxy inputs:

- Release/tag: `5.5.1`
- Commit: `d4878bf7729902c1fb5e319d3b043c81388e0720`
- DNSTT submodule commit: `f1b9b97a269f83bad41d2ceef291b4d2c161cd11`
- Go module and checksums: `IPtProxy.go/go.mod` and `IPtProxy.go/go.sum` at that commit
- Physical-iOS build script: `localPackages/Arti/build-iptproxy-ios-device.sh`
- License: `localPackages/Arti/IPTPROXY-LICENSE.txt`

That IPtProxy source pins:

- Lyrebird commit `fc105a03c0e0` and reports Lyrebird `0.8.1`
- Snowflake `2.14.1`
- gomobile `v0.0.0-20260611195102-4dd8f1dbf5d2`

Snowflake's broker, front-domain, ICE, and bridge defaults in
`Sources/TorTransport.swift` were checked against the Tor Project Snowflake
repository at commit `cd33fc638ac03343197eb944a611df29f554be88`.

## Platform scope

The pluggable-transport artifact contains two library identifiers: `ios-arm64`
and `ios-arm64_x86_64-simulator`. There is no macOS or Mac Catalyst IPtProxy
slice. The simulator slice exists so the SwiftPM `Tor` target links on the
simulator, which is where CI builds the app and runs the Swift test suite.
Censorship-resistance acceptance still happens only on a physical device.

Both iOS slices of the Arti xcframework, `ios-arm64` and
`ios-arm64_x86_64-simulator`, were refreshed from the same crate and export the
transport FFI. They must stay in step: `TorManager` declares
`arti_start_with_config` and `arti_validate_transport_config` under
`#if os(iOS)`, which covers the simulator, so an iOS slice that lacks those
symbols fails the link rather than degrading at runtime.

The macOS slice is retained unchanged for direct Arti compatibility. It does not
export the transport FFI and cannot link IPtProxy features. Nothing references
them there, because the Swift code compiles those calls only on iOS and the app
shows transport controls only on iOS.

## Regenerating the iOS artifacts

Use the exact toolchains below. From the repository root:

```sh
rustup toolchain install 1.96.0
rustup run 1.96.0 cargo install cbindgen --version 0.29.4 --locked
localPackages/Arti/build-arti-ios-device.sh

git clone --recurse-submodules --branch 5.5.1 \
  https://github.com/tladesignz/IPtProxy.git <IPTPROXY_CHECKOUT>
localPackages/Arti/build-iptproxy-ios-device.sh <IPTPROXY_CHECKOUT>
```

The IPtProxy script refuses any checkout or DNSTT submodule that does not match
the recorded commits. It also requires Go `1.25.10` and the pinned gomobile
revision. `gomobile bind -target=ios` builds `ios/arm64`,
`iossimulator/arm64`, and `iossimulator/amd64`; the installed xcframework is
rebuilt from IPtProxy's `ios-arm64` and `ios-arm64_x86_64-simulator`
frameworks and drops any other slice. The script also normalizes each
framework's bundle version to `5.5.1` and deployment metadata to iOS 16.0
because current gomobile uses build-time values and can misread newer Xcode SDK
version encodings.

The Arti script requires Rust `1.96.0` and cbindgen `0.29.4`, installs its own
targets, and builds `aarch64-apple-ios` plus the `aarch64-apple-ios-sim` and
`x86_64-apple-ios` pair it lipos into the simulator slice. Every target uses the
same size-oriented release flags, archive metadata is normalized with
`xcrun libtool -static -D`, and the script replaces only the two iOS libraries
and the generated header. The macOS slice is left alone.

## Audited rebuild

The July 2026 artifacts were built from source with:

```text
rustc 1.96.0 (ac68faa20 2026-05-25)
cargo 1.96.0 (30a34c682 2026-05-25)
cbindgen 0.29.4
Go 1.25.10 darwin/arm64
gomobile v0.0.0-20260611195102-4dd8f1dbf5d2
Xcode 26.6
Build version 17F113
```

The critical packaging check is independent of file names: `lipo -info` must
report arm64 for both physical-iOS binaries and `arm64 x86_64` for the IPtProxy
simulator binary, and IPtProxy's xcframework `Info.plist` must contain only
`ios-arm64` and `ios-arm64_x86_64-simulator`, both with
`SupportedPlatform = ios`.

## Current artifact hashes

Verify the Arti artifact:

```sh
find localPackages/Arti/Frameworks/arti.xcframework -maxdepth 3 -type f \
  -exec shasum -a 256 {} + | sort -k2
```

```text
cac99db408280bbef15cae8ce64c8ccdbf2e8863c205168d59f83fe8ab680f94  localPackages/Arti/Frameworks/arti.xcframework/Info.plist
fa289d4f1c9a0a0665cfd4412c9713b27774d86b8391234934829caa2b183766  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64/Headers/arti.h
6a7ad09cb8123ede7b18b1420e6dd5411d899a86ed5e138023364634253dd5d0  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64/libarti_bitchat.a
fa289d4f1c9a0a0665cfd4412c9713b27774d86b8391234934829caa2b183766  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64_x86_64-simulator/Headers/arti.h
f344960953436b5553f5d568df1b5c2ef950e9f56049467c36397cfff2ee125c  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64_x86_64-simulator/libarti_bitchat.a
551655904834748c9dc36034fdbc9465e7533aef1e4a6514b4fcc75875b93058  localPackages/Arti/Frameworks/arti.xcframework/macos-arm64_x86_64/Headers/arti.h
7c9afe98227f1767567ddcd4e35d9dfffe70309c302c4dbc9a6c9d6aeefab007  localPackages/Arti/Frameworks/arti.xcframework/macos-arm64_x86_64/libarti_bitchat.a
```

Verify IPtProxy and its license:

```sh
find localPackages/Arti/Frameworks/IPtProxy.xcframework -maxdepth 6 -type f \
  -exec shasum -a 256 {} + | sort -k2
shasum -a 256 localPackages/Arti/IPTPROXY-LICENSE.txt
```

```text
1877f83f6109128173ad71aa232792b5b79fae059b5db0934b8609326647e35c  localPackages/Arti/Frameworks/IPtProxy.xcframework/Info.plist
c6a68ea0f813315dae83ba6db40d9c8ad586a9f1491cd7e323132855fcdf444c  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64_x86_64-simulator/IPtProxy.framework/Headers/IPtProxy.h
1e2b1d95b138b5033dde8b8535cf4c832b3de3ca55b1921088be6a4ba13f174d  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64_x86_64-simulator/IPtProxy.framework/Headers/IPtProxy.objc.h
d76b969941e61d61551ae1e6b7ddc674ac898d422f28cb5dbf8d640ba2ae8df6  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64_x86_64-simulator/IPtProxy.framework/Headers/ref.h
61b1a0cd75801d2d8d1d82ef2accda4477966c691795473d696e45de05fcbc7b  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64_x86_64-simulator/IPtProxy.framework/Headers/Universe.objc.h
6876e20827763aaf32f1842a531fcc9476284f879b555cca961b4eb7bd127718  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64_x86_64-simulator/IPtProxy.framework/Info.plist
515e7945d979a0b5a14848674a13295af44c1cd49c91cb7c009c5e08b6d7922c  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64_x86_64-simulator/IPtProxy.framework/IPtProxy
c0c22353bf8b5c33a49d002c12ab0d39bd8daad8bc957c2a90435f9ebb630613  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64_x86_64-simulator/IPtProxy.framework/Modules/module.modulemap
c6a68ea0f813315dae83ba6db40d9c8ad586a9f1491cd7e323132855fcdf444c  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64/IPtProxy.framework/Headers/IPtProxy.h
1e2b1d95b138b5033dde8b8535cf4c832b3de3ca55b1921088be6a4ba13f174d  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64/IPtProxy.framework/Headers/IPtProxy.objc.h
d76b969941e61d61551ae1e6b7ddc674ac898d422f28cb5dbf8d640ba2ae8df6  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64/IPtProxy.framework/Headers/ref.h
61b1a0cd75801d2d8d1d82ef2accda4477966c691795473d696e45de05fcbc7b  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64/IPtProxy.framework/Headers/Universe.objc.h
6876e20827763aaf32f1842a531fcc9476284f879b555cca961b4eb7bd127718  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64/IPtProxy.framework/Info.plist
8e228f15a860efb87cc20228c52e8345df37e22a600b62c96bd7edf60db3d07f  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64/IPtProxy.framework/IPtProxy
c0c22353bf8b5c33a49d002c12ab0d39bd8daad8bc957c2a90435f9ebb630613  localPackages/Arti/Frameworks/IPtProxy.xcframework/ios-arm64/IPtProxy.framework/Modules/module.modulemap
6bf5006e66e32239eb1ebbf2ac187936247f7119476575641111ac57adbe30ac  localPackages/Arti/IPTPROXY-LICENSE.txt
```

## Review checklist

- Record the Rust, Go, gomobile, and Xcode versions when refreshing a binary.
- Review `Cargo.lock`, IPtProxy's `go.mod` and `go.sum`, exported headers, and all build-script changes.
- Confirm IPtProxy contains only the `ios-arm64` and `ios-arm64_x86_64-simulator` slices.
- Run the Rust transport-configuration tests and physical-iOS package compile.
- Perform real-device direct, obfs4, Snowflake, blocked-route fallback, foreground recovery, and panic-wipe acceptance tests.
- Do not accept a binary-only update without matching source, lockfile, script, license, or provenance evidence.
