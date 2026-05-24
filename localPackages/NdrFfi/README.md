# NdrFfi

Vendored Swift bindings and Apple XCFramework for the upstream
`nostr-double-ratchet` `ndr-ffi` crate.

## Source Of Truth

The generated files in this package come from the upstream
`nostr-double-ratchet` checkout, specifically the Rust `ndr-ffi` crate and its
UniFFI-generated Swift bindings.

The exact upstream revision used for the currently vendored artifacts is
recorded in `VENDORED_FROM.md`.

Default expected upstream checkout:

```bash
$HOME/src/nostr-double-ratchet
```

You can also point the build at a different checkout by passing a path or by
setting `NDR_SOURCE_DIR`.

## Rebuild From Source

Prerequisites:

- Xcode and command line tools
- Rust toolchain with cargo
- Rust targets:
  - `aarch64-apple-darwin`
  - `aarch64-apple-ios`
  - `aarch64-apple-ios-sim`

Example:

```bash
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
cd localPackages/NdrFfi
./build-apple.sh ~/src/nostr-double-ratchet
```

Or:

```bash
cd localPackages/NdrFfi
NDR_SOURCE_DIR=/path/to/nostr-double-ratchet ./build-apple.sh
```

The script:

- builds the upstream `ndr-ffi` crate
- regenerates `Sources/NdrFfi/NdrFfi.swift` via UniFFI
- rebuilds the Apple XCFramework at `Frameworks/NdrFfi.xcframework`
- bakes in the current Apple deployment targets used by `bitchat`

## Outputs Updated By The Script

- `Sources/NdrFfi/NdrFfi.swift`
- `Frameworks/NdrFfi.xcframework`

## Recommended Verification

```bash
swift test --package-path localPackages/NdrFfi
swift test --filter NdrOutOfBandTransportTests
swift test --filter NostrTransportTests
```
