# NdrFfi

Generated Swift bindings and an ignored dynamic Apple XCFramework for the
single-device pairwise UniFFI crate in `nostr-double-ratchet`. The binary does
not include AppKeys, linked-device, sibling-sync, or group runtime code.

## Source Of Truth

The generated files in this package come from the upstream
`nostr-double-ratchet` checkout, specifically the Rust `ndr-pairwise-ffi`
crate and its UniFFI-generated Swift bindings. The built library keeps the
module name `ndr_ffi`.

The exact upstream revision is pinned by the
`vendor/nostr-double-ratchet` submodule and repeated in `SOURCE_REVISION`.
Native libraries are deliberately not tracked in this repository. Apple
deployment targets are fixed in the build script, so ambient shell settings
cannot change the output.

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
git submodule update --init --checkout vendor/nostr-double-ratchet
./localPackages/NdrFfi/build-apple.sh
```

Or:

```bash
cd localPackages/NdrFfi
NOSTR_DOUBLE_RATCHET_DIR=/path/to/nostr-double-ratchet ./build-apple.sh
```

The script:

- builds the upstream `ndr-pairwise-ffi` crate
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
