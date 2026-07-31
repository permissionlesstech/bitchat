Tor-by-default integration (scaffold)

Overview
- All network traffic is routed via a local Tor SOCKS5 proxy by default, with fail-closed behavior when Tor isn’t ready. There are no user-visible settings.
- This repo vendors an Arti-backed Swift package under `localPackages/Arti`, including a Rust static-library xcframework linked by SwiftPM.

Key pieces
- TorManager
  - Boots Tor, manages a DataDirectory under Application Support, exposes SOCKS at 127.0.0.1:39050, and provides awaitReady().
  - Fails closed by default until Tor is bootstrapped. For local development only, define BITCHAT_DEV_ALLOW_CLEARNET to bypass Tor.
- TorURLSession
  - Provides a shared URLSession configured with a SOCKS5 proxy when Tor is enforced/ready.
  - NostrRelayManager and GeoRelayDirectory now use this session and await Tor readiness before starting network activity.

Artifact maintenance
- Binary provenance, rebuild steps, and current hashes are documented in `docs/ARTI-BINARY-PROVENANCE.md`.
- The xcframework must include iOS device, iOS simulator, and macOS arm64 slices.
- Any refresh should review the Rust source, `Cargo.lock`, generated header, build script, and new hashes together.

Verification
   - On app launch, TorManager.startIfNeeded() is called implicitly by awaitReady().
   - NostrRelayManager.connect() awaits readiness, then creates WebSocket tasks via TorURLSession.shared.
   - GeoRelayDirectory.fetchRemote() awaits readiness, then fetches via TorURLSession.shared.

Optional macOS optimization
   - Detect a system Tor binary (e.g., /opt/homebrew/bin/tor) and run it as a subprocess to avoid bundling. Keep the embedded fallback for portability.

torrc template
The generated torrc (under Application Support/bitchat/tor/torrc) is:

  DataDirectory <AppSupport>/bitchat/tor
  ClientOnly 1
  SOCKSPort 127.0.0.1:39050
  ControlPort 127.0.0.1:39051
  CookieAuthentication 1
  AvoidDiskWrites 1
  MaxClientCircuitsPending 8

Dev bypass (local only)
- To temporarily allow direct network without Tor for local development:
  - Add Swift compiler flag: BITCHAT_DEV_ALLOW_CLEARNET
  - This enables a clearnet session in TorURLSession when Tor isn’t present.
  - Never enable this in release builds.

Notes
- We intentionally do not change any app-level APIs: consumers simply use TorURLSession via existing code paths.
- When Tor is missing in release builds, the app will not connect (fail-closed), logging a clear reason.
