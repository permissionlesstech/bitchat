# bitchat Protocol Specification

**Version:** 0.1.0 (see [`VERSION`](VERSION))

## Status of This Document

This specification is the normative definition of the bitchat protocol. Reference client implementations (Swift, Kotlin, or otherwise) are expected to conform to it. Where an implementation's behavior diverges from this document, the implementation — not the spec — is considered in error, until this document is formally revised.

This is a `0.1.0` release: a first, from-scratch, unreviewed draft. It has not yet been checked against every reference implementation in full, and its numbering reflects that — it does not claim the stability of a `1.0.0` release.

## Chapters

1. [Wire Format](01-wire-format.md) — packet header, byte offsets, TLV/field encodings
2. [BLE Transport](02-ble-transport.md) — GATT UUIDs, advertising format, MTU/fragmentation
3. [Noise](03-noise.md) — the Noise `XX` (live session) and `X` (offline seal) handshake message sequences and payloads
4. [Payloads](04-payloads.md) — application-layer payload encodings: announcements, private/public messages, board posts, group messages, files, voice frames
5. [Store and Forward](05-store-and-forward.md) — sender outbox, courier envelope format and rotating recipient tag, spray-and-wait budget, gossip-sync reconciliation
6. [Nostr Bridge](06-nostr-bridge.md) — NIP usage, relay interaction contract, relay-selection criteria
7. [Conformance](07-conformance.md) — implementation conformance checklist

## Requirements Language

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in [RFC 8174](https://www.rfc-editor.org/rfc/rfc8174) (which clarifies the original [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119)). They appear in this document only in their uppercase form, with that normative meaning; any lowercase occurrence of one of these words carries its ordinary English sense only.

## Byte-Layout Notation

Every fixed-layout structure in this specification (packet headers, fixed-size fields) is presented two ways, together:

- **An ASCII byte-diagram**, showing field boundaries visually across the structure's bytes.
- **A table**, giving the precise field-by-field breakdown, in this column order:

| Offset | Length (bytes) | Field | Description |
|---|---|---|---|
| *(byte offset from the start of the structure)* | *(field width, or "variable")* | *(field name)* | *(field's meaning and constraints)* |

Multi-byte integers are big-endian unless a chapter states otherwise. Variable-length fields (TLV-encoded payloads, and similar) are described in prose immediately following the table, using the same two-column style for their own sub-fields where useful.

## Glossary

Terms below are defined once here and used consistently across every chapter; a chapter marks a term in backticks on first use rather than redefining it locally. Vocabulary carries over from `WHITEPAPER.md` rather than being renamed.

- **peer ID** — the 8-byte identifier a device presents on the BLE mesh, derived from the first 8 bytes of the SHA-256 fingerprint of its Noise static key. Stable across sessions; changes only when the underlying identity is replaced.
- **static key** — a device's long-term Curve25519 key pair, used for Noise key agreement. Its SHA-256 fingerprint is the peer's stable identity.
- **signing key** — a device's long-term Ed25519 key pair, used to sign packets and announcements.
- **announcement** — a signed packet a device broadcasts to identify itself, carrying its nickname, static key, and signing key in cleartext, plus a short list of direct-neighbor peer IDs.
- **source route** — an explicit, ordered list of peer IDs a version-2 packet may carry, directing it along a known path instead of relying on flooding.
- **fragment** — one piece of a packet that exceeded the transport's MTU and was split for independent relay and reassembly at the receiving node.
- **Noise session** — a live, bidirectional encrypted channel between two connected peers, established with the Noise `XX` handshake pattern.
- **courier envelope** — an opaque, one-way-sealed message (Noise `X` pattern) handed to an intermediate peer for physical carriage to a recipient who is not currently reachable.
- **rotating recipient tag** — the opaque, day-rotating addressing tag on a courier envelope, computable only by parties who already know the recipient's static key.
- **trust tier** — the deposit quota a courier extends to a sender, based on whether the sender is a mutual favorite or merely signature-verified.
- **spray-and-wait** — the copy-budget scheme by which a courier envelope diffuses across couriers who encounter each other, rather than riding a single carrier.
- **sender outbox** — the persistent, per-peer retry queue a sender holds for private messages that have not yet been delivered or acknowledged.
- **favorite** / **mutual favorite** — a pinned trust relationship between two devices' static keys; when mutual, it unlocks Nostr-path delivery and a larger courier deposit quota.
- **gossip sync** — the periodic reconciliation of cached public broadcast history between peers, so a peer that missed messages can catch up from another peer's cache.
- **panic wipe** — the operation that erases all local identity, keys, and persisted protocol state.
- **relay** (verb) — a BLE mesh node forwarding a packet it did not originate, toward other links.
- **relay** (noun, Nostr context) — a Nostr server that stores and forwards signed events; distinct from a BLE mesh relay.
- **TTL** — the hop-count budget on a BLE mesh packet, decremented by each relay; a packet is not forwarded once it reaches zero.
