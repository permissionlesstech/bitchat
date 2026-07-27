# 01 — Wire Format

**Spec:** 1.0.0  
**Canonical source:** `localPackages/BitFoundation/Sources/BitFoundation/BinaryProtocol.swift`

All multi-byte integers on the mesh wire are **network byte order (big-endian)**
unless a payload chapter explicitly says otherwise (capability bitfields are
little-endian).

---

## 1. Packet overview

Every mesh PDU is a `BitchatPacket` encoded by `BinaryProtocol`:

```
+----------+------+-----+-----------+-------+---------------+
| Version  | Type | TTL | Timestamp | Flags | PayloadLength |
| 1 byte   | 1 B  | 1 B | 8 bytes   | 1 B   | 2 or 4 bytes  |
+----------+------+-----+-----------+-------+---------------+
| SenderID (8) | [RecipientID (8)] | [Route] | Payload… | [Signature (64)] |
```

| Version | Fixed header size | `PayloadLength` width |
|---------|-------------------|------------------------|
| `0x01`  | 14 bytes          | `uint16` BE            |
| `0x02`  | 16 bytes          | `uint32` BE            |

Other version bytes **MUST** be rejected.

Minimum valid frame: header + 8-byte sender ID (v1 → 22 bytes before optional
fields).

---

## 2. Fixed header byte offsets

### Version 1 (14-byte header)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | `version` = `0x01` |
| 1 | 1 | `type` (`MessageType`) |
| 2 | 1 | `ttl` |
| 3–10 | 8 | `timestamp` — milliseconds since Unix epoch, `uint64` BE |
| 11 | 1 | `flags` |
| 12–13 | 2 | `payloadLength` — `uint16` BE |

### Version 2 (16-byte header)

Same as v1 through the flags byte, then:

| Offset | Size | Field |
|--------|------|-------|
| 12–15 | 4 | `payloadLength` — `uint32` BE |

`Flags` always sit at absolute offset **11**
(`BinaryProtocol.Offsets.flags`).

---

## 3. Flags

| Mask | Name | Meaning |
|------|------|---------|
| `0x01` | `hasRecipient` | 8-byte `recipientID` follows `senderID` |
| `0x02` | `hasSignature` | 64-byte Ed25519 signature trails the payload |
| `0x04` | `isCompressed` | Payload section is zlib + original-size preamble |
| `0x08` | `hasRoute` | Source route present (**v2 only**; ignored on v1) |
| `0x10` | `isRSR` | Reserved/source-routing related marker; **not** covered by packet signature |
| `0x20`–`0x80` | — | Reserved; leave clear on send; ignore on receive |

---

## 4. Variable sections (in order)

After the fixed header:

1. **`senderID`** — exactly 8 bytes (zero-padded on the right if shorter at encode time).
2. **`recipientID`** — 8 bytes if `hasRecipient`; omitted otherwise.  
   Broadcast directed-fragment convention: eight `0xFF` bytes may appear as
   recipient; receivers treat nil **or** all-`0xFF` as broadcast for fragment
   assembly.
3. **`route`** (v2 + `hasRoute` only) — **not** counted inside `payloadLength`:
   - `uint8` hop count `N` (`1…255`)
   - `N × 8` bytes of hop peer IDs  
   Empty hop IDs are illegal at encode time; hops longer than 8 bytes are
   truncated, shorter hops zero-padded to 8.
4. **Payload section** — exactly `payloadLength` bytes (see compression).
5. **`signature`** — 64 bytes if `hasSignature`.

### 4.1 `payloadLength` semantics

`payloadLength` covers **only** the payload section:

- uncompressed: raw payload bytes
- compressed: `originalSize` field (`uint16`/`uint32` BE matching version) **plus** zlib ciphertext

Route bytes are **excluded**.

Decoders **MUST** reject `payloadLength` values larger than
`FileTransferLimits.maxFramedFileBytes` (~1 MiB plus TLV/framing headroom).

---

## 5. Compression

Applied automatically at encode when beneficial
(`CompressionUtil` / `Constants.compressionThresholdBytes = 100`):

1. Candidate payload length ≥ 100 bytes.
2. Sample entropy check: unique-byte ratio over `min(len, 256)` samples &lt; 0.9.
3. zlib (`COMPRESSION_ZLIB`) must shrink the buffer; otherwise leave uncompressed.
4. Set `isCompressed`, prepend original size (2 bytes v1 / 4 bytes v2), then
   compressed bytes. `payloadLength` = preamble + compressed size.

