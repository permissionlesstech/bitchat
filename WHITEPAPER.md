# bitchat Protocol Whitepaper

**Version 2.0**

**Date: July 6, 2026**

> A normative, byte-level protocol specification is being drafted in [`spec/`](spec/README.md). As each spec chapter lands, this document is trimmed of the byte-exact detail that chapter now owns, in favor of a cross-link to it; this whitepaper remains the architecture and design-goals overview.

---

## Abstract

bitchat is a decentralized, peer-to-peer messaging application for secure, private, censorship-resistant communication that works with or without the internet. Nearby devices form an ad-hoc Bluetooth Low Energy (BLE) mesh; distant peers are reached over the Nostr protocol when a connection exists. A layered store-and-forward stack — a persistent sender outbox, opportunistic couriers with a spray-and-wait copy budget, gossip-synced public history, and Nostr relay mailboxes — delivers messages to peers who are out of range at send time. This document describes the protocol and its delivery guarantees as implemented.

---

## 1. Design Goals

* **Confidentiality:** all private communication is end-to-end encrypted; intermediate nodes and couriers carry only opaque ciphertext.
* **Authentication:** peers are identified by cryptographic keys; announcements are signed and verified.
* **Resilience:** the network functions in lossy, low-bandwidth, partitioned environments with churning membership.
* **Eventual delivery:** a message to an out-of-range peer should still arrive — relayed by the mesh, carried by a moving person, or resting on an internet relay — within a bounded retention window.
* **Ephemerality by default:** conversation timelines live in memory only. Everything the store-and-forward stack persists is either sealed ciphertext or already-public broadcast traffic, and all of it dies with the panic wipe. Media is the exception: accepted images and voice notes are written to disk unsealed, protected by the platform's data-protection class rather than by app-layer encryption, and bounded by a storage quota.

## 2. Architecture Overview

Two transports implement a common `Transport` interface and are coordinated by a `MessageRouter`:

* **BLE mesh** — every device is simultaneously a GATT central and peripheral, relaying packets in a controlled flood. No infrastructure, pairing, or accounts.
* **Nostr** — private messages to mutual favorites travel in BitChat's app-specific encrypted envelopes over public relays (over Tor where enabled), bridging separate meshes through the internet.

The router prefers a live mesh link, falls back to Nostr, and engages the courier system when neither can deliver promptly.

## 3. Identity

Each device holds two long-term key pairs in the Keychain:

* a **Curve25519 static key** for Noise key agreement — its SHA-256 fingerprint is the peer's stable identity, and
* an **Ed25519 signing key** for packet signatures.

On the mesh, peers appear under a short 8-byte peer ID. That ID is **not ephemeral**: it is the first 8 bytes of the SHA-256 fingerprint of the device's Noise static key, so it is stable across sessions, reboots, and reinstalls that preserve the keychain, and it changes only when the identity itself is replaced by a panic wipe. Favoriting pins the full Noise public key so identity survives across sessions. Mutual favorites also exchange Nostr public keys for the internet path. Optional QR verification binds a nickname to a fingerprint in person.

Signed announcements additionally carry the nickname, the Noise static public key, and the Ed25519 signing public key in cleartext (§4.5), so a passive receiver in radio range can link a device across time and place regardless of the peer ID. Unlinkable presence is not a property this protocol currently provides; see §9.

## 4. BLE Mesh Layer

### 4.1 Packet Format

The packet header, byte offsets, flags, TLV encodings, and padding scheme are specified byte-exactly in [Wire Format](spec/01-wire-format.md).

### 4.2 Flood Control

The TTL/degree clamp, deduplication, jitter, and fanout-subsetting policy that governs mesh relaying are specified in [Store and Forward](spec/05-store-and-forward.md).

### 4.3 Routing

Announcements carry up to 10 direct-neighbor IDs, giving each node a shallow topology map (60 s freshness); this TLV is specified byte-exactly in [Payloads](spec/04-payloads.md). The policy for when a packet is source-routed along a known path versus falling back to flooding is specified in [Store and Forward](spec/05-store-and-forward.md).

### 4.4 Fragmentation

The GATT service/characteristic, MTU-driven chunk sizing, fragment header layout, and advertising behavior are specified byte-exactly in [BLE Transport](spec/02-ble-transport.md).

### 4.5 Presence

Signed announcements propagate multi-hop: every 4 s while isolated, backing off to ~15–30 s (jittered) when connected. A verified announce retains a peer as *reachable* for 60 s after last contact. Connection scheduling is RSSI-gated with duty-cycled scanning to bound battery drain.

## 5. Encryption

### 5.1 Live Sessions: Noise XX

