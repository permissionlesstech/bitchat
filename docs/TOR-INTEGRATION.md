# Tor integration

## Overview

Internet traffic — Nostr relay sockets and the geo-relay directory fetch — is routed through Tor by default, fail-closed: when Tor is wanted but not ready, requests queue rather than falling back to clearnet.

Tor is provided by **Arti, in-process**, vendored as a Swift package under `localPackages/Arti` wrapping a Rust static-library xcframework. There is no `tor` binary, no `torrc`, and no control port. A SOCKS5 listener on `127.0.0.1:39050` is the only application-facing interface.

iOS does not sandbox loopback between apps, so that listener is reachable by anything else on the device while it is up, and it takes no credential. Two bounds limit what a caller other than the app can do with it: a handshake that does not complete within 30 seconds is dropped, and at most 64 sessions are carried at once, which is far above what the relay set plus the directory fetch needs. Neither bound turns it into an authenticated interface. Closing that properly means a per-run SOCKS5 credential, which depends on `URLSessionConfiguration.connectionProxyDictionary` honoring `SOCKSUser`/`SOCKSPassword` on iOS; that has not been verified on a device, and getting it wrong takes the whole app off the network.

On physical iOS devices, the same package can run obfs4 or Snowflake through the vendored IPtProxy framework. IPtProxy opens a separate loopback SOCKS listener. Arti validates the original bridge lines and connects to that listener through its unmanaged pluggable-transport support. App payload connections still enter Arti at `127.0.0.1:39050`.

## Key pieces

- **`TorManager`** — owns the Arti client and its data directory under Application Support, exposes the SOCKS port, and provides `awaitReady()`.
  - `torEnforced` is compile-time: true unless `BITCHAT_DEV_ALLOW_CLEARNET` is defined. It is not set anywhere in `Configs/` or the project file, so release builds enforce.
  - `isStarting`, `bootstrapProgress`, and `bootstrapSummary` describe an attempt in flight.
  - `bootstrapDidStall` becomes true when the active route gives up, and posts `.TorBootstrapDidStall` after the configured sequence is exhausted. A route gives up when Arti's bootstrap percentage stops advancing for 30 seconds on direct Tor, 90 on obfs4, or 120 on Snowflake, or when it hits a ceiling of 45, 120, and 300 seconds respectively. The windows differ because each transport keeps its own directory cache, so a bridged route downloads the whole Tor directory on every cold start and plateaus while circuits retry. Elapsed time alone does not end an attempt: Snowflake fetches the directory over a lossy hop and retries visibly while still making progress, so a fixed deadline used to kill working attempts and report them as a blocked network.
  - `transportStatus` reports the active route, lifecycle, and previously attempted routes without including bridge material.
  - Readiness has two writers that can land in either order — the once-a-second bootstrap poll and the SOCKS probe — so `TorReadinessPolicy` re-reads Arti's counter when the probe reports a live listener over a percentage that is behind. Judging on the published copy alone left a fully bootstrapped route fail-closed for good whenever the probe won that race.
  - The probe itself only opens a connection once Arti reports bootstrap complete, because Arti binds the listener only after that. Skipping the earlier attempts drops a refused loopback connection every couple of seconds across the whole bootstrap and pays for polling often enough to publish readiness within about half a second.
  - `resetTransportForPanic()` removes Arti's directory tree as well as IPtProxy's state. A bridged route caches the bridge descriptors it fetched keyed by the bridge line that produced them, so leaving that tree in place left user-supplied obfs4 bridges recoverable from disk after a panic wipe; removing the parent also takes direct Tor's guard state.
- **`IPtProxyTransportController`** — iOS-only lifecycle wrapper for obfs4 and Snowflake. Logging and unsafe logging are disabled. Its state directory is excluded from backup and removed by panic wipe.
- **`TorTransportSettings`** — persists the selected mode in `UserDefaults` and stores user-supplied obfs4 lines in a dedicated device-only Keychain service. The Swift validator bounds and normalizes input; Arti parses it again before any network work begins.
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

## Censorship resistance on iOS

The advanced iOS setting defaults to **direct tor**, preserving the existing behavior until the user opts in:

