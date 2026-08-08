# BitChat Protocol Specification

**Spec version:** [`1.0.1`](VERSION)  
**Status:** Draft extracted from the reference implementation  
**Canonical codec:** `localPackages/BitFoundation`  
**Architecture overview:** [`WHITEPAPER.md`](../WHITEPAPER.md)

This directory is the byte-exact interoperability contract for independent
clients. It is versioned independently of any one app release. The whitepaper
describes *why* the system is shaped the way it is; these documents describe
*what* must be on the wire for two implementations to talk.

## Documents

| # | Document | Contents |
|---|----------|----------|
| 1 | [`01-wire-format.md`](01-wire-format.md) | Packet header, flags, compression, padding, peer IDs, message types |
| 2 | [`02-ble-transport.md`](02-ble-transport.md) | GATT UUIDs, advertising, MTU, fragmentation/reassembly, flood knobs |
| 3 | [`03-noise.md`](03-noise.md) | XX live sessions, X offline seals, transport frames, payload type map |
| 4 | [`04-payloads.md`](04-payloads.md) | Per-type TLV layouts (announce, message, file, courier, prekey, ping, …) |
| 5 | [`05-nostr-bridge.md`](05-nostr-bridge.md) | Proprietary private envelopes and geohash event kinds |
| — | [`conformance.md`](conformance.md) | Checklist and pointers to existing test vectors |

## Normative language

The key words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are to be
interpreted as in RFC 2119.

Where this spec and the Swift/Kotlin reference clients disagree, treat the
codec in `localPackages/BitFoundation` (and the Android mirror of the same
wire types) as authoritative until this document is amended. Open a PR against
`/spec` when fixing either side.

## Versioning

- Spec versions use **SemVer** (`MAJOR.MINOR.PATCH`) stored in [`VERSION`](VERSION).
- **MAJOR** — breaking wire change (header layout, type reassignment, crypto suite).
- **MINOR** — additive, backward-compatible (new message type, new TLV skipped by old clients).
- **PATCH** — clarifications, errata, conformance notes with no wire change.
- Spec version is **independent** of App Store / Android release numbers.

Unknown TLV types and unknown high capability bits are handled
per-family: most public TLV decoders skip unknowns so older clients can carry
newer packets opaquely, but some inner payloads (notably private-message TLVs)
reject unknowns — see [`04-payloads.md`](04-payloads.md).

## Suggested reading order for implementers

1. Wire format → build an encode/decode round-trip for empty announce packets.
2. BLE transport → discover peers and exchange a single signed announce.
3. Noise → establish an XX session and send a typed private payload.
4. Remaining payload chapters as needed (files, courier, Nostr).

## Related work

- Relay-selection / geohash delivery semantics for external publishers: issue
  [#1473](https://github.com/permissionlesstech/bitchat/issues/1473) and
  `docs/GeohashPresenceSpec.md`.
- Formal conformance vectors beyond the Noise explorer set and courier
  fixtures are tracked as follow-up work; see [`conformance.md`](conformance.md).