The `XX` handshake pattern, its message sequence, and the post-handshake transport and application-payload framing are specified byte-exactly in [Noise](spec/03-noise.md).

### 5.2 Offline Seals: Noise X

The one-way `X` pattern used to seal courier envelopes — including the forward-secret prekey variant — is specified byte-exactly in [Noise](spec/03-noise.md).

### 5.3 Nostr Path

The private-message envelope — its `gift wrap`/`seal`/`rumor` layers, encryption, and embedded packet — is specified byte-exactly in [Nostr Bridge](spec/06-nostr-bridge.md).

## 6. Store and Forward

Four mechanisms cover the "recipient is not here right now" problem. All persisted state is wiped by panic mode.

### 6.1 Sender Outbox

The sender-side retry queue for undelivered private messages — retention limits, retry cap, and persistence — is specified in [Store and Forward](spec/05-store-and-forward.md).

### 6.2 Couriers

The courier envelope wire format, rotating recipient tag, trust-tier deposit quotas, spray-and-wait budget, and handover behavior are specified byte-exactly in [Store and Forward](spec/05-store-and-forward.md).

### 6.3 Public History (Gossip Sync)

The gossip-sync request/response protocol, its Golomb-coded-set filter encoding, sync-round cadence, and per-type cache retention are specified byte-exactly in [Store and Forward](spec/05-store-and-forward.md).

### 6.4 Nostr Mailboxes

Relay selection and subscription lookback for private-message envelopes and `courier drop`s are specified in [Nostr Bridge](spec/06-nostr-bridge.md), covering the both-devices-offline case for mutual favorites whenever either side touches the internet.

### 6.5 Delivery Metrics

The local-only delivery counters a client may keep are specified in [Store and Forward](spec/05-store-and-forward.md).

## 7. Application Layer

* **Public chat** — signed broadcast messages within the mesh, backed by the gossip-synced history above.
* **Private chat** — end-to-end encrypted messages with delivery and read receipts, over mesh, courier, or Nostr.
* **Location channels** — geohash-scoped public rooms carried over Nostr relays for regional chat beyond radio range.
* **Favorites** — the mutual-trust relationship that unlocks Nostr delivery and the larger courier quota.
* **Media** — files and images fragment over the mesh, with explicit accept before anything touches disk; couriers carry text only. Size ceilings are specified byte-exactly in [Payloads](spec/04-payloads.md).
* **Panic wipe** — clears identity keys, favorites, carried courier mail, the sealed outbox, archived public history, and metrics.

## 8. Security Considerations

* **Relay nodes** cannot read private traffic; they forward opaque ciphertext. Padding applies to Noise frames only (§4.1), so other packet types relay at their natural length.
* **Couriers** are quota-bounded mailbags. A malicious courier can drop mail (redundant copies and deposit retry mitigate this) but cannot read it, link it across days, or amplify it — copy budgets are capped and every envelope is validated against size and lifetime policy on deposit.
* **Flooding abuse** is bounded by TTL clamps, deduplication, per-depositor quotas, connect-rate limits, and announce-rate limiting.
* **Replay** of public broadcasts is bounded by the 6-hour acceptance window plus deduplication; private payloads are protected by Noise nonces.
* **Metadata is the weakest part of this design, and the peer ID does not help.** The 8-byte sender ID in every packet header is derived from a never-rotating key (§3), and announcements publish the static keys and nickname in cleartext, so a passive listener can enumerate participants and follow a device between places. Announcements also carry up to ten direct-neighbor IDs (§4.3), which hands a single sniffer the local adjacency graph. Origin packets leave at the default TTL, so hop distance identifies the originator. Daily-rotating courier tags do limit correlation of carried mail, and Nostr traffic can ride Tor. Addressing the radio-layer exposure is future work (§9).
* **No forward secrecy for sealed mail or Nostr private envelopes** (§5.2–5.3) means compromise of a recipient's static key can expose retained ciphertext addressed to that key.

## 9. Future Work

* Prekey-based forward secrecy for courier envelopes.
* Couriered media beyond the 16 KiB text cap.
* Probabilistic relay and edge-of-network TTL boosting for very dense and very sparse graphs.
* Multi-hop courier routing informed by encounter history.
* **Rotating on-air identity.** Epoch-rotating peer IDs, with static-key disclosure moved inside the encrypted handshake and mutual favorites recognising each other through a tag derived from their shared secret, so presence stops being linkable across sessions (§3, §8).
* **Padding for non-Noise packet types**, and closing the gap where a frame needing more than 255 bytes of padding is emitted unpadded (§4.1).
* Making the neighbor list in announcements optional, or restricted to authenticated links (§4.3).

---

*This document describes the protocol as implemented in the current release. The implementation is free and unencumbered software released into the public domain.*