- **direct tor** uses public Tor relays.
- **auto** tries direct Tor, configured obfs4 bridges, and Snowflake. A missing obfs4 configuration is skipped. After a successful bootstrap, that available route is tried first next time.
- **obfs4** requires one to eight bridge lines supplied by the user. The app does not fetch bridges, contact BridgeDB, or put bridge lines in logs or preferences.
- **snowflake** uses the two CDN77 bridge lines enabled by the pinned Tor Project Snowflake client configuration and does not require user bridge input. Other rendezvous methods in that configuration are alternatives, not additional bridges to enable concurrently.

Each transition cancels any in-progress Arti bootstrap, waits for that task to exit, and stops IPtProxy before starting the next route. Direct Tor, obfs4, and Snowflake use separate Arti state directories so cached guards from one route cannot drive another route. Attempt generations prevent a stale task from changing the current route's status, and duplicate shutdown requests are coalesced. Relay sockets are disconnected during transport changes and remain fail-closed until the new Arti SOCKS endpoint is ready. There is no automatic or terminal fallback to clearnet. A failed sequence remains visible and can be retried manually.

IPtProxy's raw logging stays disabled. A byte-transparent loopback monitor records whether Arti opened the unmanaged transport and whether IPtProxy accepted the local TCP connection without parsing or modifying the SOCKS handshake. Snowflake uses one WebRTC peer per SOCKS request, and its aggregate status latches after the first proxy connects so a sibling attempt failure cannot overwrite a working route. The app consumes controlled transport states such as Arti handoff configured, bridge request received, proxy connected, proxy discovery retrying, or transport stopped. Raw broker responses, bridge lines, hostnames, and error strings are not copied into UI or application logs.

Arti's `tracing` output is discarded by default, which makes a bootstrap that hangs indistinguishable from one that never started. Debug builds can switch on a bridge that forwards it to the app log during the bootstrap poll. Text is not forwarded verbatim: Rust keeps each event's target, its level, and the leading run of plain words, and stops at the first token that could be an address, fingerprint, URL, or bridge parameter. That is enough to tell whether `tor_ptmgr` and `tor_guardmgr` ever engaged the bridge, and it cannot carry an identifier. Release builds never enable it, and `SecureLogger.debug` compiles out of them regardless.

Obfs4 makes Tor traffic resemble random protocol traffic and is most useful with private or less-blocked bridge addresses. Snowflake uses broker rendezvous, domain fronting, and WebRTC proxies, which gives it a larger and changing proxy pool when fixed bridges are blocked. Neither transport makes the device invisible: the network can still observe connection timing and volume, and Snowflake's broker, front domain, STUN servers, and proxy peers can observe transport-level metadata.

This integration is iOS-only. The checked-in IPtProxy xcframework contains the `ios-arm64` and `ios-arm64_x86_64-simulator` slices; the simulator slice is what lets CI build the app and run the test suite. No macOS transport slice is packaged, and the existing macOS target retains direct Arti behavior without pluggable-transport controls. Transport acceptance testing is still device-only: the simulator links the same code but is not a substitute for exercising obfs4 or Snowflake against a real censored network.

## Relays

Private messages target the built-in relay set plus any relays added by hand (`NostrRelaySettings`, capped at 8, `.onion` addresses accepted). The built-in set is four well-known clearnet hostnames, so a filter blocking four names would otherwise end internet-delivered private messages until a new build shipped.

## Artifact maintenance

- Binary provenance, rebuild steps, and current hashes: `docs/ARTI-BINARY-PROVENANCE.md`, enforced by `.github/workflows/arti-provenance.yml`.
- `build-arti-ios-device.sh` refreshes the iOS Arti libraries and leaves the macOS slice alone.
- `build-iptproxy-ios-device.sh` builds from an exact IPtProxy checkout with the `ios` target and packages its `ios-arm64` and `ios-arm64_x86_64-simulator` framework slices.
- Any refresh reviews the Rust and Go source pins, lockfiles, generated headers, build scripts, licenses, and new hashes together. A binary-only update is not acceptable.

## Dev bypass (local only)

Define the Swift compiler flag `BITCHAT_DEV_ALLOW_CLEARNET` to allow direct network access without Tor while developing. Never enable it in release builds.
