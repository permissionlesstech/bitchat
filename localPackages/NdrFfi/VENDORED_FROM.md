# Source-Build Provenance

`NdrFfi` is built from source using:

- Upstream repository: `https://github.com/irislib/nostr-double-ratchet`
- Upstream base: `master` at `c93f76a2b947f4288d2c7bcbecabe70ce197da5f`
- Pinned source commit: `0fe8caf2d4e24e2030ffae195597a2764613a659`
- Crate: `ndr-pairwise-ffi` (library `ndr_ffi`)
- Runtime: durable single-identity pairwise sessions only; no AppKeys,
  linked-device, sibling-sync, or group runtime
- Rebuild script: `build-apple.sh`
- Rust compiler: `1.95.0` (pinned by `RUST_TOOLCHAIN`)
- Release Rust flags: `-C panic=abort -C strip=debuginfo`
- Packaging: embedded dynamic XCFramework, isolating its Rust runtime from
  Arti's independent static Rust runtime
- Cargo builds use `--locked`.
- The pinned source commit provides durable pairwise state/action ordering,
  targeted peer retirement, and portable exclusive storage locking.

Generated/build outputs:

- `Sources/NdrFfi/NdrFfi.swift` is tracked and checked for regeneration drift.
- `Frameworks/NdrFfi.xcframework` is rebuilt locally/CI and ignored.

Updated on `2026-07-27`.
