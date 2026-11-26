# Source-Based Routing for BitChat Packets (v2)

This document specifies the Source-Based Routing extension (v2) for the BitChat protocol. This upgrade enables efficient unicast routing across the mesh by allowing senders to specify an explicit path of intermediate relays.

**Status:** Implemented in Android and iOS: both decode routed packets, forward along routes, and originate routes. iOS origination is policy-gated (see §8). Backward compatible (v1 clients never receive routed frames from iOS: routes are only originated when every node on the path has been observed speaking v2).

---

## 1. Protocol Versioning & Layering

To support source routing and larger payloads, the packet format has been upgraded to **Version 2**.

*   **Version 1 (Legacy):** 2-byte payload length limit. Ignores routing flags.
*   **Version 2 (Current):** 4-byte payload length limit. Supports Source Routing.

**Key Rule:** The `HAS_ROUTE (0x08)` flag is **only valid** if the packet `version >= 2`. Relays receiving a v1 packet must ignore this flag even if set.

---

## 2. Packet Structure Comparison

The following diagram illustrates the structural differences between a standard v1 packet and a source-routed v2 packet.

### V1 Packet (Legacy)
```text
+-------------------+---------------------------------------------------------+
| Fixed Header (14) | Variable Sections                                       |
+-------------------+----------+-------------+------------------+-------------+
| Ver: 1 (1B)       | SenderID | RecipientID | Payload          | Signature   |
| Type, TTL, etc.   | (8B)     | (8B)        | (Length in Head) | (64B)       |
| Len: 2 Bytes      |          | (Optional)  |                  | (Optional)  |
+-------------------+----------+-------------+------------------+-------------+
```

### V2 Packet (Source Routed)
```text
+-------------------+-----------------------------------------------------------------------------+
| Fixed Header (16) | Variable Sections                                                           |
+-------------------+----------+-------------+-----------------------+------------------+-------------+
| Ver: 2 (1B)       | SenderID | RecipientID | SOURCE ROUTE          | Payload          | Signature   |
| Type, TTL, etc.   | (8B)     | (8B)        | (Variable)            | (Length in Head) | (64B)       |
| Len: 4 Bytes      |          | (Required*) | Only if HAS_ROUTE=1   |                  | (Optional)  |
+-------------------+----------+-------------+-----------------------+------------------+-------------+
```

**(*) Note:** A `Route` can be attached to **any** packet type that has a `RecipientID` (flag `HAS_RECIPIENT` set).

### Fixed Header Differences

| Field | Size (v1) | Size (v2) | Description |
|---|---|---|---|
| **Version** | 1 byte | 1 byte | `0x01` vs `0x02` |
| **Payload Length** | **2 bytes** | **4 bytes** | `UInt32` in v2 to support large files. **Excludes** route/IDs/sig. |
| **Total Size** | **14 bytes** | **16 bytes** | V2 header is 2 bytes larger. |

---

## 3. Source Route Specification

The `Source Route` field is a variable-length list of **intermediate hops** that the packet must traverse.

*   **Location:** Immediately follows `RecipientID`.
*   **Structure:**
    *   `Count` (1 byte): Number of intermediate hops (`N`).
    *   `Hops` (`N * 8` bytes): Sequence of Peer IDs.

### Intermediate Hops Only
The route list MUST contain **only** the intermediate relays between the sender and the recipient.
*   **DO NOT** include the `SenderID` (it is already in the packet).
*   **DO NOT** include the `RecipientID` (it is already in the packet).

**Example:**
Topology: `Alice (Sender) -> Bob -> Charlie -> Dave (Recipient)`
*   Packet `SenderID`: Alice
*   Packet `RecipientID`: Dave
*   Packet `Route`: `[Bob, Charlie]` (Count = 2)

---

## 4. Topology Discovery (Gossip)

To calculate routes, nodes need a view of the network topology. This is achieved via a **Neighbor List** extension to the `IdentityAnnouncement` packet.

The `ANNOUNCE` packet payload now consists of a sequence of TLVs. The standard identity information is followed by an optional Gossip TLV.

*   **Mechanism:** Appended to the `IdentityAnnouncement` payload.
*   **New TLV Type:** `0x04` (Direct Neighbors).
*   **Content:** A list of Peer IDs that the announcing node is directly connected to.

