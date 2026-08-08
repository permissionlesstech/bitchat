# 03 — Noise Handshake and Encrypted Transport

**Spec:** 1.0.1  
**Canonical source:** `bitchat/Noise/NoiseProtocol.swift`,  
`NoiseSession.swift`, `NoiseEncryptionService.swift`,  
`bitchat/Protocols/BitchatProtocol.swift` (`NoisePayloadType`)  
**Background:** `BRING_THE_NOISE.md`, `WHITEPAPER.md` §5

---

## 1. Crypto suite

| Component | Choice |
|-----------|--------|
| DH | X25519 (Curve25519.KeyAgreement) |
| AEAD | ChaCha20-Poly1305 |
| Hash | SHA-256 |
| KDF | HKDF-SHA256 |
| Packet / announce signatures | Ed25519 (separate signing keypair) |

Protocol names used on the wire (Noise naming):

| Use | Name | Prologue |
|-----|------|----------|
| Live mesh session | `Noise_XX_25519_ChaChaPoly_SHA256` | empty |
| Courier seal v1 | `Noise_X_25519_ChaChaPoly_SHA256` | UTF-8 `bitchat-courier-v1` |
| Prekey seal v2 | `Noise_X_25519_ChaChaPoly_SHA256` | UTF-8 `bitchat-prekey-v1` ‖ `uint32 BE prekeyID` |

`IK` / `NK` appear in the Noise module but are **not** used for live mesh
sessions in the reference clients.

---

## 2. Live sessions: Noise XX

Pattern:

```
XX:
  -> e
  <- e, ee, s, es
  -> s, se
```

Application payloads inside handshake messages are **empty** in production
(handshake blobs contain only Noise tokens / AEAD wrappers).

### 2.1 Message sizes (empty payload)

| Msg | Direction | Contents (summary) | Typical size |
|-----|-----------|--------------------|--------------|
| 1 | Initiator → Responder | raw ephemeral pubkey `e` (32) | **32** |
| 2 | Responder → Initiator | `e`(32) + `Encrypt(s)`(48) + `Encrypt(∅)`(16) | **96** |
| 3 | Initiator → Responder | `Encrypt(s)`(48) + `Encrypt(∅)`(16) | **64** |

`Encrypt(s)` is a 32-byte static public key under ChaChaPoly → 32 + 16 tag = 48
once a cipher key exists. Before a key is mixed, Noise returns plaintext.

### 2.2 Mapping onto mesh packets

| Noise step | `MessageType` | Packet fields |
|------------|---------------|---------------|
| XX msg 1/2/3 | `noiseHandshake` (`0x10`) | `payload` = handshake blob; `recipientID` = 8-byte peer; `signature` = nil; TTL default 7 |
| Transport | `noiseEncrypted` (`0x11`) | `payload` = transport ciphertext (below); directed; typically padded |

Which of the three XX messages a `0x10` packet carries is determined solely by
session state — there is no extra discriminator byte.

Handshake timeouts in the reference stack: ordinary ~10 s; responder quarantine
~20 s; max handshake message 2048 bytes.

---

## 3. Transport ciphertext (post-handshake)

Live sessions enable **extracted nonces** (`useExtractedNonce = true`):

```
[4 bytes nonce BE][ciphertext…][16 bytes Poly1305 tag]
```

ChaChaPoly nonce construction for the AEAD call: 12-byte buffer with the
64-bit counter in bytes **4…11 little-endian** (bytes 0…3 zero).

Overhead versus plaintext: **20** bytes (4 nonce + 16 tag).

Receivers apply sliding-window replay protection on the extracted 4-byte
counter. Nonces beyond `UInt32.max − 1` force rekey / error.

> **Conformance note:** Official Noise explorer vectors in
> `bitchatTests/Noise/NoiseTestVectors.json` use non-empty prologues/payloads
> and transport **without** extracted nonces. Those vectors validate the crypto
> core; they are **not** byte-identical to production XX mesh traffic.

---

## 4. Inner plaintext after decrypt

```
[1 byte NoisePayloadType][type-specific data…]
```

| Value | Name | Inner format (summary) |
|-------|------|------------------------|
| `0x01` | `privateMessage` | TLV `0x00` messageID, `0x01` content (1-byte lengths, ≤255 each) |
| `0x02` | `readReceipt` | UTF-8 original message ID |
| `0x03` | `delivered` | UTF-8 message ID |
| `0x06` | `groupInvite` | creator-signed group state |
| `0x07` | `groupKeyUpdate` | creator-signed key/roster update |
| `0x08` | `voiceFrame` | `VoiceBurstPacket` |
| `0x10` | `verifyChallenge` | QR verification challenge bytes |
| `0x11` | `verifyResponse` | QR verification response bytes |
| `0x12` | `vouch` | vouch attestation batch |
| `0x20` | `privateFile` | full `BitchatFilePacket` (encrypted *before* outer BLE fragmentation) |
| `0x21` | `authenticatedPeerState` | versioned TLV peer state (see payloads) |
| `0x09` | *(legacy alias)* | Decode-only alias for `privateFile`; **MUST NOT** emit |

Unknown payload types **MUST** be ignored without tearing down the session.

Detailed TLV layouts: [`04-payloads.md`](04-payloads.md).

---

## 5. Offline seals: Noise X

### 5.1 Courier v1 (static key)

1. MixHash prologue `bitchat-courier-v1`.
2. Pre-message: mix recipient static public key into handshake hash.
3. Single initiator message: `e, es, s, ss` + encrypted application payload.
4. Ciphertext has **no** 4-byte extracted nonce prefix (handshake AEAD only).
5. Rough size: `32 + 48 + (payloadLen + 16)` plus any unencrypted token bytes
   per Noise X.

No forward secrecy: compromise of the recipient static key exposes captured
sealed mail. Prefer live XX sessions when the peer is reachable.

The ciphertext is wrapped in a `CourierEnvelope` TLV carried as mesh type
`0x04` — see payloads.

### 5.2 Prekey v2 (forward-secret)

Same X pattern, but the responder static is a **one-time prekey** from a
gossiped `PrekeyBundle` (`0x24`). Prologue:

```
"bitchat-prekey-v1" || uint32_be(prekeyID)
```

Envelope TLV includes optional `prekeyID` (`0x05`) so carriers can forward
opaquely; old clients that only know v1 still carry the bytes and fail open
quietly if addressed to them without the matching prekey.

---

## 6. Authenticated peer state

After XX completes, peers exchange `authenticatedPeerState` (`0x21`) inside the
session to pin capabilities and the Ed25519 signing key under Noise
authentication. Public announce TLVs remain discovery hints and are not a
substitute for this proof.

---

## 7. Implementer checklist

- [ ] Implement XX with empty prologue and empty handshake payloads.
- [ ] Map handshake blobs to `MessageType 0x10` and transport to `0x11`.
- [ ] Use extracted 4-byte BE nonce prefix on transport frames.
- [ ] Prefix decrypted plaintext with `NoisePayloadType`.
- [ ] Seal courier mail with prologue `bitchat-courier-v1` (pattern X).
- [ ] Seal prekey mail with `bitchat-prekey-v1` ‖ prekeyID.
- [ ] Pass `NoiseTestVectors.json` for the crypto core (knowing the production
      divergence above).
