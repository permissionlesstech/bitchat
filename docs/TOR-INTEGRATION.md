# Tor integration

## Overview

Internet traffic — Nostr relay sockets and the geo-relay directory fetch — is routed through Tor by default, fail-closed: when Tor is wanted but not ready, requests queue rather than falling back to clearnet.

Tor is provided by **Arti, in-process**, vendored as a Swift package under `localPackages/Arti` wrapping a Rust static-library xcframework. There is no `tor` binary, no `torrc`, and no control port. A SOCKS5 listener on `127.0.0.1:39050` is the only interface.

## Key pieces

- **`TorManager`** — owns the Arti client and its data directory under Application Support, exposes the SOCKS port, and provides `awaitReady()`.
  - `torEnforced` is compile-time: true unless `BITCHAT_DEV_ALLOW_CLEARNET` is defined. It is not set anywhere in `Configs/` or the project file, so release builds enforce.
  - `isStarting`, `bootstrapProgress`, and `bootstrapSummary` describe an attempt in flight.
  - `bootstrapDidStall` becomes true when an attempt spends its whole 75-second deadline without completing, and posts `.TorBootstrapDidStall`. This is the state a network that blocks Tor produces, and it is deliberately distinct from `isStarting`: without it the UI says "starting tor…" indefinitely. It is cleared on each new start or restart.
- **`TorURLSession`** — a shared `URLSession` with the SOCKS proxy configured when proxying is on, and an unproxied session when it is off. `setProxyMode(useTor:)` is the switch, driven by `NetworkActivationService`.
- **`NetworkActivationService`** — decides whether Tor may run at all. Tor starts when the activation policy permits it *and* the Tor preference is on. `persistedTorPreference(in:)` is a `nonisolated` read of that preference for callers off the main actor.

Both network call sites go through `TorURLSession`: `NostrRelayManager` (relay websockets) and `GeoRelayDirectory` (directory CSV refresh). There is no other outbound network in the app or the share extension.

## The Tor preference is user-visible

The earlier version of this document said there are no user-visible settings. There is one: a **tor routing** toggle in settings, persisted under `networkActivationService.userTorEnabled`, defaulting to on.

Turning it off is a real change in exposure, not a performance tweak. Every fail-closed guard is conditioned on the preference, so with it off:

- relay websockets connect directly, and every relay operator sees the device IP — including relays carrying private messages;
- the geo-relay directory fetch also goes direct.

The settings UI states this while the toggle is off.

`GeoRelayDirectory` keys its Tor wait on the *preference*, not on live readiness, and this distinction is load-bearing. With Tor off, waiting for a client that has been shut down would spend the full bootstrap timeout on every refresh and freeze the directory on its cached copy. With Tor on but not ready, the wait must still fail so the fetch is skipped rather than silently leaking the IP.

## Relays

Private messages target the built-in relay set plus any relays added by hand (`NostrRelaySettings`, capped at 8, `.onion` addresses accepted). The built-in set is four well-known clearnet hostnames, so a filter blocking four names would otherwise end internet-delivered private messages until a new build shipped.

## Artifact maintenance

- Binary provenance, rebuild steps, and current hashes: `docs/ARTI-BINARY-PROVENANCE.md`, enforced by `.github/workflows/arti-provenance.yml`.
- The xcframework must include iOS device, iOS simulator, and macOS arm64 slices.
- Any refresh reviews the Rust source, `Cargo.lock`, generated header, build script, and new hashes together. A binary-only update is not acceptable.

## Known gap: no bridges or pluggable transports

`arti-client` is built with `default-features = false` and features `["tokio", "rustls"]` only — no `pt-client`, no `bridge-client` — and `arti-bitchat/src/lib.rs` bootstraps from stock configuration with no bridge lines and no configurable directory authorities.

So in a country that blocks Tor by blocking the public relays and directory authorities, bootstrap never completes. The app reports that clearly now instead of appearing to start forever, and the BLE mesh is unaffected, but there is no circumvention path: obfs4, snowflake, and meek are all unavailable.

Closing this means enabling the pluggable-transport features, plumbing bridge configuration through the FFI and a settings surface, and rebuilding the xcframework under the pinned toolchain with a provenance-manifest update. That is the single largest remaining gap in censorship resilience for the internet transport.

## Dev bypass (local only)

Define the Swift compiler flag `BITCHAT_DEV_ALLOW_CLEARNET` to allow direct network access without Tor while developing. Never enable it in release builds.