**TLV Structure (Type 0x04):**
```text
[Type: 0x04] [Length: 1B] [NeighborID1 (8B)] [NeighborID2 (8B)] ...
```
The `Length` field indicates the total size of the neighbor IDs in bytes (N * 8). There is no explicit count field.

Nodes receiving this TLV update their local mesh graph, linking the sender to the listed neighbors.

### Edge Verification (Two-Way Handshake)

To prevent spoofing and routing through stale connections, the Mesh Graph service implements a strict two-way handshake verification:

*   **Unconfirmed Edge:** If Peer A announces Peer B, but Peer B does *not* announce Peer A, the connection is treated as **unconfirmed**. Unconfirmed edges are visualized as dotted lines in debug tools but are **excluded** from route calculations.
*   **Confirmed Edge:** An edge is only valid for routing when **both** peers explicitly announce each other in their neighbor lists. This ensures that the connection is bidirectional and currently active from both perspectives.

---

## 5. Fragmentation & Source Routing

When a large source-routed packet (e.g., File Transfer) exceeds the MTU and requires fragmentation:

1.  **Version Inheritance:** All fragments MUST be marked as **Version 2**.
2.  **Route Inheritance:** All fragments MUST contain the **exact same Route field** as the parent packet.

**Why?** If fragments were sent as v1 packets or without routes, they would fall back to flooding, negating the bandwidth benefits of source routing for large data transfers.

---

## 6. Security & Signing

Source routing is fully secured by the existing Ed25519 signature scheme.

*   **Scope:** The signature covers the **entire packet structure** (Header + Sender + Recipient + Route + Payload).
*   **Verification:** The receiver verifies the signature against the `SenderID`'s public key.
*   **Integrity:** Any tampering with the route list by malicious relays will invalidate the signature, causing the packet to be dropped by the destination.

**Signature Input Construction:**
Serialize the packet exactly as transmitted, but temporarily set `TTL = 0` and remove the `Signature` bytes.

---

## 7. Relay Logic

When a node receives a packet **not** addressed to itself:

1.  **Check Route:**
    *   Is `Version >= 2`?
    *   Is `HAS_ROUTE` flag set?
    *   Is the route list non-empty?
2.  **If YES (Source Routed):**
    *   Find local Peer ID in the route list at index `i`.
    *   **Next Hop:** The peer at `i + 1`.
    *   **Last Hop:** If `i` is the last index, the Next Hop is the `RecipientID`.
    *   **Action:** Attempt to unicast (`sendToPeer`) to the Next Hop.
    *   **Fallback:** If the Next Hop is unreachable, **fall back to conservative broadcast/flood** (bypassing MPR suppression and neighbor pruning) to ensure delivery.
