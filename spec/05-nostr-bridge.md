# 05 — Nostr Bridge

**Spec:** 1.0.1  
**Canonical prose:** `WHITEPAPER.md` §5.3, §6.4; `README.md`;
`docs/GeohashPresenceSpec.md`

BitChat uses public Nostr relays as an **internet mailbox and geohash
broadcast** transport. This chapter is intentionally shorter than the mesh
chapters: relay selection details for external publishers are tracked in
issue [#1473](https://github.com/permissionlesstech/bitchat/issues/1473).

---

## 1. Compatibility warning (normative)

BitChat private envelopes reuse NIP-17 / NIP-59 **kind numbers** but are
**not** NIP-17, NIP-44, or NIP-59 compatible.

- Interoperates **only** with BitChat clients.
- Content fields are **not** NIP-44 ciphertext.
- Do not expect vanilla Nostr DM clients to decrypt BitChat private mail.

---

## 2. Private envelope sketch

High-level construction (see whitepaper for motivation):

1. Inner unsigned message (kind **14** semantics).
2. Encrypted into a sender-signed seal (kind **13**).
3. Seal wrapped again in a public envelope (kind **1059**) signed by a
   one-time key so relays do not learn the stable sender identity.

Each encrypted content field:

```
"v2:" || base64url( 24-byte nonce || XChaCha20-Poly1305 ciphertext+tag )
```

Key schedule: secp256k1 ECDH + HKDF-SHA256. The HKDF info label reuses a
`nip44-v2` string for historical reasons but is **not** the NIP-44 schedule.

Properties:

- Outer `p` tag exposes the recipient Nostr pubkey to relays.
- Public timestamps are jittered (±15 minutes); real timestamp is inside
  ciphertext.
- **No forward secrecy** on this path: compromise of the recipient Nostr
  private key can expose stored envelopes.

---

## 3. Geohash public channels

| Kind | Role |
|------|------|
| `20000` | Geohash chat message |
| `20001` | Ephemeral presence heartbeat |

Presence rules (precision caps, heartbeat cadence, participant counting) are
normative in `docs/GeohashPresenceSpec.md` and should be treated as part of
the location-channel contract.

Tags typically include `["g", "<geohash>"]`. Presence content is empty and
omits nickname tags.

---

## 4. Mesh ↔ Nostr carriers

Mesh type `nostrCarrier` (`0x28`) ferries a signed Nostr event between a
mesh-only peer and an internet gateway peer advertising the `gateway` /
`bridge` capabilities. Gateway behaviour is an application policy on top of
the wire type; do not assume every peer will uplink.

---

## 5. Relay interaction (non-normative until #1473 lands)

Reference clients:

- Maintain a geo-proximity relay directory (~300 relays).
- Subscribe to a small set of relays near the active geohash
  (`nostrGeoRelayCount` default 5 in `TransportConfig`).
- Re-subscribe with lookback (DMs ~24 h; geohash chat shorter windows) on
  reconnect.

External publishers that pin an arbitrary fixed relay set may never intersect
the subscriber's geo-selected set — replicate proximity selection or publish
widely enough to overlap.

---

## 6. Implementer checklist

- [ ] Treat BitChat private envelopes as proprietary, not NIP-44.
- [ ] Implement `v2:` + base64url XChaCha20-Poly1305 content encoding.
- [ ] Support kinds 20000/20001 for geohash chat/presence.
- [ ] Do not claim NIP-17/44/59 compatibility in client metadata.
