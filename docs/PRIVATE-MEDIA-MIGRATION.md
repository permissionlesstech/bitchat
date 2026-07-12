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
- A peer advertising `PeerCapabilities.privateMedia` receives one encrypted
  `noiseEncrypted` transfer.
- An unpinned peer with a stable Noise key but without that capability is
  eligible for one signed, directed
  `fileTransfer`, matching the pre-migration wire form used by older iOS and
  accepted by current Android clients, only after the sender confirms a
  per-send warning that the file is not end-to-end encrypted and mesh relays
  can see it. The
  consent is consumed by that invocation and is never remembered.
- A signed announce never creates a pin by itself. The fingerprint is pinned
  in the encrypted identity cache only after a completed Noise session
  authenticates the same static key as the capability-bearing registry entry.
  This comparison is performed in either event order: session then announce,
  or announce then session. A later announce missing the bit is then treated
  as a downgrade, and raw fallback is blocked even if a caller presents
  legacy consent.
- During migration, both an absent capabilities TLV and an explicit TLV
  without `privateMedia` are legacy-eligible when that stable fingerprint is
  not pinned. This supports clients that added capability advertisement before
  encrypted media. Neither shape bypasses a previously authenticated pin.

The `0x09` receive alias may be removed only after every TestFlight/internal
build that emitted it has expired and the project's minimum-supported-client
policy excludes those builds. Track that release criterion explicitly; do not
remove the alias on an arbitrary calendar date.

## Security boundary

The encrypted form provides Noise confidentiality and peer authentication.
The fallback is signed and its signature is required on receive, so relays
cannot forge its sender or contents. It is not confidential: relays can see
the raw file TLV. The UI says this explicitly and asks on every send. A peer
without a stable Noise key from a verified registry entry cannot use the
fallback. Keep
the fallback only for the mixed-version migration and remove it after
supported Android and iOS releases advertise `privateMedia`. Never replace it
with an unsigned fallback, persist blanket consent, or send both forms.

Incoming clients accept all three migration-era shapes:

| Sender | Inbound form | Result |
| --- | --- | --- |
| Current Android | Noise `0x20` | Decrypt and deliver |
| Prerelease iOS | Noise `0x09` | Decrypt, canonicalize, and deliver |
| Older client | Signed directed `fileTransfer` | Verify signature and deliver |
| Forged/unsigned raw sender | Directed `fileTransfer` | Reject |

Panic wipe clears the persistent capability pins together with the rest of
the encrypted identity cache.

This migration path is BLE-only. Nostr private-media transport is unchanged
and remains a follow-up; do not infer the BLE consent fallback or capability
pin semantics for Nostr delivery.

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
