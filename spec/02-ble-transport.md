# BLE Transport

This chapter defines bitchat's Bluetooth Low Energy transport: the GATT service and characteristic peers connect over, the MTU-driven fragmentation scheme that lets a `bitchat packet` exceed a single BLE write, and the advertising/scanning behavior peers use to find each other. It does not define the packet header or payload encodings themselves; see the Wire Format chapter for those.

## 1. GATT Service and Characteristic

A bitchat node runs both the GATT peripheral and central roles simultaneously, so it can be discovered by, and discover, other nodes without a fixed client/server split.

| Item | Value |
|---|---|
| Service UUID | `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C` |
| Characteristic UUID | `A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D` |
| Characteristic properties | notify, write, write-without-response, read |

There is a single characteristic on the service; it is the sole data channel, carrying every `bitchat packet` in both directions. There is no separate read/write characteristic pair.

## 2. MTU and Fragment Sizing

BLE links in this specification are sized to a 512-byte MTU ceiling. A sender's default per-fragment chunk size is 469 bytes, leaving headroom for the fragment header (see [Fragment Header](#31-fragment-header)), the enclosing packet's own header and ID sections, and encryption overhead when the fragment rides inside a `noiseEncrypted` packet.

## 3. Fragmentation

A packet whose encoded size exceeds the link MTU MUST be split into `fragment` (`0x20`) packets (see the Wire Format chapter's [Message Types](01-wire-format.md#7-message-types)) and reassembled at the receiving node. Each fragment carries one slice of the original packet's encoded bytes as its payload; the original packet's own header and sections are not re-transmitted per fragment beyond what is captured by the fragment header below.

### 3.1 Fragment Header

```
+----------------+-------------+-------------+------------+----------------+
| Fragment ID    | Index       | Total       | Orig. Type | Fragment Data  |
| 8 bytes        | 2 bytes     | 2 bytes     | 1 byte     | variable       |
+----------------+-------------+-------------+------------+----------------+
 offset 0          8             10            12           13
```

| Offset | Length (bytes) | Field | Description |
|---|---|---|---|
| 0 | 8 | `fragmentID` | A random identifier generated per fragmented stream, shared by every fragment in that stream. |
| 8 | 2 | `index` | This fragment's zero-based position within the stream, big-endian. |
| 10 | 2 | `total` | The total number of fragments in the stream, big-endian. |
| 12 | 1 | `originalType` | The `type` byte of the packet being fragmented (see [Message Types](01-wire-format.md#7-message-types)), so the receiver knows how to interpret the reassembled bytes. |
| 13 | variable | `fragmentData` | One contiguous slice of the original packet's encoded bytes. |

### 3.2 Fragment Cap and Lifetime

A receiver MUST reject a fragment stream whose `total` exceeds 10,000; this is the general reassembly ceiling and applies regardless of the fragmented packet's type.

A stricter cap applies to one case: a directed `fileTransfer (0x22)` packet (the legacy migration fallback for private media, used when the recipient has not advertised the `privateMedia` capability — see the Payloads chapter's [§5](04-payloads.md#5-peer-state-and-capabilities)) MUST NOT be split into more than 256 fragments, and a receiver MAY reject such a stream if `total` exceeds that lower cap. This exists as a cross-platform contract with clients whose reassembler enforces a 256-fragment ceiling on that path specifically; implementations that accept larger fragment counts on it still MUST NOT rely on peers doing the same. Public files and capability-gated encrypted private media (carried as `noiseEncrypted` fragments to a peer advertising `privateMedia`) are bound only by the general 10,000-fragment ceiling above.

A receiving node reassembles fragments for a stream by collecting them keyed by `(sender, fragmentID)` until the number received equals `total`, then concatenates them in `index` order to recover the original packet's encoded bytes, which are then decoded per the Wire Format chapter using `originalType`. A stream with no new fragment arriving for 30 seconds is considered stalled; a node SHOULD request the missing fragments (see the Store and Forward chapter's sync mechanism) rather than discarding the stream outright.

Per-node limits on concurrent in-flight reassemblies and their buffered byte size are resource guards, not part of the wire protocol — they are implementation-defined and MAY differ between nodes without affecting interop.

### 3.3 Route-Aware Fragmentation (v2)

When the packet being fragmented carries a v2 [source route](README.md#glossary), the fragment-carrying packets MAY themselves carry that same source route so each fragment follows the same explicit path. Doing so adds the route section's bytes to every fragment's overhead, so a sender MAY shrink its per-fragment chunk size below the 469-byte default to keep the outer packet within the MTU, floored at a 64-byte minimum chunk size.

## 4. Advertising and Scanning

### 4.1 Advertisement Contents

A node's BLE advertisement (and any scan-response packet) MUST carry only the service UUID from [§1](#1-gatt-service-and-characteristic). It MUST NOT carry the device's local name, TX power level, peer ID, or any other peer-identifying bytes — advertisement contents are the only signal visible to a passive scanner before a connection and handshake establish identity, and leaking a stable identifier there undermines that.

A peer's `peer ID` is learned only after connecting and exchanging an `announce` packet over the characteristic, never from the advertisement itself.

### 4.2 Scanning

A central-role node scans filtered to the service UUID from [§1](#1-gatt-service-and-characteristic) and, on connecting, (re)discovers that same service and its characteristic before use.

### 4.3 Advertising and Scan Interval

The physical advertising interval and scan duty cycle are not part of the wire protocol — they are implementation-defined, since the platform BLE stack, not the application, ultimately governs them. Implementations MAY duty-cycle scanning or vary advertising parameters for power management without affecting interop, provided the contents in [§4.1](#41-advertisement-contents) and the service/characteristic in [§1](#1-gatt-service-and-characteristic) are unchanged.
