# Source-Build Provenance

`NdrFfi` is built from source using:

- Upstream repository: `https://github.com/irislib/nostr-double-ratchet`
- Upstream base: `master` at `6177add831597f2e66f34ade3717c6201852cbdf`
- Pinned source commit: `6177add831597f2e66f34ade3717c6201852cbdf`
- Pairwise/FFI Rust release: `0.0.168`; core NDR: `0.0.170`;
  locked `nostr` dependency: `0.44.8`
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
- This update includes invite identity binding and the NIP-44 resource
  exhaustion fix from the locked `nostr` dependency. Authenticated invite-response
  bindings stay pinned while their sessions live, even after the bounded
  general replay window rotates. The wire format and FFI interface are unchanged.

Generated/build outputs:

- `Sources/NdrFfi/NdrFfi.swift` is generated locally and ignored; its
  normalized SHA-256 must match `SWIFT_BINDINGS_SHA256` before installation.
- `Frameworks/NdrFfi.xcframework` is rebuilt locally/CI and ignored.

Updated on `2026-10-20`.
