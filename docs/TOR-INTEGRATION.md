Tor-by-default integration (scaffold)

Overview
- All network traffic is routed via a local Tor SOCKS5 proxy by default, with fail-closed behavior when Tor isn’t ready. There are no user-visible settings.
- This repo now includes a minimal TorManager and TorURLSession to make dropping in an embedded Tor framework straightforward.

Key pieces
- TorManager
  - Boots Tor, manages a DataDirectory under Application Support, exposes SOCKS at 127.0.0.1:39050, and provides awaitReady().
  - Fails closed by default until Tor is bootstrapped. For local development only, define BITCHAT_DEV_ALLOW_CLEARNET to bypass Tor.
- TorURLSession
  - Provides a shared URLSession configured with a SOCKS5 proxy when Tor is enforced/ready.
  - NostrRelayManager and GeoRelayDirectory now use this session and await Tor readiness before starting network activity.

Drop‑in steps
1) Build or obtain a small Tor framework
   - Recommended: Tor C (client-only) with static linking and dead-strip.
   - Configure Tor with a minimal feature set:
     ./configure \
       --enable-static \
       --disable-asciidoc --disable-unittests --disable-manpage \
       --disable-zstd --disable-lzma --enable-zlib \
       --disable-systemd --disable-ptrace --disable-seccomp
     CFLAGS="-Os -fdata-sections -ffunction-sections" \
     LDFLAGS="-Wl,-dead_strip"
   - Build a tiny OpenSSL/LibreSSL (no engines, strip symbols) or reuse system crypto where permitted on macOS.

2) Add the framework to Xcode targets
   - Drop your xcframework into `Frameworks/`. The project is prewired in `project.yml` to link/embed `Frameworks/tor-nolzma.xcframework` (rename yours to match, or update the path).
   - Ensure the binary includes the slices you need (iOS device/simulator and/or macOS). If your xcframework lacks simulator slices, you can still build/run on device or macOS arm64; simulator will fail to link.
   - On iOS, it will be embedded and signed automatically.

3) Wire Tor bootstrap in TorManager.startTor()
   - Two paths are already implemented:
     - If a module named `Tor` is present (iCepa API), it starts `TORThread` directly.
     - Otherwise, it attempts a dynamic load (`dlopen`) of a bundled framework binary named `tor-nolzma.framework/tor-nolzma` (or `Tor.framework/Tor`), resolves `tor_run_main`, and launches Tor on a background thread.
   - `TorManager` writes a torrc and then probes `127.0.0.1:39050` until ready.

4) Verify networking
   - On app launch, TorManager.startIfNeeded() is called implicitly by awaitReady().
   - NostrRelayManager.connect() awaits readiness, then creates WebSocket tasks via TorURLSession.shared.
   - GeoRelayDirectory.fetchRemote() awaits readiness, then fetches via TorURLSession.shared.

5) Optional macOS optimization
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
