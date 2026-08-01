# Payloads

This chapter catalogs bitchat's application-layer payload encodings: the field-by-field contents carried by the outer, plaintext `MessageType` packets that are not owned by another chapter, and by the `NoisePayloadType` values carried inside a `noiseEncrypted (0x11)` packet's application-payload framing (see the Noise chapter's [§3.3](03-noise.md#33-application-payload-framing)). The Wire Format chapter's [Message Types](01-wire-format.md#7-message-types) table lists every `type` value; this chapter defines the payload shape for each one it owns.

Not owned by this chapter: `noiseHandshake`/`noiseEncrypted` framing itself and `prekeyBundle` (Noise chapter), `courierEnvelope` and `requestSync` (Store and Forward chapter), `fragment` (BLE Transport chapter), and `nostrCarrier` (Nostr Bridge chapter).

## 1. Outer and Inner Payloads

An outer payload is the `payload` section of a plaintext `BitchatPacket` — its type is visible to every relay. An inner payload is one of the eleven `NoisePayloadType` values, visible only to the two ends of a `Noise session`. A handful of payload shapes — files and voice bursts — are carried both ways: the identical wire body rides as an outer `fileTransfer`/`voiceFrame` packet when sent publicly, and as an inner `privateFile`/`voiceFrame` payload when sent to one peer over a session. Each section below states which case it covers.

## 2. Presence: Announce

`announce (0x01)` is a signed, plaintext broadcast (`AnnouncementPacket`) by which a device identifies itself. Its payload is a [TLV-8](01-wire-format.md#81-tlv-8) sequence:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `nickname` | ≤255, UTF-8 | Display name. |
| 0x02 | `noisePublicKey` | 32 | The device's Noise `static key`. |
| 0x03 | `signingPublicKey` | 32 | The device's Ed25519 `signing key`. |
| 0x04 | `directNeighbors` | multiple of 8, optional | Up to 10 direct-neighbor `peer ID`s, concatenated. |
| 0x05 | `capabilities` | 1–8, optional | `PeerCapabilities` bitfield ([§5.1](#51-peercapabilities-bitfield)). |
| 0x06 | `bridgeGeohash` | ≤12, optional, UTF-8 | Coarse geohash cell this peer bridges to Nostr, present only when advertising the `bridge` capability. Full encoding is defined in the Nostr Bridge chapter. |

`nickname`, `noisePublicKey`, and `signingPublicKey` are REQUIRED; a decoder MUST reject an `announce` payload missing any of them. `directNeighbors`, `capabilities`, and `bridgeGeohash` are each OPTIONAL and MAY be absent, including from clients that predate them.

## 3. Public and Private Messages

### 3.1 Public Message

`message (0x02)` is a signed, plaintext broadcast. Its payload is the message's UTF-8 content bytes verbatim — no TLV framing and no length prefix beyond the enclosing packet's `payloadLength`.

### 3.2 Private Message

`privateMessage (0x01)` is an inner payload carrying a one-to-one message inside a `Noise session`. Its data is a [TLV-8](01-wire-format.md#81-tlv-8) sequence:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x00 | `messageID` | ≤255, UTF-8 | Sender-assigned identifier, echoed by [§4](#4-delivery-and-read-acknowledgement) acknowledgements. |
| 0x01 | `content` | ≤255, UTF-8 | Message text. |

### 3.3 Leave

`leave (0x03)` is a signed, plaintext, empty-payload broadcast a device sends when it is about to disconnect.

## 4. Delivery and Read Acknowledgement

`delivered (0x03)` and `readReceipt (0x02)` are inner payloads acknowledging a `privateMessage`. Each carries no TLV framing: the payload is the acknowledged message's `messageID` as raw UTF-8 bytes, verbatim.

## 5. Peer State and Capabilities

`authenticatedPeerState (0x21)` is an inner payload binding a peer's signing key and feature capabilities to the session, so a receiver need not trust the plaintext `announce` for this information. Its data is a 1-byte version tag followed by a [TLV-8](01-wire-format.md#81-tlv-8) sequence:

```
+---------+------------------------------+
| Version |             TLV              |
| 1 byte  |           variable           |
+---------+------------------------------+
```

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `capabilities` | 1–8 | `PeerCapabilities` bitfield ([§5.1](#51-peercapabilities-bitfield)), minimal little-endian encoding. |
| 0x02 | `signingPublicKey` | 32 | The peer's Ed25519 `signing key`. |

`version` MUST be `0x01`; a decoder MUST reject any other value. A decoder MUST reject a payload with a duplicate TLV entry, and MUST reject a `capabilities` TLV that is not the minimal (trailing-zero-byte-stripped) encoding described in [§5.1](#51-peercapabilities-bitfield).

### 5.1 `PeerCapabilities` Bitfield

`PeerCapabilities` is a little-endian bitfield, encoded as the fewest whole bytes needed to represent its highest set bit (at least 1 byte when non-empty; an encoder omits trailing all-zero bytes). A decoder accepts any length and keeps only the low 64 bits, so an unrecognized high bit set by a newer client round-trips without corrupting bits the decoder does understand. This encoding is used both standalone (`announce`'s `capabilities` TLV, [§2](#2-presence-announce)) and inside `authenticatedPeerState` ([§5](#5-peer-state-and-capabilities)).

| Bit | Name | Meaning |
|---|---|---|
| 0 | `prekeys` | Peer publishes `prekey bundle`s. |
| 1 | `wifiBulk` | Peer supports bulk transfer over a local Wi-Fi side channel. |
| 2 | `gateway` | Peer relays between the mesh and Nostr (see the Nostr Bridge chapter). |
| 3 | `groups` | Peer supports private groups ([§7](#7-private-groups)). |
| 4 | `board` | Peer supports board posts ([§6](#6-board-posts)). |
| 5 | `vouch` | Peer supports web-of-trust vouching ([§12](#12-web-of-trust-vouch)). |
| 6 | `meshDiagnostics` | Peer responds to `ping`/`pong` ([§10](#10-mesh-diagnostics)). |
| 7 | `bridge` | Peer advertises a Nostr bridge rendezvous geohash ([§2](#2-presence-announce)). |
| 8 | `privateMedia` | Peer accepts private files/voice over a session ([§8](#8-files), [§9](#9-voice)). |
| 9 | `privateMediaReceipts` | Peer sends delivery/read acknowledgements for private media. |
| 10 | `nonDestructiveNoiseReplacement` | Reserved; never advertised by a conforming encoder. |
| 11–63 | reserved | MUST be `0` on encode. A decoder MUST preserve, not reject on, an unrecognized set bit. |

## 6. Board Posts

`boardPost (0x23)` is a signed, plaintext broadcast (`BoardWire`) carrying a bulletin-board post or its deletion tombstone, scoped either to the local mesh (empty `geohash`) or to a Nostr Bridge geohash region. Its payload is a [TLV-16](01-wire-format.md#82-tlv-16) sequence:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `kind` | 1 | `0x01` post, `0x02` tombstone. Selects which of the remaining fields apply. |
| 0x02 | `postID` | 16 | Random identifier, shared between a post and its tombstone. |
| 0x03 | `geohash` | ≤12, UTF-8 | Empty for the mesh-local board; post only. |
| 0x04 | `content` | 1–512, UTF-8 | Post body; post only. |
| 0x05 | `authorSigningKey` | 32 | Author's Ed25519 `signing key`; both kinds. |
| 0x06 | `authorNickname` | ≤64, UTF-8 | Post only. |
| 0x07 | `createdAt` | 8 | Milliseconds since the Unix epoch; post only. |
| 0x08 | `expiresAt` | 8 | Milliseconds since the Unix epoch; MUST NOT exceed `createdAt` plus 7 days; post only. |
| 0x09 | `flags` | 1 | Bit 0 = urgent; post only. |
| 0x0A | `signature` | 64 | Ed25519 signature ([§6.1](#61-signing)); both kinds. |
| 0x0B | `deletedAt` | 8 | Milliseconds since the Unix epoch; tombstone only. |

A decoder MUST reject a payload whose `kind` is absent or unrecognized, or that is missing a field its `kind` requires.

### 6.1 Signing

A **post**'s `signature` covers, concatenated in this order: the ASCII context string `bitchat-board-v1`; `postID`; `geohash` and `content` each preceded by their own 2-byte big-endian length; `authorSigningKey`; `authorNickname` preceded by its 2-byte big-endian length; `createdAt`; `expiresAt`; and `flags`.

A **tombstone**'s `signature` covers: the ASCII context string `bitchat-board-del-v1`, `postID`, and `deletedAt`. Only the original post's `authorSigningKey` can produce a valid tombstone for it.

## 7. Private Groups

A private group's roster and symmetric key are distributed over a `Noise session` as `groupInvite (0x06)` or `groupKeyUpdate (0x07)` — the same wire shape (`GroupStatePayload`) for both; the two `NoisePayloadType` values distinguish an initial invite from a later key rotation or roster update, but nothing inside the payload itself does. A receiver MUST require that the `Noise session` peer delivering this payload be the group's creator, per [§7.1](#71-signing).

Its data is a [TLV-16](01-wire-format.md#82-tlv-16) sequence:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `groupID` | 16 | Random identifier. |
| 0x02 | `name` | variable, UTF-8 | Display name. |
| 0x03 | `key` | 32 | Symmetric ChaCha20-Poly1305 key for the epoch named below. |
| 0x04 | `epoch` | 4 | Big-endian; bumped on every key rotation. |
| 0x05 | `roster` | variable | Member list ([§7.2](#72-roster-encoding)). |
| 0x06 | `creatorFingerprint` | 32 | SHA-256 fingerprint of the creator's Noise `static key`. |
| 0x07 | `signature` | 64 | Ed25519 signature ([§7.1](#71-signing)) by the creator. |

A group has at most 16 members. A decoder MUST reject a payload with more than 16 roster entries, or whose `creatorFingerprint` does not match a fingerprint present in `roster`.

### 7.1 Signing

`signature` covers, concatenated: the ASCII context string `bitchat-group-v1`; `groupID`; `epoch` (4-byte big-endian); the SHA-256 hash of `key`; the SHA-256 hash of the encoded `roster`; and the SHA-256 hash of `name`'s UTF-8 bytes. A receiver MUST verify this signature against the signing key of the roster member whose fingerprint equals `creatorFingerprint`, and MUST reject the payload if that member is absent from the roster or the signature does not verify.

### 7.2 Roster Encoding

`roster` is a count byte followed by that many fixed-plus-length-prefixed entries, with no framing between entries:

```
+-------+-------------------------------------------------------+
| Count |                    Member × Count                     |
|1 byte |                                                        |
+-------+-------------------------------------------------------+
```

Each member entry is:

| Offset (within entry) | Length (bytes) | Field | Description |
|---|---|---|---|
| 0 | 32 | `fingerprint` | SHA-256 fingerprint of the member's Noise `static key`. |
| 32 | 32 | `signingKey` | The member's Ed25519 `signing key`. |
| 64 | 1 | `nicknameLength` | Length of the field below, in bytes. |
| 65 | `nicknameLength` | `nickname` | UTF-8, truncated to at most 64 bytes on a whole-character boundary. |

### 7.3 Group Message

`groupMessage (0x25)` is an outer, plaintext-framed broadcast whose payload (`GroupMessageEnvelope`) is a [TLV-16](01-wire-format.md#82-tlv-16) sequence:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `groupID` | 16 | Identifies the group; visible to relays. |
| 0x02 | `epoch` | 4 | Big-endian; visible to relays, so a stale-epoch message can be dropped without decrypting. |
| 0x03 | `nonce` | 12 | ChaCha20-Poly1305 nonce. |
| 0x04 | `ciphertext` | variable | AEAD ciphertext (message content, see [§7.4](#74-group-message-plaintext)) plus its 16-byte trailing tag. |

The AEAD is ChaCha20-Poly1305, keyed by the group's `key` for `epoch`, with associated data `groupID || epoch` (4-byte big-endian) — binding the envelope's visible routing fields to the ciphertext without encrypting them.

### 7.4 Group Message Plaintext

The AEAD plaintext, once decrypted, is itself a [TLV-16](01-wire-format.md#82-tlv-16) sequence:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `messageID` | variable, UTF-8 | Sender-assigned identifier. |
| 0x02 | `senderSigningKey` | 32 | The sending member's Ed25519 `signing key`, proving authorship within the group. |
| 0x03 | `senderNickname` | variable, UTF-8 | Sender's display name at send time. |
| 0x04 | `timestamp` | 8 | Milliseconds since the Unix epoch, big-endian. |
| 0x05 | `content` | variable, UTF-8 | Message text. |
| 0x06 | `signature` | 64 | Ed25519 signature by `senderSigningKey`. |

`signature` covers, concatenated: the ASCII context string `bitchat-group-msg-v1`; the enclosing envelope's `groupID` and `epoch` (4-byte big-endian); `messageID`; `timestamp` (8-byte big-endian); and `content`. A receiver MUST reject a group message whose `senderSigningKey` does not belong to a current member of the group, or whose signature does not verify.

## 8. Files

`privateFile (0x20)` (inner, carried in a `Noise session`) and `fileTransfer (0x22)` (outer, plaintext broadcast) share one wire body (`BitchatFilePacket`) for finalized file, image, and voice-note attachments. Its framing departs from both of this specification's general TLV grammars: it is 1-byte type plus a **2-byte big-endian length**, except the `content` field, whose length prefix is **4 bytes big-endian**:

| Type | Field | Length-field width | Description |
|---|---|---|---|
| 0x01 | `fileName` | 2 bytes | UTF-8, optional. |
| 0x02 | `fileSize` | 2 bytes | 4-byte big-endian `UInt32` byte count of `content`. |
| 0x03 | `mimeType` | 2 bytes | UTF-8, optional. |
| 0x04 | `content` | 4 bytes | Opaque file bytes. |

A decoder MUST additionally accept a legacy `fileSize` TLV whose length field reads `8` (an old 8-byte size encoding) and, if the 4-byte `content` length read does not fit the remaining bytes, MUST retry with a legacy 2-byte `content` length — both purely for backward decode compatibility; an encoder MUST NOT emit either legacy form.

An encoder MUST NOT emit a `content` field larger than 1 MiB (1,048,576 bytes) for a general file, or larger than 512 KiB (524,288 bytes) for a voice note or an image.

## 9. Voice

`voiceFrame (0x08)` (inner, private) and `voiceFrame (0x29)` (outer, public broadcast) share one wire body (`VoiceBurstPacket`) for a live push-to-talk audio burst. Unlike this chapter's other payloads, it is a fixed-field layout, not TLV:

```
+---------+-----+-------+------------------+
| BurstID | Seq | Flags |     Payload      |
| 8 bytes |2byte|1 byte |     variable     |
+---------+-----+-------+------------------+
```

| Offset | Length (bytes) | Field | Description |
|---|---|---|---|
| 0 | 8 | `burstID` | Identifies all frames of one burst. |
| 8 | 2 | `seq` | Big-endian sequence number within the burst. |
| 10 | 1 | `flags` | `0x01` START, `0x02` END, `0x04` CANCELED, `0x00` data. |
| 11 | variable | `payload` | Depends on `flags` (below). |

`payload`'s shape depends on `flags`:

| `flags` | `payload` |
|---|---|
| START (`0x01`) | 1 byte: `codec`. `0x01` = `aacLC16kMono` (AAC-LC, 16 kHz, mono, ~16 kbps) — the only codec this specification defines. |
| data (`0x00`) | Repeated `[length: 2 bytes big-endian][AAC frame: length bytes]` entries. |
| END (`0x02`) | `[totalDataPackets: 2 bytes big-endian][durationMs: 4 bytes big-endian]`. |
| CANCELED (`0x04`) | Empty. |

## 10. Mesh Diagnostics

`ping (0x26)` and `pong (0x27)` are outer, unencrypted, unsigned, directed packets used to probe reachability and hop distance. Both share the fixed 9-byte layout `MeshPingPayload`:

```
+---------+-----------+
|  Nonce  | OriginTTL |
| 8 bytes |  1 byte   |
+---------+-----------+
```

| Offset | Length (bytes) | Field | Description |
|---|---|---|---|
| 0 | 8 | `nonce` | Random for a `ping`; a `pong` echoes the `nonce` of the `ping` it answers. |
| 8 | 1 | `originTTL` | The packet's `ttl` ([Wire Format §2](01-wire-format.md#2-header-layout)) at the moment it was sent. |

A receiver computes hop count as `originTTL − receivedTTL + 1` (the `+ 1` counts the final delivery link); a `receivedTTL` greater than `originTTL` indicates an inconsistent or forged pair and MUST be treated as unmeasurable rather than a negative hop count. A decoder MUST accept a payload longer than 9 bytes, ignoring the excess, so a future revision can extend the format without breaking older clients.

## 11. Identity Verification

`verifyChallenge (0x10)` and `verifyResponse (0x11)` are inner payloads implementing an out-of-band identity check: a party who has learned a peer's expected Noise static key through a side channel (e.g. an in-person QR scan) issues a challenge over the live session, and the other side must prove possession of the matching private key. This specification defines only the two payloads' wire shape; the side channel that conveys the expected key is implementation-defined.

`verifyChallenge`'s data is a [TLV-8](01-wire-format.md#81-tlv-8) sequence:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `noiseKeyHex` | ≤255, ASCII | Hex encoding of the Noise `static key` the challenger expects the session peer to hold. |
| 0x02 | `nonceA` | ≤255 | Challenge nonce, chosen by the challenger. |

`verifyResponse`'s data is a [TLV-8](01-wire-format.md#81-tlv-8) sequence:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `noiseKeyHex` | ≤255, ASCII | Echoed from the challenge. |
| 0x02 | `nonceA` | ≤255 | Echoed from the challenge. |
| 0x03 | `signature` | ≤255 | Ed25519 signature ([below](#111-response-signing)) by the responder's `signing key`. |

### 11.1 Response Signing

`signature` covers, concatenated: the ASCII context string `bitchat-verify-resp-v1`; `noiseKeyHex`'s ASCII bytes preceded by their own 1-byte length; and `nonceA`. The challenger MUST verify this signature against the responder's known `signing key` before treating the identity as verified.

## 12. Web of Trust: Vouch

`vouch (0x12)` is an inner payload carrying a batch of transitive-verification attestations: a signed statement, made by the session peer sending this payload, that they have separately verified some third party's identity. The voucher's own identity is implicit — it is whoever holds the `Noise session` this payload arrives on — so a receiver authenticates an attestation against the session peer's announce-bound `signing key`, not against anything named inside the attestation itself.

The batch body is a count byte followed by that many length-prefixed attestations:

```
+-------+---------------------------------------------------+
| Count |              Attestation × Count                   |
|1 byte |                                                     |
+-------+---------------------------------------------------+
```

Each attestation entry is a 2-byte big-endian length followed by that many bytes of a [TLV-8](01-wire-format.md#81-tlv-8)-encoded attestation:

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `voucheeFingerprint` | 32 | SHA-256 fingerprint of the vouched-for party's Noise `static key`. |
| 0x02 | `voucheeSigningKey` | 32 | The vouched-for party's Ed25519 `signing key`. |
| 0x03 | `timestamp` | 8 | Milliseconds since the Unix epoch, big-endian. |
| 0x04 | `signature` | 64 | Ed25519 signature ([below](#121-attestation-signing)) by the voucher's `signing key`. |

A batch MUST NOT carry more than 16 attestations. A receiver MUST reject an attestation whose `timestamp` is more than 30 days in the past or more than 1 hour in the future.

### 12.1 Attestation Signing

`signature` covers, concatenated: the ASCII context string `bitchat-vouch-v1`, `voucheeFingerprint`, `voucheeSigningKey`, and `timestamp` (8-byte big-endian). A receiver MUST verify this signature against the sending `Noise session` peer's announce-bound `signing key`.
