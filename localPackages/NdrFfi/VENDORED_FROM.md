# Vendored Provenance

Current vendored `NdrFfi` artifacts in this package correspond to:

- Upstream repository: `htree://npub1xdhnr9mrv47kkrn95k6cwecearydeh8e895990n3acntwvmgk2dsdeeycm/iris-chat-rs`
- Upstream crate: `protocol-ffi` (`iris-chat-protocol-ffi`, library `ndr_ffi`)
- Upstream version: `0.1.0`
- Upstream source revision: `423d88cf Retry queued protocol sends from FFI inbound events`
- Upstream commit: `423d88cff10f9ebaab3c8e327ebcb916abb3f029`
- Rebuild script: `build-apple.sh`
- Release Rust flags: `-C panic=abort` to avoid linking a second Rust unwind runtime beside other Rust static archives in the app.
- Static archive post-processing: `xcrun strip -S` to remove DWARF debug info while preserving link symbols
- Rust toolchain used for the vendored refresh: `rustc 1.95.0 (59807616e 2026-04-14)`

Vendored outputs updated from that source:

- `Sources/NdrFfi/NdrFfi.swift`
- `Frameworks/NdrFfi.xcframework` (`macos-arm64_x86_64`, `ios-arm64`, `ios-arm64_x86_64-simulator`)

Recorded on `2026-06-04T00:27:00Z`.
