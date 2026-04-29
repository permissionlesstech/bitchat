# Vendored Provenance

Current vendored `NdrFfi` artifacts in this package correspond to:

- Upstream repository: `git@github.com:mmalmi/nostr-double-ratchet.git`
- Upstream crate: `rust/crates/ndr-ffi`
- Upstream version: `v0.0.124`
- Upstream source revision: `v0.0.100-37-g3555991`
- Upstream commit: `35559918bda142793b8ec9de0fd6a5deb460da24`
- Rebuild script: `build-apple.sh`
- Release Rust flags: `-C panic=abort` to avoid linking a second Rust unwind runtime beside other Rust static archives in the app.
- Static archive post-processing: `xcrun strip -S` to remove DWARF debug info while preserving link symbols
- Rust toolchain used for the vendored refresh: `rustc 1.94.1 (e408947bf 2026-03-25)`

Vendored outputs updated from that source:

- `Sources/NdrFfi/NdrFfi.swift`
- `Frameworks/NdrFfi.xcframework` (`macos-arm64_x86_64`, `ios-arm64`, `ios-arm64_x86_64-simulator`)

Recorded on `2026-04-29T23:10:01Z`.
