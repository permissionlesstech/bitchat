# Source-Build Provenance

`NdrFfi` is built from source using:

- Upstream repository: `https://github.com/irislib/iris-chat-rs`
- Upstream crate: `protocol-ffi` (`iris-chat-protocol-ffi`, library `ndr_ffi`)
- Upstream base: `main` at `33f7732bbd300ed62fdf5bcf9da0a176efa7ff8c`
- Pinned source commit: `095e70489345df4d92dded686902f3dccb54cc45`
- Source branch: `codex/bitchat-ffi-hardening`
- Latest double-ratchet crates: `nostr-double-ratchet` `0.0.164` and
  `nostr-double-ratchet-pairwise-codec` `0.0.164`, checksum-pinned by
  `protocol-ffi/Cargo.lock`
- Rebuild script: `build-apple.sh`
- Rust compiler: `1.95.0` (pinned by `RUST_TOOLCHAIN`)
- Release Rust flags: `-C panic=abort -C strip=debuginfo`
- Packaging: embedded dynamic XCFramework, isolating its Rust runtime from
  Arti's independent static Rust runtime
- Cargo builds use `--locked`.
- The pinned source commit transactionally binds invite responses to an
  expected account owner and preserves account/device attribution in UniFFI.

Generated/build outputs:

- `Sources/NdrFfi/NdrFfi.swift` is tracked and checked for regeneration drift.
- `Frameworks/NdrFfi.xcframework` is rebuilt locally/CI and ignored.

Updated on `2026-07-27`.
