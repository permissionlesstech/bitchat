# BitFoundation golden vectors

BitChat’s shared crypto and wire types live in `localPackages/BitFoundation`. Executable **golden vectors** in that package are how independent clients (Android today, future SDKs under [#1073](https://github.com/permissionlesstech/bitchat/issues/1073)) prove they speak the same bytes without copying Swift source.

This note documents the pattern already used for peer-ID rotation so new protocol surfaces can follow it.

## Where the pattern lives today

| Piece | Path |
|---|---|
| Spec text | [`docs/PEER-ID-ROTATION.md`](PEER-ID-ROTATION.md) |
| Implementation | `localPackages/BitFoundation/Sources/BitFoundation/PeerIDRotation.swift` |
| Golden vectors | `localPackages/BitFoundation/Tests/BitFoundationTests/PeerIDRotationTests.swift` |
| Wire-format tests | `localPackages/BitFoundation/Tests/BitFoundationTests/AnnounceV2PacketTests.swift` |

Comments in `PeerIDRotationTests` mark fixed hex digests with `VECTOR:` and explain the two rules that keep them useful.

## Rules

1. **Reproduce from the spec, not from the other platform’s code.**  
   Derive expected digests from `docs/PEER-ID-ROTATION.md` (or the relevant protocol doc) using an independent HKDF/HMAC implementation. Matching Swift by reading Swift only proves both sides share a bug.

2. **When the derivation changes, the hex changes deliberately.**  
   Never “fix” a vector to match new behavior in place without updating the spec and calling out the break. A vector that silently tracks the implementation has stopped being a vector.

3. **Keep inputs obviously fake and stable.**  
   Use fixed key material (for example `01..20`) and fixed epochs so CI failure is about crypto, not flaky clocks.

4. **Ship vectors next to the type they constrain.**  
   Prefer `BitFoundationTests` over app-target tests so an SDK or Android checkout that vendors only BitFoundation still runs them.

## How to add vectors for a new surface

1. Write or update the human spec under `docs/`.
2. Implement the pure functions in BitFoundation (no UI, no BLE).
3. Add `@Test` cases that assert full hex digests (or fixed byte arrays) with a `VECTOR:` comment naming the construction.
4. Cross-check once with an independent tool (Python `hmac`/`hashlib`, Go, etc.) and note that in the test file header.
5. Link the new doc from this file’s table when the surface is meant for interop.

## What this is not

- Not a substitute for a versioned, standalone protocol repository (the longer-term ask in #1073 / #1448).
- Not permission to paste production key material into tests.
- Not a requirement that every unit test become a golden vector — reserve digests for cross-platform consensus surfaces.

## Quick check

From the repo root, BitFoundation’s suite (including vectors) runs as part of the normal SwiftPM / `just test` path used by CI.
