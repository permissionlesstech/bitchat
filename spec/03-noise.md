# Noise

This chapter defines bitchat's use of the Noise Protocol Framework: the `XX` handshake pattern and post-handshake transport framing for live, bidirectional sessions between connected peers, and the one-way `X` pattern used to seal store-and-forward mail (`courier envelope`s) when no live session exists. It also defines the `prekeyBundle` wire packet, which provisions the one-time keys the `X` path seals against.

It does not define the field catalog of application payloads carried inside a live session (see the Payloads chapter) or the `courierEnvelope` TLV that wraps an `X`-sealed message for physical or relayed carriage (see the Store and Forward chapter) — only the cryptographic framing those chapters build on.

## 1. Cipher Suite

Both handshake patterns in this chapter use the same primitives: Curve25519 for Diffie-Hellman, ChaCha20-Poly1305 for AEAD, and SHA-256 for hashing and key derivation — `Noise_XX_25519_ChaChaPoly_SHA256` for §2 and `Noise_X_25519_ChaChaPoly_SHA256` for §4.

## 2. Live Sessions: the XX Pattern

Two peers with an active BLE connection establish a `Noise session` with the interactive, mutually-authenticating `XX` pattern before exchanging any private payload.

### 2.1 Handshake Message Sequence

```
Initiator                              Responder
---------                              ---------
-> e                                   32 bytes
<- e, ee, s, es                        96 bytes
-> s, se                               48 bytes
```

| Message | Direction | Tokens | Size (bytes) | Contents |
|---|---|---|---|---|
| 1 | initiator → responder | `e` | 32 | initiator's ephemeral public key, cleartext |
| 2 | responder → initiator | `e, ee, s, es` | 96 | responder's ephemeral public key (32 bytes, cleartext), then responder's static public key encrypted under the running key (32-byte ciphertext + 16-byte Poly1305 tag) |
| 3 | initiator → responder | `s, se` | 48 | initiator's static public key encrypted under the running key (32-byte ciphertext + 16-byte Poly1305 tag) |

A handshake message MUST NOT exceed 2048 bytes.

On completion of message 3, both sides derive a pair of directional transport cipher keys via the standard Noise `Split()` function: the initiator's send key is the responder's receive key, and vice versa.

### 2.2 Wire Carriage of Handshake Messages