Decompression:

- Original size **MUST** equal the decompressed length.
- Compression ratio (original / compressed) **MUST NOT** exceed `50_000:1`
  (zip-bomb guard).

---

## 6. PKCS#7-style frame padding

`MessagePadding` buckets: **256, 512, 1024, 2048**.

- Pad bytes are all equal to the pad length (1…255).
- If more than 255 pad bytes would be required to reach the next bucket, the
  frame is left **unpadded**.
- Decode tries the buffer as-is, then strips padding and retries.

**Only** `noiseHandshake` and `noiseEncrypted` frames are padded on the BLE
outbound path. All other types travel at natural length — payload length is
observable for those types.

---

## 7. Message types (`type` byte)

From `MessageType` (`localPackages/BitFoundation/.../MessageType.swift`):

| Value | Name | Notes |
|-------|------|-------|
| `0x01` | `announce` | Presence + identity keys (signed) |
| `0x02` | `message` | Public chat (`BitchatMessage` binary) |
| `0x03` | `leave` | Departure |
| `0x04` | `courierEnvelope` | Store-and-forward sealed mail |
| `0x10` | `noiseHandshake` | Noise XX message blob |
| `0x11` | `noiseEncrypted` | Noise transport ciphertext |
| `0x20` | `fragment` | Fragment of a larger encoded packet |
| `0x21` | `requestSync` | GCS gossip sync request (local) |
| `0x22` | `fileTransfer` | Public file/audio/image TLV |
| `0x23` | `boardPost` | Signed geohash board post/tombstone |
| `0x24` | `prekeyBundle` | Gossiped one-time prekeys |
| `0x25` | `groupMessage` | Group-encrypted broadcast |
| `0x26` | `ping` | Mesh diagnostic echo request |
| `0x27` | `pong` | Mesh diagnostic echo reply |
| `0x28` | `nostrCarrier` | Signed Nostr event ferry |
| `0x29` | `voiceFrame` | Public live PTT burst |

Inner private traffic (DMs, receipts, private media, verification) uses type
`0x11` with a typed plaintext after decrypt — see
[`03-noise.md`](03-noise.md) and [`04-payloads.md`](04-payloads.md).

---

## 8. Peer identity on the wire

| Concept | Definition |
|---------|------------|
| Noise static key | 32-byte Curve25519.KeyAgreement public key |
| Fingerprint | `SHA-256(noiseStaticPublicKey)` (32 bytes / 64 hex) |
| Mesh peer ID | **First 8 bytes** of the fingerprint (16 hex chars) |
| Packet `senderID` / `recipientID` | Those 8 raw bytes |

The 8-byte routing ID is **stable** for the life of the Noise static key. It is
not a session ephemeral. Panic wipe / identity rotation is the only change
event.

Ed25519 signing keys (32-byte public) are advertised in announces and used for
packet signatures; they are distinct from the Noise static key.

---

## 9. Packet signatures

- Algorithm: **Ed25519** (`Curve25519.Signing`), 64-byte signature.
- Canonical bytes: encode the packet with `signature = nil`, `ttl = 0`,
  `isRSR = false` (TTL and RSR are mutable in flight and excluded).
- Relays **MUST** decrement TTL without recomputing the signature.
- Announces, leaves, public file transfers, and other authenticated public
  types set `hasSignature` when the reference clients emit them.

Optional helper `bitchat-announce-v1` binding bytes exist in the Noise service
for nickname/key binding tests; live mesh announces sign the **full packet**
canonical form above, verified against the Ed25519 key carried in the announce
TLV payload.

---

## 10. Size limits (shared)

| Limit | Value | Source |
|-------|-------|--------|
| Max file content | 1 MiB | `FileTransferLimits.maxPayloadBytes` |
| Max voice / image (app policy) | 512 KiB each | same |
| Max framed file decode ceiling | ~1 MiB + TLV + v2 header/ids/sig | `maxFramedFileBytes` |
| Compression attempt threshold | 100 bytes | `Constants.compressionThresholdBytes` |

---

## 11. Implementer checklist

- [ ] Round-trip v1 packet with no recipient, no signature, empty payload.
- [ ] Round-trip v1 with recipient + signature.
- [ ] Round-trip v2 with route hops; confirm route bytes are outside `payloadLength`.
- [ ] Compress a low-entropy &gt;100 B payload; confirm preamble + flag.
- [ ] Reject version `0x00` / `0x03`.
- [ ] Derive peer ID as `SHA256(noisePub)[0..<8]`.
