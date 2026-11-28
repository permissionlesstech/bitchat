# Arti Binary Provenance

This repo vendors a prebuilt Arti static-library xcframework at:

`localPackages/Arti/Frameworks/arti.xcframework`

SwiftPM links it through `localPackages/Arti/Package.swift` as the binary target named `arti`. Treat changes to this artifact like dependency updates: review the Rust sources, lockfile, build script, produced headers, and artifact hashes together.

## Source Inputs

- Rust workspace: `localPackages/Arti/Cargo.toml`
- Crate: `localPackages/Arti/arti-bitchat`
- Dependency lockfile: `localPackages/Arti/Cargo.lock`
- Build script: `localPackages/Arti/build-ios.sh`
- Exported C header: `localPackages/Arti/Frameworks/include/arti.h`

The crate declares `rust-version = "1.90"` and uses `arti-client` / `tor-rtcompat` `0.38` with minimal Tokio/Rustls features. The current lockfile requires Rust 1.90 or newer. The build script currently targets:

- `aarch64-apple-ios`
- `aarch64-apple-ios-sim`
- `x86_64-apple-ios`
- `aarch64-apple-darwin`
- `x86_64-apple-darwin`

It builds release static libraries with size-oriented flags (`opt-level=z`, fat LTO, one codegen unit, `-Z build-std=std,panic_abort`, `-Z build-std-features=optimize_for_size`, `-C panic=immediate-abort`, `-Z location-detail=none`, stripped symbols, and `tracing`/`log` compile-time `release_max_level_off`), while keeping `arti-client` (`rustls` + `tokio` `rt-multi-thread`) runtime behavior unchanged. It normalizes static-archive metadata with `xcrun libtool -static -D`, then packages them with `xcodebuild -create-xcframework`.

## Regenerating The Artifact

From the repo root:

```sh
cd localPackages/Arti
rustup toolchain install nightly-2026-11-28
rustup component add --toolchain nightly-2026-11-28 rust-src
rustup target add --toolchain nightly-2026-11-28 aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin
rustup run nightly-2026-11-28 cargo install cbindgen --version 0.29.4 --locked
./build-ios.sh
```

`build-ios.sh` defaults to the audited `nightly-2026-11-28` toolchain and refuses a rustc
version other than `1.102.0-nightly`; it likewise requires cbindgen `0.29.4`. Set
`RUST_TOOLCHAIN`, `RUSTC_VERSION`, or `CBINDGEN_VERSION` explicitly only when
intentionally updating the binary provenance and hashes below.

After rebuilding, verify that:

- `Cargo.lock` changes are intentional and reviewed.
- `Frameworks/include/arti.h` still matches the exported FFI functions used by `TorManager`.
- `Frameworks/arti.xcframework` contains iOS device arm64, universal iOS simulator arm64+x86_64, and universal macOS arm64+x86_64 slices.
- The main app still passes iOS tests and the macOS build.

## Audited Rebuild

The November 2026 artifact below was rebuilt from source on this host with:

```text
rustc 1.102.0-nightly (c82ce1563 2026-11-27)
cargo 1.102.0-nightly (ae8f06eb4 2026-11-21)
rustup 1.29.3 (2026-11-02)
cbindgen 0.29.4
Xcode 27.2
Build version 27B52
```

Rust 1.86.0 was also checked during the audit and no longer builds this lockfile because `typed-index-collections@3.4.0` requires Rust 1.90.0 or newer.

The build script normalizes static-archive metadata and writes a stable xcframework `Info.plist`.

## Current Artifact Hashes

Run this from the repo root to verify the checked-in artifact:

```sh
find localPackages/Arti/Frameworks/arti.xcframework -type f -print0 | sort -z | xargs -0 shasum -a 256
```

Current hashes:

```text
cac99db408280bbef15cae8ce64c8ccdbf2e8863c205168d59f83fe8ab680f94  localPackages/Arti/Frameworks/arti.xcframework/Info.plist
551655904834748c9dc36034fdbc9465e7533aef1e4a6514b4fcc75875b93058  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64/Headers/arti.h
9f8bda29077abdcfb1ad1cd59dd112119057256c44542fecfe5e47d941760d75  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64/libarti_bitchat.a
551655904834748c9dc36034fdbc9465e7533aef1e4a6514b4fcc75875b93058  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64_x86_64-simulator/Headers/arti.h
6765588fa9cc6601a0467cc7af07f51b302fe29828029cb68b7d294e61c0277b  localPackages/Arti/Frameworks/arti.xcframework/ios-arm64_x86_64-simulator/libarti_bitchat.a
551655904834748c9dc36034fdbc9465e7533aef1e4a6514b4fcc75875b93058  localPackages/Arti/Frameworks/arti.xcframework/macos-arm64_x86_64/Headers/arti.h
f76134e09706af4bd9535676b0a53eb898b6ec7a1750165acee9a754d499412e  localPackages/Arti/Frameworks/arti.xcframework/macos-arm64_x86_64/libarti_bitchat.a
```

## Review Checklist

- Record `rustc --version`, `cargo --version`, `cbindgen --version`, and `xcodebuild -version` in the PR when refreshing the binary.
- Include the hash output above after any binary change.
- If a rebuild changes only xcframework/library bytes, record the new hashes and app validation evidence in the PR.
- Keep `target/`, `.build/`, and `.swiftpm/` out of source control.
- Do not accept an xcframework-only update without matching source, lockfile, or build-script evidence explaining where it came from.
