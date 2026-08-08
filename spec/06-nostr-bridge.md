# Nostr Bridge

This chapter specifies bitchat's use of the Nostr protocol: the event kinds and tags it defines, the private-envelope construction carried over Nostr for one-to-one messages, relay-selection criteria, geohash-scoped public channels, and the `gateway`/`bridge` services that carry mesh traffic across the internet.

Two of this chapter's mechanisms are foundational and REQUIRED of every conformant implementation: the private-message envelope (§2) and geohash public channels (§3–4) are bitchat's only long-distance transport and have no `PeerCapabilities` gate; `courier drop`s (§5) are likewise REQUIRED, closing the forward reference the Store and Forward chapter's [§3.6](05-store-and-forward.md#36-nostr-relay-drop) already opened. `gateway` (§6) and `bridge` (§7) are each capability-gated and OPTIONAL to implement — a mesh-only implementation that advertises neither bit is fully conformant — but an implementation that advertises the `gateway` or `bridge` bit ([Payloads §5.1](04-payloads.md#51-peercapabilities-bitfield)) MUST implement that section's wire format and semantics exactly.

Not owned by this chapter: `nostrCarrier (0x28)`'s message-type value and the TLV-16 framing it uses ([§7](01-wire-format.md#7-message-types), [§8.2](01-wire-format.md#82-tlv-16) of the Wire Format chapter); the `privateMessage`, `delivered`, and `readReceipt` inner-payload shapes carried inside the private-envelope's embedded packet ([§3.2](04-payloads.md#32-private-message), [§4](04-payloads.md#4-delivery-and-read-acknowledgement) of the Payloads chapter); the `gateway`/`bridge` `PeerCapabilities` bits and the `bridgeGeohash` TLV slot on `announce` ([§5.1](04-payloads.md#51-peercapabilities-bitfield), [§2](04-payloads.md#2-presence-announce) of the Payloads chapter — this chapter defines `bridgeGeohash`'s value); the `courierEnvelope (0x04)` wire format, rotating recipient tag algorithm, deposit quotas, and spray-and-wait budget ([§3](05-store-and-forward.md#3-courier-envelopes) of the Store and Forward chapter — this chapter defines only how a courier envelope becomes a relay-hosted event).

## 1. Event Construction

Every event in this chapter is a standard NIP-01 Nostr event: `id` is the lowercase-hex SHA-256 of the canonical JSON array `[0, pubkey, created_at, kind, tags, content]` (`pubkey` lowercase-hex, `created_at` Unix seconds, `tags` an array of string arrays); `sig` is a 64-byte Schnorr signature (BIP-340) over `id`, verified against the 32-byte x-only `pubkey`. An implementation MUST reject an event whose `id` does not match its recomputed value or whose `sig` does not verify against `pubkey`.

The kinds this chapter defines:

| Kind | Name | Requirement | Content |
|---|---|---|---|
| 1 | `textNote` | REQUIRED (§3.2) | Plaintext geohash-scoped location note. |
| 5 | `deletion` | REQUIRED (§3.2) | Empty; deletes a self-authored `textNote` (NIP-09). |
| 13 | `seal` | REQUIRED (§2) | Encrypted `rumor`. |
| 14 | `dm` | REQUIRED (§2) | Plaintext (once decrypted): the rumor. |
| 1059 | `giftWrap` | REQUIRED (§2) | Encrypted `seal`. |
| 20000 | `ephemeralEvent` | REQUIRED (§3), OPTIONAL reuse (§7) | Plaintext geohash chat message, or (tagged `r` instead of `g`) a `bridge` rendezvous message. |
| 20001 | `geohashPresence` | REQUIRED (§3), OPTIONAL reuse (§7) | Empty; a geohash or (tagged `r`) `bridge`-cell presence heartbeat. |
| 1401 | `courierDrop` | REQUIRED (§5) | Base64 `courierEnvelope` wire bytes. |
| 0 | `metadata` | Reserved | Not used to construct any event in this specification. |

Kind 5, 13, 14, and 1059 reuse NIP-09's and NIP-17/NIP-59's kind numbers, and kind 13/14/1059's `content` construction reuses NIP-44's `nip44-v2` HKDF info label, but §2's envelope is **not** NIP-17-, NIP-44-, or NIP-59-compatible: it interoperates only with other bitchat clients, not with generic Nostr DM clients.

An implementation SHOULD bound inbound events defensively before processing: RECOMMENDED limits are 64 tags per event, 16 values per tag, and 1024 UTF-8 bytes per tag value.

## 2. Private Messages

A private message reaches a peer who is not reachable over the mesh, but whose Nostr public key is known (a mutual `favorite`, or a peer sharing the sender's current geohash channel), by riding a three-layer envelope over Nostr relays. Content is BitChat-specific and opaque to relays and to any non-bitchat Nostr client.

### 2.1 Envelope Layers

From innermost to outermost:

1. **Rumor** (kind `dm`, 14) — the unsigned inner event. `content` is the embedded bitchat packet (§2.3). `tags` MUST be empty; a decoder MUST also accept exactly one `["p", recipientPubkey]` tag (a historical encoder shape) and MUST reject any other tag shape. `sig` MUST be absent.
2. **Seal** (kind `seal`, 13) — the rumor, JSON-serialized and encrypted (§2.2) to the recipient, signed with the sender's own long-term Nostr identity key. `tags` MUST be empty. This is the layer that authenticates the sender: a decoder MUST verify the seal's signature and MUST treat its signer, not any claim inside the rumor, as the message's authenticated sender.
3. **Gift wrap** (kind `giftWrap`, 1059) — the seal, JSON-serialized and encrypted (§2.2) to the recipient using a fresh one-time key generated for this message alone, signed with that same one-time key. `tags` MUST be exactly `[["p", recipientPubkey]]`. The one-time signing key hides the sender's stable identity from relays and from any observer who is not the recipient.

The seal's and gift wrap's `created_at` are each independently randomized by up to ±15 minutes from the real send time (uniform, resampled per layer) so relay-visible timestamps do not correlate; the rumor's `created_at` carries the true send time and is recoverable only after both decryption steps.

A decoder MUST reject a gift wrap whose `content` exceeds 64 KiB before attempting decryption, and MUST apply the same bound to the decrypted seal `content` before parsing it as JSON, and again to the decrypted rumor.

### 2.2 Encryption

Both encrypted layers (seal→rumor, gift wrap→seal) use the same construction:

1. Compute an ECDH shared secret over secp256k1 between the layer's signing private key and the recipient's public key (the recipient's x-only Nostr pubkey, tried with an even-Y prefix and, on failure, an odd-Y prefix).
2. Derive a 32-byte key: `HKDF-SHA256(ikm = sharedSecret, salt = "", info = "nip44-v2", L = 32)`.
3. Generate a random 24-byte nonce. Seal the layer's canonical JSON with XChaCha20-Poly1305 under the derived key and nonce, producing ciphertext and a 16-byte authentication tag.
4. `content = "v2:" || base64url(nonce || ciphertext || tag)` (unpadded).

Decryption reverses this: strip and require the `v2:` prefix, base64url-decode, split into `nonce (24) || ciphertext || tag (16)`, and open. A decoder MUST reject a `content` value under 41 bytes (24 + 16 + 1) after the prefix is stripped, or lacking the `v2:` prefix at all.

### 2.3 Embedded BitChat Packet

The rumor's `content`, once decrypted, is not raw text: it is `"bitchat1:" || base64url(packetBytes)` (unpadded), where `packetBytes` is a complete `BitchatPacket` ([§2](01-wire-format.md#2-header-layout) of the Wire Format chapter) with:

- `type` = `noiseEncrypted (0x11)`.
- `signature` absent — the packet is unsigned, since the surrounding seal already authenticates the sender.
- `ttl` = `7`.
- `recipientID` = the recipient's 8-byte `peer ID` for a favorites DM, or absent for a message sent within a geohash channel's anonymous DM context.
- `payload` = a one-byte `NoisePayloadType` tag followed by that inner payload's bytes: `privateMessage (0x01)` ([§3.2](04-payloads.md#32-private-message) of the Payloads chapter) for message content, or `delivered (0x03)`/`readReceipt (0x02)` ([§4](04-payloads.md#4-delivery-and-read-acknowledgement) of the Payloads chapter) for an acknowledgement.

### 2.4 Sending and Reachability

An implementation SHOULD prefer a live mesh link and fall back to this chapter's private-message path only when the recipient is not reachable over the mesh but a Nostr public key for them is known and a relay connection to the default relay set (§4.1) is live. A courier drop (§5) is the further fallback when neither is available.

## 3. Geohash Public Channels

A geohash channel is a public, unencrypted chat room scoped to a geohash cell, letting peers beyond radio range converse regionally over Nostr relays.

### 3.1 Ephemeral Chat and Presence

A channel message is a kind `ephemeralEvent` (20000) event: `content` is the plaintext message; `tags` MUST include exactly one `["g", geohash]`, MAY include `["n", nickname]`, and MAY include `["t", "teleport"]` to mark a post made from outside the poster's physical geohash. A presence heartbeat is a kind `geohashPresence` (20001) event with empty `content` and `tags` = exactly `[["g", geohash]]` — no nickname or teleport tag.

### 3.2 Location Notes and Deletion

A persistent (non-ephemeral) location note is a kind `textNote` (1) event: `content` is the note text; `tags` MUST include exactly one `["g", geohash]`, MAY include `["n", nickname]`, MAY include `["expiration", unixSeconds]` (NIP-40, §8), and MAY include `["t", "urgent"]`. An author MAY retract a self-authored `textNote` with a kind `deletion` (5) event whose `tags` is exactly `[["e", noteEventID]]` and empty `content` (NIP-09); a relay honoring NIP-09 drops the referenced event, and a receiving client SHOULD do the same on receipt of a validly-signed deletion from the note's original author.

## 4. Relay Selection

### 4.1 Default Relay Set

Private messages (§2) and courier drops (§5) target a fixed default relay set. An implementation SHOULD use:

```
wss://relay.damus.io
wss://nos.lol
wss://relay.primal.net
wss://offchain.pub
```

merged with any user-added custom relays (RECOMMENDED cap: 8). An implementation SHOULD connect this set only when it has a reason to need it — a mutual favorite, a granted location permission, or an active geohash channel — rather than unconditionally on startup.

### 4.2 Geo-Proximity Relay Set

Geohash channel traffic (§3) and `bridge` rendezvous traffic (§7) instead target the relays nearest the relevant geohash cell: decode the geohash to a lat/lon center and select the `count` (RECOMMENDED: 5) relays with the smallest haversine distance to it, ties broken by hostname so publishers and subscribers agree on the same set. Relay coordinates come from a maintained directory (host, latitude, longitude); an implementation SHOULD source this directory from a reviewed, validated copy rather than trusting an unauthenticated third-party feed directly at fetch time, and SHOULD validate a refreshed copy (bounded size, valid coordinate ranges, a minimum-overlap check against the previous copy) before replacing what it already has.

### 4.3 Private-Message Subscription

A client subscribes for gift wraps (kind 1059) addressed to each Nostr identity it holds (its stable favorites identity, and any per-geohash identity for an open channel), filtered by the `p` tag equal to that identity's pubkey. An implementation SHOULD subscribe with a lookback window (RECOMMENDED: 24 hours) from the current time on every (re)connect, so a client that was offline still retrieves mail waiting on relays.

## 5. Courier Drops

A courier drop parks a sealed `courier envelope` ([§3](05-store-and-forward.md#3-courier-envelopes) of the Store and Forward chapter) on relays so its delivery does not require a physical courier encounter, closing the Nostr Relay Drop path that chapter's [§3.6](05-store-and-forward.md#36-nostr-relay-drop) opens. Every conformant implementation MUST support both depositing and retrieving courier drops.

A drop is a kind `courierDrop` (1401) event: `content` is the base64 encoding (standard alphabet, padded) of the courier envelope's own wire-encoded bytes ([§3.1](05-store-and-forward.md#31-wire-format) of the Store and Forward chapter — the full TLV-16 packet payload, not just its `ciphertext` field); `tags` MUST include exactly one `["x", recipientTagHex]` (the envelope's `recipientTag`, lowercase hex) and exactly one `["expiration", unixSeconds]` (NIP-40, §8) matching the envelope's `expiry`. A depositor MUST sign each drop with a fresh, single-use Nostr identity rather than a stable per-device key, so relay observers cannot correlate drops from the same publisher across messages.

A drop targets the default relay set (§4.1). A recipient (or a `gateway`/`bridge` peer retrieving on a mesh-only peer's behalf) subscribes for kind `courierDrop` events tagged with any of its own candidate recipient tags for `epochDay − 1`, `epochDay`, and `epochDay + 1` ([§3.2](05-store-and-forward.md#32-rotating-recipient-tag) of the Store and Forward chapter), and, on a match, decodes `content` back into a `courierEnvelope` and verifies its own computed `recipientTag` matches the event's `x` tag before treating it as addressed to it — an event's tag is untrusted routing metadata, not proof of addressing. An expired envelope (by the enclosed `courierEnvelope`'s own `expiry`, not just the event's NIP-40 `expiration`) MUST be discarded rather than opened or forwarded.

## 6. Gateway

`gateway` is an OPTIONAL, capability-gated service (`PeerCapabilities` bit 2, [§5.1](04-payloads.md#51-peercapabilities-bitfield) of the Payloads chapter): a device with both mesh and internet connectivity that lets mesh-only peers reach a geohash channel (§3) by relaying between the two. An implementation MUST NOT advertise the `gateway` bit unless it implements this section's wire format and semantics exactly.

### 6.1 `NostrCarrierPacket` Wire Format

`nostrCarrier (0x28)`'s payload is a [TLV-16](01-wire-format.md#82-tlv-16) sequence:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `direction` | 1 | One of the values below. REQUIRED. |
| 0x02 | `geohash` | 1–12, UTF-8 | The channel or cell this event belongs to. REQUIRED. |
| 0x03 | `eventJSON` | 1–16384 | The complete signed Nostr event, JSON-encoded. REQUIRED. |

`direction` values:

| Value | Name | Used By |
|---|---|---|
| 0x01 | `toGateway` | §6.2 |
| 0x02 | `fromGateway` | §6.3 |
| 0x03 | `toBridge` | §7.2 |
| 0x04 | `fromBridge` | §7.3 |

A decoder MUST reject a `direction` byte outside `0x01`–`0x04`. This is deliberate: a decoder that predates `bridge` support (§7) fails to decode a `0x03`/`0x04` carrier and drops it, so `bridge` traffic degrades to invisible on an old client rather than being misrouted. A decoder MUST independently re-verify `eventJSON`'s signature after decoding — the carrier itself carries no trust, only transport.

### 6.2 Uplink (mesh → relay)

A mesh-only peer composing a geohash event it cannot publish directly (no live relay connection) MAY send a `toGateway` carrier as a directed packet to a known gateway peer. On receipt, a gateway:

1. Structurally validates the carried event (parses, checks size, confirms `event.kind == ephemeralEvent (20000)`, confirms a `["g", geohash]` tag matches the carrier's `geohash` field, checks freshness — RECOMMENDED: reject anything older than 15 minutes) before any signature check.
2. Rejects a duplicate of an event it has already published, queued, or learned from the mesh (§6.4).
3. Applies a per-depositor rate limit (RECOMMENDED: 10 accepted deposits per depositor per minute) before paying for signature verification.
4. Verifies the event's signature (§1); rejects on failure.
5. Publishes immediately if a relay connection is live, or holds the event in a bounded per-depositor queue (RECOMMENDED: 20 total, 5 per depositor, oldest evicted first) until one is.

### 6.3 Downlink (relay → mesh)

Every event a gateway's own geohash subscription delivers, it MAY rebroadcast onto the mesh as a broadcast `fromGateway` carrier, gated the same way as uplink (freshness, the event's own `g` tag matching, loop prevention per §6.4, signature verification) and rate-limited (RECOMMENDED: 30 rebroadcasts per minute, with a bounded drop-oldest queue beyond that budget).

### 6.4 Loop Prevention

A gateway MUST enforce all of the following, so that mesh-carried traffic is never re-injected onto the relay network or echoed back onto the mesh it came from:

1. An event learned from a `fromGateway` mesh broadcast MUST NOT be re-published to relays, re-uplinked, or rebroadcast.
2. An event this gateway has already published (via uplink) MUST NOT subsequently be rebroadcast (via downlink) even if the gateway's own relay subscription redelivers it; a given event MUST NOT be published more than once, nor rebroadcast more than once.
3. Uplink MUST be attempted only for a locally-composed event — an event received over a carrier or from a relay subscription MUST NOT itself trigger a further uplink.

## 7. Bridge

`bridge` is an OPTIONAL, capability-gated service (`PeerCapabilities` bit 7, [§5.1](04-payloads.md#51-peercapabilities-bitfield) of the Payloads chapter) distinct from `gateway`: it stitches together disjoint BLE mesh islands that share a physical place but have no direct radio path between them, by routing public mesh traffic through Nostr as a rendezvous. An implementation MUST NOT advertise the `bridge` bit unless it implements this section's wire format and semantics exactly.

### 7.1 Rendezvous Cell and Events

A peer's rendezvous cell is its current geohash truncated to precision 6 (~1.2 km); this is the value an `announce`'s `bridgeGeohash` TLV ([§2](04-payloads.md#2-presence-announce) of the Payloads chapter) carries when advertising `bridge`. A rendezvous message reuses kind `ephemeralEvent` (20000) with `tags` = `[["r", cell]]` (optionally `["n", nickname]`) instead of a `g` tag — keeping bridge traffic out of geohash-channel (§3) subscriptions, which filter on `#g`. A rendezvous message MAY additionally carry `["m", [stableID, meshSenderIDHex, meshTimestampMs]]`, an unauthenticated hint correlating the event to a specific mesh-originated packet; a receiver MUST NOT treat a `m`-tag match alone as authenticating a message (§7.3). A rendezvous presence heartbeat reuses kind `geohashPresence` (20001) with `tags` = `[["r", cell]]` and empty `content`.

Signing identity for rendezvous events is per-cell and SHOULD be distinct from a peer's geohash-channel and favorites identities, so relay observers cannot link a bridge participant to their geohash-channel activity from key reuse alone.

### 7.2 Publishing (mesh → relay)

A device with `bridge` enabled additionally signs every public mesh message it sends as a rendezvous event (§7.1) and either publishes it directly to the geo-proximity relay set for its cell (§4.2), or, if mesh-only, deposits it as a directed `toBridge` carrier (§6.1's structure, `direction = toBridge`) to a peer serving as a bridge gateway. A per-message flag MAY suppress composing the rendezvous copy for a message the sender knows is only relevant locally.

### 7.3 Receiving and the Radio Race

A `bridge`-enabled device subscribed to its cell (and, RECOMMENDED, its immediate geohash neighbors) that receives a rendezvous event: verifies the event's own signature and that its `r` tag is within its subscribed cell set; classifies it (by kind) as a presence heartbeat or a message; and injects it into the mesh timeline marked as bridged. A device also serving that mesh island (`bridge` and internet both available) additionally rebroadcasts genuine remote rendezvous events onto the local mesh as `fromBridge` carriers (§6.1's structure, `direction = fromBridge`), subject to the same loop-prevention rules as §6.4 applied to `toBridge`/`fromBridge` in place of `toGateway`/`fromGateway`. A `fromBridge` carrier MUST be accepted for injection regardless of whether the local device has `bridge` enabled — reception is passive, unlike publishing and serving.

An authenticated radio-received copy of a message (heard directly over the mesh) MUST take precedence over a bridge-relayed row that only matched on the untrusted `m`-tag hint (§7.1): if a radio copy of a message arrives after a bridge-sourced row for the same content, the receiver MUST replace the bridge row with the authenticated one rather than displaying both. The `m` tag MAY be used to merge a duplicate but MUST NOT be used to suppress delivery of the genuine signed event.

## 8. Expiration and Deletion

`["expiration", unixSeconds]` (NIP-40) marks an event for relay-side garbage collection once relays observe the given Unix timestamp has passed; this chapter uses it on courier drops (§5, REQUIRED) and MAY use it on location notes (§3.2). A relay's honoring of NIP-40 is a hygiene measure, not a delivery guarantee — a receiving client MUST independently discard an expired courier envelope regardless of whether the hosting relay has (§5).

`["e", eventID]` on a kind `deletion` (5) event (NIP-09) requests removal of one self-authored event; a client MUST sign a deletion with the same key that signed the original event, and a receiving client honoring a deletion MUST verify that signature match before acting on it.
