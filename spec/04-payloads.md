# 04 — Payload Layouts

**Spec:** 1.0.1  

TLV conventions differ by packet family — do not mix length widths.

| Family | Length field |
|--------|--------------|
| Announce / private message / authenticated peer state | `uint8` |
| Courier envelope / prekey bundle | `uint16` BE |
| File transfer content TLV | `uint32` BE (canonical); other file TLVs `uint16` BE |

### Unknown-TLV policy (do not over-promise)

Forward-compatible **skip** of unknown TLV types applies only where the
reference decoder actually skips:

| Family | Unknown TLV behaviour |
|--------|------------------------|
| Announce | **Skip** and continue |
| Authenticated peer state | **Skip** and continue |
| Courier envelope | **Skip** and continue |
| Prekey bundle | **Skip** and continue |
| File transfer | **Skip** and continue |
| Private message (`PrivateMessagePacket`) | **Reject** entire payload (`nil`) |

Adding a new private-message TLV under a SemVer **minor** bump would break
current reference DM decoders. Treat private-message TLV extensions as a
**MAJOR** wire change (or change the decoder first), not as a silent skip.

---

## 1. Announce (`MessageType 0x01`)

**Source:** `bitchat/Protocols/Packets.swift` — `AnnouncementPacket`

Each TLV: `[type:u8][len:u8][value]`.

| Type | Field | Notes |
|------|-------|-------|
| `0x01` | nickname | UTF-8, ≤255 bytes (**required**) |
| `0x02` | noisePublicKey | 32-byte Curve25519 KA public (**required**) |
| `0x03` | signingPublicKey | 32-byte Ed25519 public (**required**) |
| `0x04` | directNeighbors | concatenation of ≤10 × 8-byte peer IDs |
| `0x05` | capabilities | little-endian `PeerCapabilities` bitfield (minimal encoding, ≥1 byte) |
| `0x06` | bridgeGeohash | UTF-8 cell, ≤12 bytes |

Outer packet is Ed25519-signed (`hasSignature`). Sender ID **MUST** equal
`SHA256(noisePublicKey)[0..<8]`.

### 1.1 Capability bits (`PeerCapabilities`)

Encoded little-endian, trailing zero bytes dropped; always at least one byte.

| Bit | Name |
|-----|------|
| 0 | `prekeys` |
| 1 | `wifiBulk` |
| 2 | `gateway` |
| 3 | `groups` |
| 4 | `board` |
| 5 | `vouch` |
| 6 | `meshDiagnostics` |
| 7 | `bridge` |
| 8 | `privateMedia` |
| 9 | `privateMediaReceipts` |
| 10 | `nonDestructiveNoiseReplacement` (reserved; do not advertise) |

---

## 2. Public message (`MessageType 0x02`)

**Source:** `BitchatMessage.toBinaryPayload()`

```
flags:u8
timestamp_ms:u64 BE
id_len:u8 | id UTF-8
sender_len:u8 | sender UTF-8
content_len:u16 BE | content UTF-8
[optional fields per flags…]
```

| Flag bit | Meaning |
|----------|---------|
| `0x01` | isRelay |
| `0x02` | isPrivate (legacy; mesh DMs use Noise instead) |
| `0x04` | has originalSender (`u8` len + UTF-8) |
| `0x08` | has recipientNickname |
| `0x10` | has senderPeerID (`u8` len + UTF-8 peer id string) |
| `0x20` | has mentions (`u8` count, then each `u8` len + UTF-8) |
| `0x40` | isBridged |

---

## 3. Leave (`0x03`)

Reference clients send a signed leave with a small/empty payload. Treat unknown
payload bytes as non-fatal if the outer signature verifies.

---

## 4. Courier envelope (`0x04`)

**Source:** `CourierEnvelope.swift`

TLV: `[type:u8][len:u16 BE][value]`.

| Type | Field | Length |
|------|-------|--------|
| `0x01` | recipientTag | 16 bytes — HMAC-SHA256 truncated |
| `0x02` | expiry | 8 bytes `uint64` BE ms since epoch |
| `0x03` | ciphertext | 1…16384 bytes Noise X ciphertext |
| `0x04` | copies | 1 byte spray budget (omitted when `1`) |
| `0x05` | prekeyID | 4 bytes `uint32` BE (v2 only; omitted for v1) |

Recipient tag:

```
tag = HMAC-SHA256(key = recipientNoiseStatic,
                  msg = "bitchat-courier-tag-v1" || uint32_be(utcDay))[0..<16]
utcDay = floor(unixSeconds / 86400)
```

