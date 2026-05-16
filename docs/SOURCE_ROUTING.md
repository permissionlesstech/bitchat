# Source-Based Routing for BitChat Packets (v2)

This document specifies the Source-Based Routing extension (v2) for the BitChat protocol. This upgrade enables efficient unicast routing across the mesh by allowing senders to specify an explicit path of intermediate relays.

**Status:** Implemented in Android and iOS. Backward compatible (v1 clients ignore routing data).

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
    *   **Fallback:** If the Next Hop is unreachable, **fall back to broadcast/flood** to ensure delivery.
3.  **If NO (Standard):**
    *   Flood the packet to all connected neighbors (subject to TTL and probability rules).
