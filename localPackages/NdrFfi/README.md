# NdrFfi

Vendored Swift bindings and Apple XCFramework for the upstream
`iris-chat-rs` `protocol-ffi` crate.

## Source Of Truth

The generated files in this package come from the upstream
`iris-chat-rs` checkout, specifically the Rust `protocol-ffi` crate and its
UniFFI-generated Swift bindings. The built library keeps the compatibility
name `ndr_ffi`.

The exact upstream revision used for the currently vendored artifacts is
recorded in `VENDORED_FROM.md`.

Default expected upstream checkout:

```bash
$HOME/src/iris-chat-rs
```

You can also point the build at a different checkout by passing a path or by
setting `ICP_SOURCE_DIR`.

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
./build-apple.sh ~/src/iris-chat-rs
```

Or:

```bash
cd localPackages/NdrFfi
ICP_SOURCE_DIR=/path/to/iris-chat-rs ./build-apple.sh
```

The script:

- builds the upstream `protocol-ffi` crate
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