Matchers **SHOULD** accept yesterday/today/tomorrow tags for clock skew.
`copies` is clamped to `1…8`. Max lifetime policy in reference clients: 24 h.

---

## 5. Fragment (`0x20`)

See [`02-ble-transport.md`](02-ble-transport.md) §5 — 13-byte header + chunk.

---

## 6. File transfer (`0x22`) and private files

**Source:** `BitchatFilePacket.swift`

Canonical encode:

| Type | Length width | Value |
|------|--------------|-------|
| `0x01` fileName | `u16` BE | UTF-8 |
| `0x02` fileSize | `u16` BE = 4 | `u32` BE size |
| `0x03` mimeType | `u16` BE | UTF-8 |
| `0x04` content | **`u32` BE** | raw bytes |

Decoders **SHOULD** accept legacy `fileSize` length 8 and legacy content length
width 2 when the canonical parse fails.

Limits: content ≤ 1 MiB; voice/image app caps 512 KiB.

**Public** media uses mesh type `0x22` (signed).  
**Private** media places the same `BitchatFilePacket` bytes inside Noise as
`NoisePayloadType.privateFile` (`0x20`), then fragments the outer
`noiseEncrypted` packet. Peers without capability bit `privateMedia` require a
consent-gated legacy path (see `docs/PRIVATE-MEDIA-MIGRATION.md`).

---

## 7. Prekey bundle (`0x24`)

**Source:** `PrekeyBundle.swift`

TLV `[type:u8][len:u16 BE][value]`:

| Type | Field |
|------|-------|
| `0x01` | noiseStaticPublicKey (32) |
| `0x02` | prekeys blob: repeated (`id:u32 BE` ‖ `pubkey:32`), 1…8 entries, unique IDs |
| `0x03` | generatedAt `u64` BE ms |
| `0x04` | Ed25519 signature (64) |

Signable bytes (domain-separated):

```
u8(len) || "bitchat-prekey-bundle-v1"
|| noiseStatic(32)
|| u8(count) || { id:u32 BE || pubkey:32 }×count
|| generatedAt:u64 BE
```

Verified with the owner's announce-bound Ed25519 key.

---

## 8. Ping / pong (`0x26` / `0x27`)

**Source:** `MeshPingPayload.swift`

```
nonce: 8 random bytes
originTTL: u8
```

Pong echoes the nonce. Hop estimate:
`hopCount = (originTTL - receivedTTL) + 1` when `originTTL ≥ receivedTTL`.
Unsigned and unencrypted by design. Trailing bytes **MAY** be ignored.

---

## 9. Noise inner: private message

**Source:** `PrivateMessagePacket`

TLV `[type:u8][len:u8][value]`:

| Type | Field |
|------|-------|
| `0x00` | messageID UTF-8 ≤255 |
| `0x01` | content UTF-8 ≤255 |

Prefixed by `NoisePayloadType.privateMessage` (`0x01`) when inside Noise.

Unlike announce/courier TLVs, any unknown type byte causes
`PrivateMessagePacket.decode` to return `nil` immediately (no skip). Both
`messageID` and `content` are required.

---

## 10. Noise inner: authenticated peer state

```
version = 0x01
then TLV [type:u8][len:u8][value]:
  0x01 capabilities — canonical little-endian PeerCapabilities (1…8 bytes)
  0x02 signingPublicKey — 32 bytes Ed25519
```

Duplicates, non-canonical capability encodings, and unknown versions **MUST**
be rejected.

---

## 11. Board / group / voice / Nostr carrier

These types have dedicated Swift modules (`BoardPackets`, `GroupProtocol`,
`VoiceBurstPacket`, bridge carriers). They follow the same outer
`BinaryProtocol` framing. Full TLV breakdowns for board and groups are
intentionally deferred to a minor spec revision; implementers should mirror
the encode/decode in:

- `bitchat/Protocols/BoardPackets.swift`
- `bitchat/Services/Groups/GroupProtocol.swift`
- live voice design notes in `docs/PUSH-TO-TALK-DESIGN.md`

---

## 12. Implementer checklist

- [ ] Parse announce TLVs with 1-byte lengths; require nickname + both keys.
- [ ] Encode capabilities as little-endian with unknown bits preserved.
- [ ] Courier TLVs use 2-byte lengths; compute rotating recipient tags.
- [ ] File content TLV uses 4-byte length; tolerate legacy widths on decode.
- [ ] Prekey bundle signature verifies over domain-prefixed signable bytes.
- [ ] Private DM content is Noise-typed, not a public `0x02` packet.
- [ ] Confirm unknown private-message TLVs reject; unknown announce TLVs skip.
