# Nearsend Chat protocol v2

Implemented identically by `NearsendChatiOS` (Swift) and `NearsendChatAndroid` (Kotlin). Both are tested against the
vectors below and against the same relay scenarios (`NearsendChatiOS/Tests/main.swift`,
`NearsendChatAndroid/app/src/test/.../ProtocolTest.kt`; both run in CI).
Not related to the Bitchat protocol.

## 1. Link layer (Bluetooth LE)

Every phone is both a **GATT server** (advertises the service) and a **GATT client** (scans, connects to everyone it finds).
No pairing. Each phone therefore holds a central link to each neighbour; to reach a neighbour you write to *their* server.

| | UUID | Access |
|---|---|---|
| Service | `7A3C5E10-9D2B-4F6A-8C1E-4E4541525345` | advertised |
| Identity characteristic | `7A3C5E11-9D2B-4F6A-8C1E-4E4541525345` | read |
| Packet characteristic | `7A3C5E12-9D2B-4F6A-8C1E-4E4541525345` | write (with response) |

Identity value (JSON): `{"id": "<device id>", "name": "<nickname>", "pk": "<base64 X25519 public key, 32 bytes>"}`.
A phone is a *neighbour* once its identity has been read. Signal strength (RSSI) of the link is polled every 2 s.
Packets are limited to 512 bytes (one ATT long write).

## 2. Packets

JSON object, optional fields omitted when absent.

| field | meaning |
|---|---|
| `v` | protocol version, `2` |
| `t` | `ann` (announce) · `msg` (direct message) · `pub` (public channel) · `ack` (delivery receipt) |
| `id` | unique packet id (for `msg`: the message id) |
| `src` | sender device id |
| `dst` | destination device id (`msg`, `ack`); absent for broadcasts |
| `ttl` | remaining hops; the sender starts at **5** |
| `ts` | sender clock, ms since epoch (informational) |
| `n` | sender nickname |
| `pk` | `ann`: base64 public key |
| `ct` | `msg`: base64 sealed text (section 4) |
| `tx` | `pub`: plain text |
| `ref` | `ack`: id of the acknowledged message |

Text is limited to **180 UTF-8 bytes** (cut on a character boundary).

## 3. Relaying

- Every phone sends an `ann` (ttl 5) to its neighbours when a neighbour connects and then every **8 s**.
- A receiver ignores packets it has seen (`id` cache of the last 1500) or that it sent itself.
- `hops = 6 - ttl` as received (a direct neighbour's packet arrives with ttl 5, so hops = 1).
- Otherwise it handles the packet and, if `ttl > 1`, forwards it with `ttl - 1` to all neighbours except the one it came from.
  Packets with a `dst` that is a direct neighbour go only to that neighbour.
- `ann` creates/refreshes a peer entry (name, key, hops). Relayed peers not heard from for **40 s** are dropped; direct
  neighbours are dropped when the link is lost. Reach is therefore at most **5 hops**.
- `msg` for me: decrypt, show, reply with an `ack`. `pub`: show. `ack` for me: mark the message delivered.
- Messages to a peer that is not currently known stay queued in the app and are sent when the peer appears (give up after 10 min).

## 4. Direct-message encryption

```
shared = X25519(my private key, peer public key)
key    = HKDF-SHA256(ikm = shared, salt = "nearsend-chat-v2", info = sorted([myId, peerId]).join("|"), 32 bytes)
sealed = nonce(12 random bytes) || ChaCha20-Poly1305(key, nonce, plaintext = UTF-8 text, aad = message id) || tag(16)
```
`ct` is `base64(sealed)`. The message id is authenticated, so a ciphertext cannot be replayed under another id.

**Fingerprint** = first 16 bytes of `SHA-256(public key)`, shown as 8 groups of 4 hex digits in two lines
(`AAA8 FFF7 03B5 0B22` / `97F4 F6E1 3508 F724`). People compare fingerprints in person and tap "Mark as verified".

### Test vector (generated with Python `cryptography`)

```
private key A  0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20
private key B  65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384
public key A   07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c
public key B   5714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c36
ids            alice (A), bob (B)         message id (aad)  m-1
derived key    ed8ca2aba1397ffeb4c22c4c2eeb86de13003eb87640dc3749cdd1bc58b4d756
nonce          c8c9cacbcccdcecfd0d1d2d3
sealed         c8c9cacbcccdcecfd0d1d2d3b7f7d3789adc70b46a831626878bc5809086ac2253d1ba553d06af4445a5b4c525
plaintext      "Hej världen 👋"
fingerprint A  AAA8 FFF7 03B5 0B22 / 97F4 F6E1 3508 F724
```

## 5. What this does **not** protect against (read before relying on it)

- **Not audited.** Custom protocol built from standard primitives; no third-party review.
- **Announcements are unauthenticated.** Anyone can claim any id/name/key. A person in the middle could substitute a key
  until the two people compare fingerprints in person. Unverified chats are encrypted but not authenticated.
- **No forward secrecy:** keys are long-lived; stealing a phone's key exposes recorded traffic to/from it.
- **Metadata is visible** to anyone in range and to relays: sender id/nickname, destination id, packet sizes and timing.
- **Public channel** messages are plain text and can be spoofed (no signatures).
- No replay protection beyond the id cache; no rate limiting or spam control; relays can drop or delay packets.
- Bluetooth advertising reveals that a phone runs Nearsend Chat.
