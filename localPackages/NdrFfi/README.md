# NdrFfi

Generated Swift bindings and an ignored dynamic Apple XCFramework for the upstream
`iris-chat-rs` `protocol-ffi` crate. Its locked dependency graph uses
`nostr-double-ratchet` and `nostr-double-ratchet-pairwise-codec` `0.0.164`.

## Source Of Truth

The generated files in this package come from the upstream
`iris-chat-rs` checkout, specifically the Rust `protocol-ffi` crate and its
UniFFI-generated Swift bindings. The built library keeps the compatibility
name `ndr_ffi`.

The exact upstream revision is pinned by the `vendor/iris-chat-rs` submodule
and repeated in `SOURCE_REVISION`. Native libraries are deliberately not
tracked in this repository. Apple deployment targets are fixed in the build
script, so ambient shell settings cannot change the output.

## Rebuild From Source

Prerequisites:

- Xcode and command line tools
- Rust toolchain version from `RUST_TOOLCHAIN`, with cargo
- Rust targets:
  - `aarch64-apple-darwin`
  - `x86_64-apple-darwin`
  - `aarch64-apple-ios`
  - `aarch64-apple-ios-sim`
  - `x86_64-apple-ios`

Example:

```bash
rustup target add \
  aarch64-apple-darwin \
  x86_64-apple-darwin \
  aarch64-apple-ios \
  aarch64-apple-ios-sim \
  x86_64-apple-ios
git submodule update --init --checkout vendor/iris-chat-rs
./localPackages/NdrFfi/build-apple.sh
```

Or:

```bash
cd localPackages/NdrFfi
IRIS_CHAT_RS_DIR=/path/to/iris-chat-rs ./build-apple.sh
```

The script:

- builds the upstream `protocol-ffi` crate
- reuses an ignored Cargo target cache under `.cache/ndr-ffi/apple`
- regenerates `Sources/NdrFfi/NdrFfi.swift` via UniFFI
- rebuilds the ignored dynamic Apple XCFramework at `Frameworks/NdrFfi.xcframework`
- bakes in the current Apple deployment targets used by `bitchat`

The NDR runtime is an embedded dynamic framework because the shipping app
already links Arti as a Rust static library. Rust static libraries each bundle
their own standard library and are not safe to combine independently in one
foreign-linker process.

## Outputs Updated By The Script

- `Sources/NdrFfi/NdrFfi.swift`
- `Frameworks/NdrFfi.xcframework` (local build output, ignored)

## Recommended Verification

```bash
swift test --package-path localPackages/NdrFfi
swift test --filter NdrOutOfBandTransportTests
swift test --filter NostrTransportTests
```
