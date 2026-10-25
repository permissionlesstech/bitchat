# Store and Forward

This chapter covers how bitchat delivers a message to a peer who is not reachable right now: the BLE mesh's controlled-flood relay policy, the sender's own retry queue for private messages, the `courier envelope` mailbag that lets a third device carry sealed mail, and `gossip sync`, the periodic reconciliation that lets a peer catch up on public broadcast history it missed.

Not owned by this chapter: the source-route byte layout (Wire Format chapter [§4.2](01-wire-format.md#42-source-route)), the Noise `X` pattern used to seal a courier envelope's `ciphertext`, the sealing-to-a-prekey variant, and the `prekeyBundle (0x24)` packet itself ([§4](03-noise.md#4-offline-seals-the-x-pattern), [§4.3](03-noise.md#43-prekey-envelopes), and [§5](03-noise.md#5-prekey-bundles) of the Noise chapter, respectively), the inner payload field catalogs for messages the mechanisms here carry unopened (Payloads chapter), the `announce (0x01)` payload including its `directNeighbors` TLV ([§2](04-payloads.md#2-presence-announce) of the Payloads chapter), and the board post signing/tombstone/expiry model ([§6](04-payloads.md#6-board-posts) of the Payloads chapter). This chapter's own wire types are `courierEnvelope (0x04)` and `requestSync (0x21)` (see the Wire Format chapter's [Message Types](01-wire-format.md#7-message-types)). The Nostr-relay publish path a courier envelope may additionally take, and the NIP-level event encoding it uses, are specified in the Nostr Bridge chapter; this chapter defines only the store-and-forward-relevant parameters of that path (§3.6).

## 1. Mesh Relay and Flood Control

A `bitchat packet` reaches peers beyond direct radio range by controlled flooding: each relay that receives a packet not addressed to itself decides whether, and to whom, to re-send it. This section defines that decision.

### 1.1 Suppression

A relay MUST NOT re-send a packet it authored itself, a packet whose `recipientID` matches its own `peer ID`, or a packet whose `ttl` is `0` or `1` after decrement. A `requestSync (0x21)` packet MUST NEVER be relayed, regardless of its `ttl`: it is defined ([§4](#4-gossip-sync)) as link-local between the two ends of a single connection, and relaying it would let a crafted request replay a full sync round onto a next hop that never asked for one.

A relay SHOULD deduplicate packets it has already relayed, keyed by sender, timestamp, type, and payload, over a bounded recent-history window (RECOMMENDED: 1000 entries, 5-minute expiry) so redundant copies arriving from different neighbors after the first are dropped rather than re-flooded.

### 1.2 TTL

A packet's `ttl` field ([§2](01-wire-format.md#2-header-layout)) is set by its originator and decremented by each relay. The default originating `ttl` is `7` hops. A relay MAY clamp the `ttl` it forwards with below the incoming value, tuned to local connection degree (the number of currently connected links):

| Degree | Clamp |
|---|---|
| ≤ 2 (thin chain) | No clamp — relay at the full incoming depth; every hop matters and flood cost is minimal. |
| 3–5 | Clamp to 6 hops (7 for `announce` and an urgent `boardPost`). |
| ≥ 6 (dense) | Clamp to 5 hops. |

These thresholds are RECOMMENDED defaults for congestion control, not a cross-platform contract — an implementation MAY tune them without affecting interop, since every relay applies its own clamp independently and a receiver's decoding does not depend on which clamp the last hop used.

### 1.3 Fanout Subsetting

A broadcast packet (no `recipientID`) that is not a `fragment`, `announce`, or `requestSync` is, by default, **not** relayed to every connected link. A relay SHOULD instead select a deterministic pseudo-random subset of its links:

1. Start from every connected link, minus the link the packet arrived on (split horizon) and any explicitly excluded link. Where more than one link is bound to the same peer, collapse them to one.
2. If the resulting link count `n` is ≤ 2, the subset is all of them.
3. Otherwise the subset size is `k = bitlength(n − 1) + 1` (equivalently `⌈log₂ n⌉ + 1`, clamped to `[1, n]`).
4. For each candidate link `id`, compute `SHA-256("{messageID}::{id}")`. Sort candidates by this digest (ties broken by `id`) and keep the `k` lowest.

`fragment`, `announce`, and `requestSync` packets bypass subsetting and go to every allowed link: fragments need every link a large transfer might be split across, announces bind links to peers and are already rate-limited, and `requestSync` is never relayed at all ([§1.1](#11-suppression)).

### 1.4 Directed Delivery

A packet with a single-peer `recipientID` is delivered, in order of preference:

1. **Direct link.** If a link is already bound to the recipient's `peer ID`, the packet goes only to that link.
2. **Source route.** Otherwise, the sender MAY attach a v2 [source route](01-wire-format.md#42-source-route) instead of falling back to flooding. A relay that receives a packet carrying a source route follows it hop-by-hop: it looks up its own `peer ID` in the route, forwards to the next entry (or to the packet's `recipientID` if it is the last entry), and decrements `ttl`. If the computed next hop is not currently connected, the relay falls back to flood relay rather than dropping the packet.
3. **Flood.** Otherwise the packet is relayed per [§1.2–1.3](#12-ttl).

### 1.5 Source-Route Origination Policy

An implementation MAY originate a v2 source route on a packet it authors. This chapter does not mandate that an implementation do so, but a conformant implementation that does MUST gate origination on all of the following, so that route attachment never produces an undeliverable or mis-signed packet:

- The packet is authored locally (a relay MUST NOT attach or alter a route on a packet it did not originate — that would invalidate the original signature).
- The packet has a single-peer `recipientID`.
- `ttl > 1`.
- The recipient is not already directly connected (a direct link already delivers in one hop).
- A complete path to the recipient is known, where every intermediate hop and the recipient have been observed speaking the v2 packet version — a v1-only peer cannot decode a v2 frame, so routing through one would silently drop the packet.

A relay SHOULD track per-recipient route health: if a routed send sees no inbound packet from that recipient within 10 seconds, subsequent directed sends toward it SHOULD fall back to flooding for 60 seconds before a route is attempted again.

## 2. Sender Outbox

The `sender outbox` is the persistent, per-peer retry queue for a private message the sender could not deliver promptly. An implementation MUST NOT discard such a message outright; it MUST be retained and retried as the recipient becomes reachable, until one of the following ends its wait: a `delivered (0x03)` or `readReceipt (0x02)` acknowledgement arrives ([§4](04-payloads.md#4-delivery-and-read-acknowledgement) of the Payloads chapter), or the message is dropped per the limits below.

RECOMMENDED limits: 100 queued messages per peer (oldest evicted first), a 24-hour retention TTL, and a cap of 8 retried send attempts before the message is dropped with a visible failure to the user. While queued, a message SHOULD also be offered to eligible couriers ([§3](#3-courier-envelopes)); a RECOMMENDED cap of 3 distinct couriers per message bounds how widely a single queued message spreads.

The outbox holds plaintext message content pending delivery, not wire-encoded packets. An implementation SHOULD persist it across restarts under encryption at rest, since it otherwise holds undelivered private content only the sender has seen.

## 3. Courier Envelopes

A `courier envelope` lets a message reach a recipient who is not reachable by any live transport, by handing a sealed, opaque copy to another device that may physically encounter the recipient later. The envelope's ciphertext is produced by the Noise `X` seal defined in the Noise chapter's [§4](03-noise.md#4-offline-seals-the-x-pattern); a courier that carries an envelope cannot decrypt it and learns neither the sender, the recipient, nor the content.

### 3.1 Wire Format

A `courierEnvelope (0x04)` packet's payload is a [TLV-16](01-wire-format.md#82-tlv-16) sequence:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `recipientTag` | 16 | Rotating recipient tag ([§3.2](#32-rotating-recipient-tag)). REQUIRED. |
| 0x02 | `expiry` | 8 | Milliseconds since epoch, big-endian, after which the envelope MUST be discarded. REQUIRED. |
| 0x03 | `ciphertext` | 1–16384 | The Noise `X`-sealed message. REQUIRED. |
| 0x04 | `copies` | 1 | Remaining spray-and-wait copy budget ([§3.4](#34-spray-and-wait)), 1–8. OPTIONAL — a decoder that does not find this TLV MUST treat the envelope as `copies = 1` (carry-only). |
| 0x05 | `prekeyID` | 4 | Big-endian identifier of the one-time `prekey` this envelope was sealed to (see the Noise chapter's [§4.3](03-noise.md#43-prekey-envelopes)). OPTIONAL — present only for a forward-secret seal; absent for a static-key seal. |

A decoder MUST reject an envelope missing `recipientTag`, `expiry`, or `ciphertext`, or whose `ciphertext` exceeds 16384 bytes. `copies` and `prekeyID` are each encoded only when their value needs stating (`copies` is omitted when it equals `1`; `prekeyID` is omitted for a static-key seal), so a static-sealed, unsprayed envelope stays byte-identical whether or not the sender or courier supports spraying or forward secrecy.

### 3.2 Rotating Recipient Tag

`recipientTag` is the only routing information a courier envelope carries. It is computed as:

```
epochDay   = floor(unixSeconds / 86400)
recipientTag = HMAC-SHA256(recipientNoiseStaticKey, "bitchat-courier-tag-v1" || epochDay)[0..16]
```

where `epochDay` is encoded as a big-endian 32-bit integer appended to the ASCII context string before hashing. The tag is therefore computable only by a party that already knows the recipient's Noise `static key` — the same key an `announce` publishes in cleartext — and it rotates once per UTC day, so envelopes addressed to the same recipient on different days do not correlate for a courier or observer who does not hold that key.

Because envelopes may be sealed and carried across a day boundary, a party checking whether an envelope is addressed to a given recipient MUST test the candidate tags for `epochDay − 1`, `epochDay`, and `epochDay + 1` (evaluated at check time), not only the current day's tag.

### 3.3 Deposit Policy and Trust Tiers

A device accepting a courier envelope deposit from another peer classifies the depositor into a `trust tier`: **favorite** (a mutual `favorite`) or **verified** (any peer with a signature-verified `announce`, but not a mutual favorite). The tier bounds how much mail that depositor may place:

| Limit | Value |
|---|---|
| Total envelopes carried | 40 |
| Verified-tier share of the total | ≤ 20 |
| Per-favorite-depositor quota | 5 |
| Per-verified-depositor quota | 2 |
| Envelope lifetime cap (`expiry` beyond deposit time) | 24 hours + 1 hour clock-skew slack |

A deposit that would exceed the depositor's per-tier quota MUST be rejected. When the total cap is reached, an implementation MUST evict oldest-first, evicting verified-tier envelopes before any favorite-tier envelope; a verified-tier deposit MUST be rejected outright, never displacing favorite-tier mail, once only favorite-tier envelopes remain. This ordering means a crowd of unfavorited, merely-verified peers can still carry mail for each other, but can never crowd out a mutual favorite's queued messages.

A depositor SHOULD re-offer a queued message to a newly-encountered eligible courier until it has been accepted by up to 3 distinct couriers or the message expires ([§2](#2-sender-outbox)).

### 3.4 Spray-and-Wait

An envelope carries a `copies` budget (RECOMMENDED initial value: 4, hard cap: 8) governing how far it may diffuse between couriers before it must simply wait to meet the recipient. When one courier encounters another eligible courier (not the recipient), it MAY offer each envelope it still has spray budget for, splitting the offered copy's remaining budget in half (`copies / 2`, minimum 1) between the two couriers. An envelope with `copies = 1` is carry-only and MUST NOT be sprayed further. A courier MUST NOT spray the same envelope to a peer it has already sprayed it to, so a given envelope sprays to each courier along its path at most once and the total copies in flight for it never exceeds its original depositor's budget.

### 3.5 Handover

When a courier verifies a peer's `announce` as the envelope's recipient:

- On a **direct** announce (the recipient is the peer that just connected), the courier hands over every matching envelope on the live link and removes it from local storage. This handover is non-destructive at the offer stage: an envelope is removed only after the transport confirms it was actually delivered onto the link, so a failed send leaves it intact for the next encounter.
- On a **relayed** announce (heard via a multi-hop relay, not a direct connection), the courier MAY speculatively flood a copy toward the recipient as a directed packet, while the carried original stays in storage — a routed multi-hop send is not a delivery guarantee. This SHOULD be rate-limited per envelope (RECOMMENDED: at most once per 10 minutes) so repeated relayed announces don't re-flood the same mail.

A receiver deduplicates delivered messages by `messageID` ([§3.2](04-payloads.md#32-private-message) of the Payloads chapter), so redundant copies arriving via multiple couriers, or alongside the sender's own retained outbox original, are harmless.

### 3.6 Nostr Relay Drop

A courier envelope MAY additionally be parked on Nostr relays so its delivery does not require a physical courier encounter with the recipient. This chapter defines only the store-and-forward-relevant shape of that path; the event kind, tag structure, and relay-selection criteria are defined in the Nostr Bridge chapter.

A device offering this path SHOULD bound it: a RECOMMENDED cap of 20 pending drops (oldest evicted first), a per-envelope republish cooldown of 30 minutes, and an encoded-drop size cap of 20 KiB (the 16 KiB `ciphertext` limit plus TLV and envelope overhead). Each publish SHOULD use a fresh, throwaway signing key rather than a stable per-device key, so a passive relay observer cannot fingerprint courier traffic to a single publisher across drops. A publish is not considered complete — and MUST NOT be treated as freeing the local pending-drop slot — until the relay acknowledges it (a NIP-01 `OK`), not merely once it has been written to a socket.

## 4. Gossip Sync

`gossip sync` reconciles the cache of recently-seen **broadcast** (unencrypted, flooded) packets between two directly connected peers, so a peer that missed messages — because it just joined, walked between two partitions of the mesh, or was offline — can catch up from a peer that has them. It is a distinct mechanism from courier envelopes: gossip sync never carries a `courierEnvelope`, and a courier envelope is never a candidate for gossip sync ([§4.5](#45-cache-scope-and-retention)).

### 4.1 REQUEST_SYNC Payload

A `requestSync (0x21)` packet's payload is a [TLV-16](01-wire-format.md#82-tlv-16) sequence:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `p` | 1 | Golomb-Rice parameter of the filter in `data`. REQUIRED, 1–32. |
| 0x02 | `m` | 4 | Hash-bucket modulus, big-endian. REQUIRED, > 0. |
| 0x03 | `data` | variable | Golomb-coded set (GCS) filter bitstream ([§4.2](#42-golomb-coded-set-filter)). REQUIRED. |
| 0x04 | `types` | 1–8 | Bitfield of which message types this round covers ([§4.5](#45-cache-scope-and-retention)). OPTIONAL — a decoder that finds this TLV absent MUST treat the request as covering `announce` and `message` only. |
| 0x05 | `sinceTimestamp` | 8 | Milliseconds since epoch, big-endian. OPTIONAL cursor: the filter in `data` only covers candidates at or after this timestamp; older matching packets are outside the filter but not missing, and MUST NOT be treated as such. |
| 0x06 | `fragmentIdFilter` | variable, UTF-8 | Comma-separated, lowercase-hex-encoded 8-byte fragment stream IDs (at most 60), narrowing a `fragment`-type round to exactly the named stalled reassembly streams. OPTIONAL. |

A `requestSync` packet MUST be sent with `ttl = 0`: it is never relayed ([§1.1](#11-suppression)), so a `ttl` budget beyond the immediate link is meaningless. `p`, `m`, and `data` are always present, even for an empty cache (`p` derived per [§4.2](#42-golomb-coded-set-filter), `m = 1`, `data` empty), so the recipient can distinguish "nothing to report" from a malformed request. A decoder MUST reject `p > 32` or `m = 0`.

### 4.2 Golomb-Coded Set Filter

The `data` field is a Golomb-coded set: a compact, probabilistic membership filter over the requester's known packet IDs, letting the responder compute what the requester is missing without transmitting every ID it already holds.

A packet's ID, for gossip-sync purposes, is the first 16 bytes of `SHA-256(type || senderID || timestamp || payload)` (`type` as its single byte, `timestamp` big-endian). To place a 16-byte ID into the filter:

1. Hash it: `h = first 8 bytes of SHA-256(id)`, interpreted as a big-endian 63-bit unsigned integer (the top bit is cleared).
2. Map it into `[1, m)`: `bucket = h mod m`; if the result is `0`, remap it to `1` — every bucket value in the filter is therefore in `[1, m − 1]`, keeping every encoded delta strictly positive.

To build the filter, the sender sorts its buckets ascending, deduplicates equal values, and Golomb-Rice encodes the sequence of successive deltas `x ≥ 1` (the first delta is the value itself, taken from an implicit zero): each delta is split into a quotient `q = (x − 1) >> p` and a `p`-bit remainder `r = (x − 1) & ((1 << p) − 1)`; `q` is written as that many `1` bits followed by a `0` bit (unary), then `r` follows as `p` bits. The bitstream is packed MSB-first within each byte, with the final byte's unused low bits set to `0`.

To test whether a 16-byte ID is a member, a decoder computes its `bucket` per step 2 above (using the filter's own `m`) and binary-searches the filter's decoded, sorted bucket list — decoded by reading each delta back off the bitstream (unary quotient, then `p`-bit remainder, reconstructing `x`, and accumulating `x` onto a running sum) until the running sum reaches or exceeds `m`.

`p` SHOULD be derived from a target false-positive rate `f` as `p = ⌈log₂(1/f)⌉`, clamped to `[1, 32]` (a target of 1% yields `p = 7`). `m` is fixed to the candidate count at encode time (scaled by `2^p`) and stays fixed even if the encoder must trim candidates to fit a byte budget, so `m` alone does not reveal how many candidates the filter actually reached — a responder relies on `sinceTimestamp` ([§4.1](#41-request_sync-payload)) for that.

### 4.3 Sync Rounds

A peer SHOULD request a sync round from each newly connected peer shortly after connecting (RECOMMENDED delay: 1–5 seconds), covering every type it tracks ([§4.5](#45-cache-scope-and-retention)).

Beyond the initial round, a peer SHOULD run a periodic sync round per message-type group against every currently connected peer (unicast to each; broadcast only if none are connected yet), at a RECOMMENDED cadence tuned to how time-sensitive that type is:

| Type group | RECOMMENDED interval |
|---|---|
| `announce` + `message` (+ `groupMessage`, where supported) | 15 s |
| `fragment` | 30 s |
| `fileTransfer` | 60 s |
| `boardPost` | 60 s |
| `prekeyBundle` (see the Noise chapter's [§5](03-noise.md#5-prekey-bundles)) | 60 s |

A peer whose `fragment` reassembly has stalled (no new fragment for its stream in 30 seconds, per the BLE Transport chapter's [§3.2](02-ble-transport.md#32-fragment-cap-and-lifetime)) SHOULD send a targeted round immediately, using the `fragmentIdFilter` TLV to name only the stalled stream IDs, rather than waiting for the next periodic `fragment` round.

### 4.4 Responses and the RSR Flag

A responder answering a `requestSync` walks its cache of the requested type(s), tests each candidate packet's ID against the requester's filter ([§4.2](#42-golomb-coded-set-filter)), and re-sends every packet that tests as **not present** in the filter — i.e., every packet the filter indicates the requester is missing. Each such response:

- Is sent as the packet's own original type (`message`, `announce`, `fragment`, `fileTransfer`, `groupMessage`, `prekeyBundle`, or `boardPost`) — there is no separate response packet type.
- MUST have `ttl = 0`: a sync response is a direct answer to the requester, not something for the requester to further relay.
- MUST have the `isRSR` flag ([§3](01-wire-format.md#3-flags) of the Wire Format chapter) set, marking it a solicited **Request-Sync Response** rather than an unprompted broadcast.

`announce` and `prekeyBundle` responses are exempt from the `sinceTimestamp` cursor: there is at most one live packet of each per owner, so resending it whenever the filter doesn't already cover it is cheap and lets a peer joining long after a bundle was published still learn it.

A peer that sent a `requestSync` treats an inbound `isRSR`-flagged packet from a given sender as attributable to its own request only within a bounded window after sending it (RECOMMENDED: 30 seconds); an `isRSR` packet arriving outside that window, or from a peer it never asked, SHOULD be treated as unsolicited. A responder SHOULD also rate-limit how many sync rounds it answers for a single requester in a short window (RECOMMENDED: 8 responses per 30 seconds) so a rapid burst of requests cannot be used to repeatedly replay a peer's whole cache.

### 4.5 Cache Scope and Retention

Gossip sync covers exactly the broadcast types a `types` bitfield can name: `announce`, `message`, `fragment`, `fileTransfer`, `boardPost`, `prekeyBundle`, and `groupMessage`. It MUST NOT cover `courierEnvelope` (a directed deposit between trusted peers, never gossiped), `ping`/`pong` (ephemeral directed probes), `nostrCarrier` (ephemeral gateway traffic), `voiceFrame` (live audio, useless once stale), `noiseHandshake`/`noiseEncrypted` (session-bound, not broadcast), or `requestSync` itself.

A peer tracks each covered type in a separate bounded, time-windowed cache:

| Type | RECOMMENDED capacity | RECOMMENDED age window |
|---|---|---|
| `message` | 1000 | A long window (RECOMMENDED: 6 hours) so a device that reconnects after a partition still serves recent public chat history. |
| `groupMessage` | 200 | Shares `message`'s long window — a member catching up after time off-mesh should backfill group history the same way. |
| `announce` | One retained per known peer (no shared pool cap) | 15 minutes |
| `fragment` | 600 | 15 minutes |
| `fileTransfer` | 200 | 15 minutes |
| `boardPost` | 200 | No independent window — a board post ages out only via its own signed expiry/tombstone ([§6](04-payloads.md#6-board-posts) of the Payloads chapter). |
| `prekeyBundle` | 200 | 24 hours |

A device SHOULD persist its `message` cache across restarts (so a relaunching device still has recent public history to serve) but MAY keep the shorter-lived caches (`fragment`, `fileTransfer`) in memory only.

## 5. Delivery Metrics

An implementation MAY keep bare local counters of store-and-forward activity — for example, deposits, handovers, sprays, and outbox flushes or drops — to let delivery behavior be measured on-device. Such counters MUST NOT record message IDs, peer identities, or timestamps, and MUST NOT be transmitted off the device. They are cleared by a `panic wipe` along with the rest of this chapter's persisted state (the `sender outbox`, carried `courier envelope`s, and the gossip-sync cache).
