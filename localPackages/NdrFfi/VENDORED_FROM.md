# Vendored Provenance

Current vendored `NdrFfi` artifacts in this package correspond to:

- Upstream repository: `git@github.com:mmalmi/nostr-double-ratchet.git`
- Upstream crate: `rust/crates/ndr-ffi`
- Upstream version: `v0.0.100`
- Upstream source revision: `v0.0.100-1-gb8f0cc2`
- Upstream commit: `b8f0cc2ef9dd651d5eb4a6d9e1236532c9b414a4`
- Rebuild script: `build-apple.sh`
- Static archive post-processing: `xcrun strip -S` to remove DWARF debug info while preserving link symbols
- Rust toolchain used for the vendored refresh: `rustc 1.94.1 (e408947bf 2026-03-25)`

Vendored outputs updated from that source:

- `Sources/NdrFfi/NdrFfi.swift`
- `Frameworks/NdrFfi.xcframework` (`macos-arm64_x86_64`, `ios-arm64`, `ios-arm64_x86_64-simulator`)

Recorded on `2026-04-26T12:14:44Z`.
