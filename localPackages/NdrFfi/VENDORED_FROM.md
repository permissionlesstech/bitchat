# Vendored Provenance

Current vendored `NdrFfi` artifacts in this package correspond to:

- Upstream repository: `git@github.com:mmalmi/nostr-double-ratchet.git`
- Upstream crate: `rust/crates/ndr-ffi`
- Upstream version: `v0.0.97`
- Upstream source revision: `v0.0.97-3-g5fa8dbb`
- Upstream commit: `5fa8dbb7d4a2ea21e448e5fa220f655030de12f2`
- Rebuild script: `build-apple.sh`
- Static archive post-processing: `xcrun strip -S` to remove DWARF debug info while preserving link symbols
- Rust toolchain used for the vendored refresh: `rustc 1.94.1 (e408947bf 2026-03-25)`

Vendored outputs updated from that source:

- `Sources/NdrFfi/NdrFfi.swift`
- `Frameworks/NdrFfi.xcframework` (`macos-arm64_x86_64`, `ios-arm64`, `ios-arm64_x86_64-simulator`)

Recorded on `2026-04-25T09:00:04Z`.
