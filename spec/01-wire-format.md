# Wire Format

This chapter defines the byte-level encoding of a bitchat packet: the fixed header, the variable sections that follow it, padding, and the two general-purpose TLV (type-length-value) framings used elsewhere in this specification. Application-layer payload catalogs (which TLV types exist and what their values mean) are defined in the chapters that own them, not here; this chapter defines only the grammar those catalogs are written in.

## 1. Packet Versions

A packet carries one of two version numbers, `1` or `2`, as the first byte of its header. The two versions share the same field order and differ only in:

- the width of the `payloadLength` field (2 bytes for v1, 4 bytes for v2), and
- the availability of the optional source-route section, which v1 packets MUST NOT carry.

A decoder MUST reject a packet whose version byte is neither `1` nor `2`.

## 2. Header Layout

All multi-byte integer fields, in the header and everywhere else in this chapter, are big-endian (network byte order) unless stated otherwise.

```
+--------+------+-----+------------------------+-------+------------------+
|Version | Type | TTL |       Timestamp        | Flags | PayloadLength    |
|1 byte  |1 byte|1byte|        8 bytes          |1 byte | 2 or 4 bytes     |
+--------+------+-----+------------------------+-------+------------------+
 offset 0  1      2     3                        11      12
```

| Offset | Length (bytes) | Field | Description |
|---|---|---|---|
| 0 | 1 | `version` | `1` or `2`. Selects the header size and `payloadLength` width. |
| 1 | 1 | `type` | The message type. See [Message Types](#7-message-types). |
| 2 | 1 | `ttl` | Hop-count budget. Decremented by each relay; a packet MUST NOT be relayed once its `ttl` reaches `0`. |
| 3 | 8 | `timestamp` | Milliseconds since the Unix epoch. |
| 11 | 1 | `flags` | Bitfield. See [Flags](#3-flags). |
| 12 | 2 (v1) / 4 (v2) | `payloadLength` | Length, in bytes, of the `payload` section only (see [Payload and Compression](#43-payload-and-compression)). Excludes the source-route section. |

The header is therefore **14 bytes for v1** and **16 bytes for v2** — the only difference is the width of `payloadLength`, not an added field. A v1 packet's `payloadLength` is a 16-bit field, so its payload section is bounded to 65,535 bytes; a v2 packet's 32-bit `payloadLength` raises that ceiling, subject to whatever transport-level limits the carrying link imposes (see the BLE Transport chapter).

## 3. Flags

The `flags` byte is a bitfield, bit 0 the least significant:

| Bit | Value | Name | Meaning |
|---|---|---|---|
| 0 | 0x01 | `hasRecipient` | The 8-byte `recipientID` section is present. |
| 1 | 0x02 | `hasSignature` | The 64-byte `signature` section is present. |
| 2 | 0x04 | `isCompressed` | The `payload` section is compressed; see [Payload and Compression](#43-payload-and-compression). |
| 3 | 0x08 | `hasRoute` | The source-route section is present. MUST NOT be set on a v1 packet. |
| 4 | 0x10 | `isRSR` | Marks the packet as a solicited response to a prior sync request. This bit is excluded from the signed frame (see [Signing](#5-signing)) because it is set after signing and MAY change during relay. Its consumption is defined in the Store and Forward chapter. |
| 5–7 | 0x20–0x80 | reserved | MUST be `0` on encode. A decoder MUST ignore reserved bits rather than reject the packet, to allow future extension. |

## 4. Variable Sections

Following the header, sections appear in this fixed order. Each is present only under the condition given; absent sections contribute no bytes.

| Section | Size | Present when |
|---|---|---|
| `senderID` | 8 bytes, fixed | always |
| `recipientID` | 8 bytes, fixed | `hasRecipient` |
| route | 1-byte hop count + 8 bytes/hop | `hasRoute` (v2 only) |
| `payload` | `payloadLength` bytes (optionally prefixed by a 2/4-byte original-size field; see below) | always |
| `signature` | 64 bytes, fixed | `hasSignature` |

### 4.1 Sender ID and Recipient ID

`senderID` and `recipientID` are each 8-byte `peer ID` values (see the glossary in [`README.md`](README.md)). `recipientID` is present only when `hasRecipient` is set; its absence marks the packet as a broadcast rather than a directed send.

### 4.2 Source Route

A v2 packet MAY carry an explicit `source route`: a 1-byte hop count `N`, followed by `N` 8-byte peer IDs, in traversal order. This section is present only when `hasRoute` is set, and its bytes are **not** counted in `payloadLength`. `N` MUST NOT exceed 255 (it is bounded by the 1-byte count prefix).

### 4.3 Payload and Compression

The `payload` section is `payloadLength` bytes. When `isCompressed` is set, the first bytes of the payload section are an original-size preamble — 2 bytes for a v1 packet, 4 bytes for a v2 packet, big-endian — giving the decompressed size, followed by the compressed bytes; both the preamble and the compressed bytes are counted in `payloadLength`. When `isCompressed` is not set, the payload section is the payload bytes verbatim.

The interpretation of the (decompressed) payload bytes depends on `type`; see the Payloads, Noise, and Store and Forward chapters for the payload encodings each message type carries.

### 4.4 Signature

When `hasSignature` is set, a 64-byte Ed25519 signature follows the payload section. See [Signing](#5-signing) for what is signed.

## 5. Signing

The signature, when present, is computed over the packet's encoded bytes with three substitutions: the `signature` section itself is omitted, `ttl` is fixed to `0` regardless of the packet's actual TTL, and the frame is always padded per [Padding](#6-padding) — even for a message type that §6 transmits unpadded. `ttl` is excluded because a relay decrementing it in place would otherwise invalidate every signed packet it forwards. `isRSR` is likewise excluded, being set after the packet is signed.

A verifier MUST reconstruct the same fixed-TTL, signature-omitted, RSR-omitted, **padded** frame before checking a signature against it, regardless of whether the packet as received on the wire carried padding.

## 6. Padding

This section defines the padding algorithm and states which message types carry padding **on the wire**. The signing transcript is a separate case: it is always padded by this same algorithm regardless of message type (see [Signing](#5-signing)), because the signature is computed before the type-dependent choice of whether to pad the transmitted frame is applied.

Only `noiseHandshake` and `noiseEncrypted` packets are padded on the wire; every other message type is transmitted at its natural length. Padding is applied to the full encoded frame (header through payload, before the signature section) and is PKCS#7-style: the pad length is appended as that many bytes, each byte equal to the pad length itself.

Padding targets the smallest of the block sizes `256`, `512`, `1024`, `2048` bytes that the frame (plus a 16-byte allowance for encryption overhead) fits into. Because the pad length must fit in a single byte, a frame that would need more than 255 bytes of padding to reach its target block is emitted **unpadded** instead of padded to a smaller-than-optimal bucket. A decoder MUST attempt to decode a frame as unpadded first, and only on failure retry after stripping trailing PKCS#7 padding.

## 7. Message Types

The `type` byte selects both the message's purpose and, indirectly, the shape of its payload:

| Value | Name |
|---|---|
| 0x01 | `announce` |
| 0x02 | `message` |
| 0x03 | `leave` |
| 0x04 | `courierEnvelope` |
| 0x10 | `noiseHandshake` |
| 0x11 | `noiseEncrypted` |
| 0x20 | `fragment` |
| 0x21 | `requestSync` |
| 0x22 | `fileTransfer` |
| 0x23 | `boardPost` |
| 0x24 | `prekeyBundle` |
| 0x25 | `groupMessage` |
| 0x26 | `ping` |
| 0x27 | `pong` |
| 0x28 | `nostrCarrier` |
| 0x29 | `voiceFrame` |

Each type's payload encoding is defined in the chapter that owns it (Payloads, Noise, Store and Forward, BLE Transport, or Nostr Bridge). A decoder MUST skip — not reject the enclosing packet for — a `type` value it does not recognize, to allow forward-compatible extension.

## 8. TLV Encodings

Two distinct TLV (type-length-value) byte framings are used across this specification. They are structurally different — most notably in the width of the length field — so this chapter names them distinctly rather than describing one universal "TLV format." Both use unknown-type-skip decoding: a decoder MUST skip a TLV entry whose type it does not recognize (using the entry's length to find the next one) rather than rejecting the payload that contains it.

### 8.1 TLV-8

```
+------+--------+-------------------+
| Type | Length |       Value       |
|1 byte|1 byte  |    Length bytes   |
+------+--------+-------------------+
```

`Length` is the number of bytes in `Value`, as an unsigned 8-bit integer — a single TLV-8 entry's value is therefore at most 255 bytes. This framing is used by the `announce` payload and by gossip neighbor lists; see the Payloads chapter for the type catalog.

### 8.2 TLV-16

```
+------+-----------------+-------------------+
| Type |     Length      |       Value       |
|1 byte|  2 bytes (BE)   |    Length bytes   |
+------+-----------------+-------------------+
```

`Length` is the number of bytes in `Value`, as a big-endian unsigned 16-bit integer. This framing is used by `prekeyBundle` payloads (see the Noise chapter) and `courierEnvelope` payloads (see the Store and Forward chapter).
