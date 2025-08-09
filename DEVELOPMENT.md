# Development Guide

This guide is for contributors working on BitChat. It focuses on a fast local setup, safe debugging, and practical troubleshooting – optimized for agentic, incremental changes.

## Prerequisites
- Xcode 15+
- macOS 13+
- Swift toolchain installed (via Xcode)
- XcodeGen (recommended):
  ```bash
  brew install xcodegen
  ```

## Project Layout (high level)
- `bitchat/` – app sources (Services, Protocols, Noise, ViewModels, Views)
- `bitchatTests/` – unit/integration tests
- `WHITEPAPER.md` – protocol/crypto/system specification
- `BRING_THE_NOISE.md` – Noise-layer specifics and session notes
- `PRIVACY_POLICY.md` – privacy guarantees and limits
- `AI_CONTEXT.md` – architecture + development context

## Setup & Run
### Option A: XcodeGen (recommended)
```bash
cd bitchat
xcodegen generate
open bitchat.xcodeproj
```
Select target and run.

### Option B: Swift Package Manager
```bash
cd bitchat
open Package.swift
```
Select a scheme and run from Xcode.

### Option C: Justfile helpers
The repo includes a `Justfile` with handy tasks. Try:
```bash
just run   # macOS sandbox run helper
just clean # restore workspace state
```

## Bluetooth permissions (iOS/macOS)
Ensure Info.plist contains a Bluetooth usage description (iOS/macOS may differ by version):
- `NSBluetoothAlwaysUsageDescription` – “BitChat uses Bluetooth to discover nearby peers and relay messages.”

BitChat already includes the correct entitlements in templates; this note is for manual project setups.

## Logging & Security
- Use structured logs for boundaries: discovery/connect/disconnect, handshake start/end, route selection.
- Never log secrets: keys, plaintext message content, session material, or relay auth tokens.
- Prefer redaction when in doubt. (See `WHITEPAPER.md` Security Considerations.)

## Debugging checklist (simple-first)
1. Bluetooth ON? Permissions granted? App in foreground? (macOS may require specific privacy settings.)
2. Any peers visible in discovery logs?
3. If connected but not authenticated, confirm Noise handshake paths (see `BRING_THE_NOISE.md`).
4. No messages? Check TTL policy and Bloom filter dedupe.
5. Nostr fallback only works for mutual favorites; verify both sides are favorited.

## Tests
- Open the Xcode project/workspace
- Product → Test (⌘U)
- Start with protocol/encoding tests and expand to services as needed

## Contributor tips (agentic pattern)
- Make one small change at a time; run and observe
- Prefer sequential baselines before introducing parallelism
- Add or improve logs at boundaries before refactors
- Document new lessons in `AI_CONTEXT.md` or a small `docs/` note

## Useful references
- `WHITEPAPER.md` – stack, message formats, TTL, Bloom filters
- `AI_CONTEXT.md` – system architecture and design decisions
- `BRING_THE_NOISE.md` – Noise protocol details and session lifecycle
- `PRIVACY_POLICY.md` – privacy scope and limitations