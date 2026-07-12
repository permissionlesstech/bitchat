# Private-media wire migration

Private files use the `BitchatFilePacket` TLV shared by iOS and Android. The
preferred direct-message wire form encrypts that complete TLV inside the
peer's Noise session before BLE fragmentation.

## Wire values and capability

- `NoisePayloadType.privateFile` is `0x20`, the value already deployed by the
  Android client. New sends must use this value.
- iOS temporarily accepts `0x09`, which appeared in prerelease builds of the
  private-media change. Decoders canonicalize it to `privateFile`; they never
  emit it.
- `NoisePayloadType.authenticatedPeerState` is permanently assigned `0x21`.
  It is emitted after every completed/rekeyed Noise XX session and echoed at
  most once when the remote state arrives, so message-3/proof reordering over
  different mesh links converges. This type is part of the protocol security
  boundary and is not removed when the media migration ends.
- The `0x21` payload starts with version `0x01`, followed by one-byte
  type/length/value fields. Version 1 requires canonical TLV `0x01` (the
  minimal little-endian `PeerCapabilities` bitfield, 1-8 bytes) and TLV `0x02`
  (the 32-byte Ed25519 announcement signing key). Duplicate required fields,
  non-minimal capabilities, malformed lengths, missing fields, and unknown
  versions are ignored without changing state. Unknown TLVs are skipped.
- The public `PeerCapabilities.privateMedia` announce bit is a discovery hint:
  it starts a Noise handshake, but never selects encrypted sending or creates
  a pin. A private transfer waits boundedly for the exact session's encrypted
  `0x21`. A valid bit-8 proof selects Noise `0x20`; a valid no-bit proof or a
  no-proof timeout reaches the explicit legacy-consent path for an unpinned
  peer. No timeout automatically sends raw bytes.
- An unpinned peer with a stable Noise key but without that capability is
  eligible for one signed, directed
  `fileTransfer`, matching the pre-migration wire form used by older iOS and
  accepted by current Android clients, only after the sender confirms a
  per-send warning that the file is not end-to-end encrypted and mesh relays
  can see it. The
  consent is consumed by that invocation and is never remembered.
- A signed announce never creates a pin by itself: an attacker can copy a
  victim's public Noise key, supply its own Ed25519 key and capability bits,
  and self-sign an internally consistent announce. Only successfully
  decrypted `0x21` state pins the authenticated Noise fingerprint and binds
  the Ed25519 key used by later announces/public messages. A later valid
  no-bit `0x21` is treated as a downgrade, and raw fallback is blocked even if
  a caller presents legacy consent. Public no-bit announces cannot overwrite
  current session-authenticated state.
- During migration, both an absent capabilities TLV and an explicit TLV
  without `privateMedia` are legacy-eligible when that stable fingerprint is
  not pinned. This supports clients that added capability advertisement before
  encrypted media. Neither shape bypasses a previously authenticated pin.

Older clients decrypt and ignore unknown inner type `0x21`; they do not need to
understand it to continue using text or the warned legacy media path. They are
never inferred capable merely because the handshake succeeded.

Removal gates are independent and must not share an arbitrary calendar date:

- Remove the `0x09` receive alias only after every TestFlight/internal build
  that emitted it has expired and minimum-supported-client policy excludes it.
- Remove the signed directed raw `0x22` fallback only after minimum-supported
  iOS and Android clients emit authenticated bit-8 `0x21` state and the legacy
  population has aged out.
- Nostr kind `1059` compatibility is a separate envelope migration. Its dual
  publish/removal gate is not evidence that either BLE compatibility shape can
  be removed.

## Security boundary

The encrypted form provides Noise confidentiality and peer authentication.
The fallback is signed and its signature is required on receive, so relays
cannot forge its sender or contents. It is not confidential: relays can see
the raw file TLV. The UI says this explicitly and asks on every send. A peer
without a stable Noise key from a verified registry entry cannot use the
fallback. Keep it only for the mixed-version migration, and remove it only
after minimum-supported Android and iOS releases emit authenticated bit-8
`0x21` state and the legacy population has aged out. Never replace it with an
unsigned fallback, persist blanket consent, or send both forms.

Incoming clients accept all three migration-era shapes:

| Sender | Inbound form | Result |
| --- | --- | --- |
| Current Android | Noise `0x20` | Decrypt and deliver |
| Prerelease iOS | Noise `0x09` | Decrypt, canonicalize, and deliver |
| Older client | Signed directed `fileTransfer` | Verify signature and deliver |
| Forged/unsigned raw sender | Directed `fileTransfer` | Reject |

Panic wipe clears the persistent capability pins together with the rest of
the encrypted identity cache.

This migration path is mesh-Noise-only (BLE and compatible direct mesh links).
Nostr private-media transport is unchanged and remains a follow-up. Nostr
inbound paths explicitly ignore `0x21`; do not infer the mesh consent fallback
or capability-pin semantics for Nostr delivery.

## Size interoperability

iOS bounds inbound file content at 1 MiB and applies the expanded allocation
budget only after a large Noise ciphertext authenticates to `0x20` or the
temporary `0x09` alias. Ordinary Noise messages retain their 64 KiB limit.

Current Android builds cap each reassembly at 256 fragments. Depending on the
negotiated BLE packet size and routing overhead, that is roughly 110-120 KiB,
well below iOS's absolute inbound ceiling. Private-media v1 therefore runs the
actual route-aware BLE fragment planner before both encrypted and consented
legacy sends and rejects any plan above 256 fragments with a visible failure.
This fragment-count contract, rather than a guessed byte threshold, stays
correct as route overhead changes.