Each handshake message's bytes, exactly as produced in [§2.1](#21-handshake-message-sequence), ride **unwrapped** as the entire `payload` section of a `noiseHandshake (0x10)` packet (see the Wire Format chapter's [Message Types](01-wire-format.md#7-message-types)). No additional TLV or length framing wraps a handshake message; the packet header's `payloadLength` field already bounds it.

## 3. Post-Handshake Transport

Once a session's transport ciphers are derived ([§2.1](#21-handshake-message-sequence)), every subsequent private message between the two peers is carried as a `noiseEncrypted (0x11)` packet.

### 3.1 Transport Ciphertext Framing

A `noiseEncrypted` packet's `payload` section is:

```
+------------------+-------------------------------+----------------+
|      Nonce       |          Ciphertext            |      Tag      |
|     4 bytes       |          variable              |    16 bytes    |
+------------------+-------------------------------+----------------+
```

| Offset | Length (bytes) | Field | Description |
|---|---|---|---|
| 0 | 4 | `nonce` | Big-endian message counter for this direction, prefixed explicitly rather than left implicit. |
| 4 | variable | `ciphertext` | The AEAD ciphertext of the application payload described in [§3.3](#33-application-payload-framing). |
| — | 16 | `tag` | ChaCha20-Poly1305 authentication tag, immediately following the ciphertext. |

The decrypted application plaintext MUST NOT exceed 65,535 bytes.

### 3.2 Replay Protection

A receiver validates an inbound `nonce` against a sliding window of the 1024 most recently accepted nonces for that direction. A receiver MUST reject a message whose `nonce` falls before the window or has already been accepted within it.

### 3.3 Application Payload Framing

The AEAD plaintext decrypted from a `noiseEncrypted` packet is itself framed as a 1-byte type tag followed by type-specific data, with no explicit length prefix — the boundary is the decrypted plaintext's own length:

```
+------+-------------------+
| Type |       Data        |
|1 byte|      variable     |
+------+-------------------+
```

| Value | Name |
|---|---|
| 0x01 | `privateMessage` |
| 0x02 | `readReceipt` |
| 0x03 | `delivered` |
| 0x06 | `groupInvite` |
| 0x07 | `groupKeyUpdate` |
| 0x08 | `voiceFrame` |
| 0x10 | `verifyChallenge` |
| 0x11 | `verifyResponse` |
| 0x12 | `vouch` |
| 0x20 | `privateFile` |
| 0x21 | `authenticatedPeerState` |

A decoder MUST also accept `0x09` as a legacy-decode alias for `privateFile (0x20)`, but MUST NOT emit `0x09` when encoding.

The field catalog for each of these types — including `authenticatedPeerState`, which binds a peer's signing key and capabilities to the session — is defined in the Payloads chapter.

## 4. Offline Seals: the X Pattern

When no live session exists to a recipient, a sender may instead seal a message directly to a key the recipient has published, using the one-way `X` pattern, and hand the result to a `courier envelope` for physical or relayed carriage (see the Store and Forward chapter).

### 4.1 Handshake Message

`X` is a single-message pattern: `-> e, es, s, ss`.

| Tokens | Size (bytes) | Contents |
|---|---|---|
| `e` | 32 | sender's ephemeral public key, cleartext |
| `es, s, ss` | 48 | sender's static public key encrypted under the running key (32-byte ciphertext + 16-byte Poly1305 tag) |

As with the `XX` handshake, this message MUST NOT exceed 2048 bytes. Because `X` is a one-way pattern, the sealed application payload is appended to the same message as AEAD ciphertext, encrypted under the key established immediately after the `s` token — the standard Noise mechanism for attaching a payload to a one-way handshake, and how a single `X` message doubles as a seal operation rather than a bare handshake. The resulting bytes (handshake fields plus sealed payload) are opaque to any party other than the recipient, and are carried as-is in the enclosing `courierEnvelope`'s `ciphertext` field (see the Store and Forward chapter).

### 4.2 Courier Envelopes

The default case seals to the recipient's long-term `static key` (see [glossary](README.md#glossary)), known to the sender from the recipient's `announcement` or prior verification. This path has **no forward secrecy**: a party who later compromises the recipient's static key can decrypt any previously captured seal made against it.

### 4.3 Prekey Envelopes

A sender who instead holds one of the recipient's published one-time `prekey`s seals to that prekey's public key rather than the recipient's static key. Because a prekey is consumed and discarded after a single use, this path provides forward secrecy that [§4.2](#42-courier-envelopes) lacks: compromising the recipient's long-term static key does not expose envelopes sealed under an already-discarded prekey. The enclosing `courierEnvelope`'s optional `prekeyID` field (see the Store and Forward chapter) identifies which prekey the sender consumed, so the recipient knows which private prekey to use in opening the seal.

A prekey MUST NOT be reused across more than one seal; once consumed, it MUST be discarded from future `prekeyBundle`s ([§5](#5-prekey-bundles)).

## 5. Prekey Bundles

A `prekey bundle` is how a device publishes a batch of one-time prekeys for other peers to seal [§4.3](#43-prekey-envelopes) envelopes against.

### 5.1 Wire Packet

A prekey bundle is carried as the payload of a `prekeyBundle (0x24)` packet (see the Wire Format chapter's [Message Types](01-wire-format.md#7-message-types)), using the TLV-16 framing (see the Wire Format chapter's [§8.2](01-wire-format.md#82-tlv-16)).

### 5.2 Fields

| Type | Field | Length (bytes) | Description |
|---|---|---|---|
| 0x01 | `noiseStaticPublicKey` | 32 | The issuing peer's long-term Curve25519 static public key, included so a recipient can validate the bundle's signature ([§5.3](#53-signature)) without a separate lookup. |
| 0x02 | `prekeys` | variable | Repeated fixed-size entries (see [§5.2.1](#521-prekey-entry)). A sender MUST NOT include more than 8 entries in a single bundle. |
| 0x03 | `generatedAt` | 8 | Milliseconds since the Unix epoch at which the bundle was generated. |
| 0x04 | `signature` | 64 | Ed25519 signature over the preceding fields, using the issuing peer's `signing key`. |

#### 5.2.1 Prekey Entry

Each entry in the `prekeys` field is 36 bytes, with no further framing between consecutive entries:

| Offset (within entry) | Length (bytes) | Field | Description |
|---|---|---|---|
| 0 | 4 | `prekeyID` | Big-endian identifier for this prekey, referenced by a `courierEnvelope`'s `prekeyID` field (see the Store and Forward chapter) once consumed. |
| 4 | 32 | `publicKey` | The one-time Curve25519 public key ([§4.3](#43-prekey-envelopes)). |

### 5.3 Signature

A recipient MUST verify the `signature` field against the issuing peer's known `signing key` before trusting any prekey the bundle carries, and MUST discard the bundle if verification fails.
