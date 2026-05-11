# Vendored Provenance

Current vendored `NdrFfi` artifacts in this package correspond to:

- Upstream repository: `git@github.com:mmalmi/nostr-double-ratchet.git`
- Upstream crate: `rust/crates/ndr-ffi`
- Upstream version: `v0.0.135`
- Upstream source revision: `v0.0.100-58-g8d324ed`
- Upstream commit: `8d324edac835fd3b69471340af8bd05525310dfe`
- Rebuild script: `build-apple.sh`
- Release Rust flags: `-C panic=abort` to avoid linking a second Rust unwind runtime beside other Rust static archives in the app.
- Static archive post-processing: `xcrun strip -S` to remove DWARF debug info while preserving link symbols
- Rust toolchain used for the vendored refresh: `rustc 1.94.1 (e408947bf 2026-03-25)`

Vendored outputs updated from that source:

- `Sources/NdrFfi/NdrFfi.swift`
- `Frameworks/NdrFfi.xcframework` (`macos-arm64_x86_64`, `ios-arm64`, `ios-arm64_x86_64-simulator`)

Recorded on `2026-05-02T17:48:11Z`.
