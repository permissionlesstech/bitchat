# NdrFfi

Source-build package for the generated Swift bindings and dynamic Apple XCFramework for the
single-device pairwise UniFFI crate in `nostr-double-ratchet`. The binary does
not include AppKeys, linked-device, sibling-sync, or group runtime code.

## Source Of Truth

The generated files in this package come from the upstream
`nostr-double-ratchet` checkout, specifically the Rust `ndr-pairwise-ffi`
crate and its UniFFI-generated Swift bindings. The built library keeps the
module name `ndr_ffi`.

The exact upstream revision is pinned by the
`vendor/nostr-double-ratchet` submodule and repeated in `SOURCE_REVISION`.
Neither native libraries nor generated Swift are tracked. `SWIFT_BINDINGS_SHA256`
pins the normalized Swift output; generation fails before installation if its
digest differs. Apple
deployment targets are fixed in the build script, so ambient shell settings
cannot change the output.

## Rebuild From Source

Prerequisites:

- Xcode and command line tools; CI selects the tested version in `.xcode-version`
- Rust toolchain version from `RUST_TOOLCHAIN`, with cargo
- Rust targets:
  - `aarch64-apple-darwin`
  - `x86_64-apple-darwin`
  - `aarch64-apple-ios`
  - `aarch64-apple-ios-sim`
  - `x86_64-apple-ios`

Example:

```bash
rustup target add --toolchain "$(cat localPackages/NdrFfi/RUST_TOOLCHAIN)" \
  aarch64-apple-darwin \
  x86_64-apple-darwin \
  aarch64-apple-ios \
  aarch64-apple-ios-sim \
  x86_64-apple-ios
git submodule update --init --checkout vendor/nostr-double-ratchet
./localPackages/NdrFfi/build-apple.sh
```

Or:

```bash
cd localPackages/NdrFfi
NOSTR_DOUBLE_RATCHET_DIR=/path/to/nostr-double-ratchet ./build-apple.sh
```

For macOS development, use `./localPackages/NdrFfi/build-apple.sh --platform macos`;
for iOS, use `--platform ios`. Only install the corresponding Rust targets from
the list above. The default `--platform all` builds every shipping slice for CI.
Each invocation replaces the generated framework with the requested platforms.
Run generation before opening Xcode or invoking SwiftPM in a clean checkout.

The script:

- builds the upstream `ndr-pairwise-ffi` crate
- reuses an ignored Cargo target cache under `.cache/ndr-ffi/apple`
- regenerates `Sources/NdrFfi/NdrFfi.swift` via UniFFI and checks its pinned digest
- rebuilds the ignored dynamic Apple XCFramework at `Frameworks/NdrFfi.xcframework`
- bakes in the current Apple deployment targets used by `bitchat`

The NDR runtime is an embedded dynamic framework because the shipping app
already links Arti as a Rust static library. Rust static libraries each bundle
their own standard library and are not safe to combine independently in one
foreign-linker process.

## Outputs Updated By The Script

- `Sources/NdrFfi/NdrFfi.swift` (local build output, ignored)
- `Frameworks/NdrFfi.xcframework` (local build output, ignored)

## Recommended Verification

```bash
swift test --package-path localPackages/NdrFfi
swift test --filter NdrOutOfBandTransportTests
swift test --filter NostrTransportTests
```

## Integration contract

This is a single-device pairwise transport enabled for compatible mutual
favorites. Peers without the authenticated capability retain the existing relay
envelope. `BITCHAT_DISABLE_NDR` explicitly disables new NDR operation while
preserving durable downgrade barriers. Android and Apple pin the same native
source revision and wire contract.

Either peer can initiate bootstrap; the native runtime converges crossed
invitations onto one session. Each started invite finishes its existing finite
retry budget while its authenticated binding remains current. A local session
does not prove the remote peer received our response. Repeating the identical
invite replays the cached native response and bootstrap envelope.

- Bootstrap invites (kind 30078) and responses (kind 1059) travel only inside
  the existing authenticated BLE Noise session. Admission checks bind the peer
  Noise key, capability and exact session generation; an unauthenticated
  announcement or a later connection cannot authorize a queued bootstrap.
- Relays carry signed kind-1060 envelopes with ephemeral sender keys and no
  recipient `p` tag, with exactly one `v=2` tag. An acceptance-specific responder
  key excludes public invite keys from private authors and subscription filters.
  The host reinstalls subscriptions when ephemeral authors
  rotate, even when the native subscription ID stays the same.
- Each publish attempt uses fresh send-only sockets, separate from receiving
  subscriptions, with no cookies, credentials, `REQ` or `AUTH`. Challenges fail
  closed and retries open new sockets. The selected Tor route is preserved;
  authentication-required relays remain unsupported.
- Before a native session can be created, durable favorite and identity pins
  disable legacy fallback. Session loss, unreadable storage, identity rebind,
  a disabled rollout, and incomplete handshakes must not reopen kind-1059 DMs
  for a pinned contact. Unfavoriting keeps an inactive binding for this check.
  Rebind uses a recoverable journal; panic reset must
  clear native state and pins as one fail-closed lifecycle operation.
- Only embedded private messages and their delivery/read acknowledgements
  cross this transport. Acknowledgements stay on the pairwise session.
  Geohash DMs continue to use their existing envelope and never carry the
  mesh peer ID. Expiration is checked again immediately before delivery.
- The native action queue owns durable work. The host acknowledges actions
  only after the corresponding relay, BLE, or consumer operation succeeds.

Privacy-v2 preserves history and downgrade pins while quarantining pre-upgrade
sessions, queued ciphertext and subscription authors. Both peers must upgrade
and complete a fresh authenticated Noise bootstrap. A retained session with
neither send nor receive readiness permits rebootstrap; receive-only sessions
still count as compatible handshakes in progress. Unversioned invites and
messages are rejected. Old queued ciphertext is not automatically resent and
cannot reopen legacy fallback for a pinned contact.

Group messaging, AppKeys, linked devices and sibling synchronization are not
part of this integration. Enabling it requires native/host tests, both shipping
Apple builds, Android validation, and physical cross-client bootstrap/message/
restart/reset coverage. Current source-build and host tests do not establish
physical-device interoperability.