3.  **If NO (Broadcast / Flood):**
    *   **Strict 1-hop sync:** `REQUEST_SYNC` packets are link-local and are never relayed.
    *   **Conservative flood classes:** Topology-healing control packets (`ANNOUNCE` for newly seen/reconnected peers, neighbor-list changes, or stale/unknown originators; `LEAVE`), directed/session-critical traffic (`NOISE_HANDSHAKE`, `NOISE_ENCRYPTED`, `COURIER_ENVELOPE`, `PING`, `PONG`, `NOSTR_CARRIER`, urgent `BOARD_POST`, directed `MESSAGE`/`FRAGMENT`/`FILE_TRANSFER`), and source-route fallbacks always relay and disable neighbor pruning (`skipNeighborPruning = true`).
    *   **Deterministic 2-hop MPR hub selection (zero wire changes):** For broadcast `MESSAGE`, `VOICE_FRAME`, ordinary `BOARD_POST`, signed `PREKEY_BUNDLE`, unchanged periodic `ANNOUNCE` (1-covered, `k = 1`), and broadcast `FILE_TRANSFER` / signed `FRAGMENT` (2-covered, `k = 2`), when network size `> 3`, the immediate previous hop `P` is known from a bound ingress link, and `P`'s local topology entry is fresh (default `bleMprEdgeMaxAgeSeconds = 120s`):
        *   Compute `N1(P)` = fresh confirmed 1-hop neighbors of `P`, and `N2(P)` = fresh confirmed 1-hop neighbors of nodes in `N1(P)` excluding `{P} U N1(P)`.
        *   Step 1: Elect every `u in N1(P)` that is among the only `<= k` covers of some `w in N2(P)`.
        *   Step 2: While any `w in N2(P)` has fewer than `k` selected covers among available candidates, greedily elect the remaining `u in N1(P)` maximizing `(uncovered N2(P) reach, fresh confirmed degree, lexicographically smallest peerID)`.
        *   **Fail-safe rule:** A non-MPR node MUST still relay if (a) any connected direct link has not yet bound to a verified peer ID, (b) `P`'s announcement is missing or stale, or (c) the node has a connected direct neighbor `v` (other than `P` and packet origin) that is not in `N1(P)` and is not already `k`-covered by `P`'s selected MPRs (protecting legacy clients that omit TLV `0x04`, newly joined peers, and unconfirmed/stale links).
        *   **Mixed-version note:** Because this policy introduces zero wire changes, upgraded iOS clients disable legacy per-role broadcast subsetting so originators and elected MPRs reach all non-pruned direct neighbors. In mixed meshes containing pre-MPR iOS origins that still subset same-role broadcasts at `>= 4` links while announcing to all neighbors, any neighbor omitted by the legacy origin's live subset is reconciled by `REQUEST_SYNC` gossip backfill (matching Android's zero-wire-change MPR behavior) until those peers upgrade.
    *   **Separate local-delivery vs. relay deduplication:** Local delivery deduplicates on first accepted arrival, while `BLERelayLifecycleStore` tracks MPR-suppressed packet IDs separately from already-relayed packet IDs. If a cryptographically authenticated duplicate arrives later from an electing previous hop within the lifecycle window (and has not yet been relayed), the node relays it at most once without re-delivering it locally. Unsigned broadcast envelopes (`FRAGMENT`, `GROUP_MESSAGE`) fail closed to neighbor-pruned relaying rather than irreversibly MPR-suppressing on first arrival.
    *   **Previous-hop and origin neighbor pruning:** When relaying a non-conservative broadcast whose bound previous hop is known and fresh, `BroadcastPruningPolicy` skips sending back to the incoming link, packet origin, previous hop (across all links), and any bound target peer that is a fresh confirmed neighbor of origin or previous hop. Unbound target links are never pruned, and stale/unknown-previous-hop fallbacks disable neighbor pruning completely.

---

## 8. iOS Origination Policy

iOS attaches a route (upgrading the packet to v2 and re-signing it) only when
**all** of the following hold at send time (`BLESourceRouteOriginationPolicy`):

1.  **Authored locally.** The packet's `SenderID` is our own peer ID. Relays
    never rewrite someone else's packet — adding a route would force a
    re-sign under the wrong key. Relays only *follow* existing routes
    (`BLERouteForwardingPolicy`).
2.  **Directed.** The packet has a single-peer `RecipientID` (not the
    broadcast ID). In practice this covers Noise-encrypted private traffic,
    private file transfers, and their fragments (fragments inherit the
    parent's route and version, per §5).
3.  **TTL headroom.** `TTL > 1`. Link-local packets (e.g. `REQUEST_SYNC`,
    always TTL 0) never carry routes.
4.  **Recipient not directly connected.** A direct write already delivers in
    one hop; a route would only add bytes.
5.  **Complete v2 path exists.** BFS over the confirmed-edge mesh graph
    (`MeshTopologyTracker`, built from verified announce `directNeighbors`
    claims, entries expiring after 60 s) finds a path with **at most 4
    intermediate hops** where every intermediate hop **and the recipient**
    has been observed originating or relaying a v2 packet. Nodes never seen
    speaking v2 are assumed v1-only and are excluded — a v1 client cannot
    decode a v2 frame, so routing through it would silently drop the packet.
6.  **No recent route failure.** See below.

If any gate fails, behavior is exactly the pre-routing flood/direct-write
path — v1 peers observe no change.

### Failure Fallback

A routed unicast rides one path; a broken hop loses the packet where a flood
would heal around it. iOS keeps a small per-recipient health cache
(`BLESourceRouteFailureCache`): a routed send that sees no inbound packet
authored by the recipient within 10 s counts as a route failure, and directed
sends to that recipient fall back to flooding for the next 60 s before
routing is attempted again. Retransmission of the payload itself stays where
it always was (MessageRouter and higher layers).
