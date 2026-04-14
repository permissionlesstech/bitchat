# RFC: Private Swap Meet via Diffie-Hellman PSI

**Author:** bigwill
**Date:** 2026-04-10
**Status:** Draft
**Target:** bitchat protocol extension (iOS + Android)

## Abstract

This RFC proposes a Swap Meet feature for bitchat that enables two nearby users to discover mutual trading interest — what each has that the other wants — without revealing non-matching items. The protocol uses Diffie-Hellman Private Set Intersection (DH-PSI) over the existing BLE mesh transport.

DH-PSI is lightweight: a complete swap exchange between two users with 20 items each requires ~3.9KB of total transmission — small enough to complete in seconds over a single BLE connection.

## Motivation

In crisis scenarios where bitchat sees real adoption, communities coordinate resource trading: medicine, batteries, food, SIM cards, clothing. Currently this requires verbally announcing what you have and need to nearby strangers, or sharing full lists openly — revealing your complete inventory to everyone you interact with.

Swap Meet replaces this with a private, frictionless protocol. Two phones discover mutual trading interest automatically — no verbal negotiation, no list-sharing, no per-peer interaction required. Users configure their wants and haves once, and every nearby swap-enabled peer is checked in the background. Only matching items are ever revealed.

The protocol protects against **honest-but-curious peers** — people you're willing to trade with but don't fully trust with your complete inventory. It does not, on its own, protect against a determined adversary who controls many devices and probes systematically (see Security section for mitigations).

## User Experience

Alice is in a crisis area and needs batteries and a SIM card. Bob nearby has extra batteries and is looking for water purification tablets.

1. Alice opens Swap Meet and browses a categorized catalog (medical, power, communication, food/water). She selects her WANTS and HAVES.
2. Alice activates swap mode. A badge or indicator shows she's discoverable.
3. Bob nearby has also configured his wants and haves and is in swap mode.
4. Their devices discover each other via BLE and run the DH-PSI exchange automatically in the background — takes 1-2 seconds. No manual per-peer interaction needed.
5. Both devices notify their users of matches. Alice sees "Bob has: battery_aa". Bob sees "Alice has: water_purification".
6. Neither sees the other's non-matching items.
7. Alice taps "Chat about batteries" → opens a private chat to coordinate the physical trade.

## Why DH-PSI

A plaintext exchange of haves/wants lists is simple, but reveals a user's complete inventory to anyone who initiates a swap. DH-PSI provides strong privacy with minimal overhead: each party blinds their haves and wants lists with a secret exponent, exchanges the blinded values, and each side double-exponentiates the other's values to find matches — ~32 bytes per item (one Ristretto255 point), for 20 items ~640 bytes per direction and ~20ms of computation. Simple, well-understood, and fits comfortably within BLE constraints.

**What DH-PSI hides:**
- Non-intersecting items. If Alice wants X and Bob doesn't have X, Bob learns nothing about Alice wanting X.

**What DH-PSI reveals:**
- **Set sizes.** Both parties learn how many items the other is querying. This can be mitigated by padding sets with random points to a fixed size, but even without padding, visible set sizes provide a natural defense — if someone queries 500 items, that's suspicious and you can refuse to meet in person.
- **The intersection** (by design — this is the feature).

## Protocol

### Item Encoding

Items are drawn from a shared catalog. Each item has a canonical string identifier (e.g., `"battery_aa"`, `"bandage_large"`, `"sim_card_local"`). Items are hashed to Ristretto255 group elements:

```
item_point = ristretto255_from_hash(SHA512("bitchat-swap-v1:" || item_id))
```

Ristretto255 is used rather than raw Curve25519 to avoid cofactor-related correctness and security issues in the equality check. SHA-512 is used (not SHA-256) because `ristretto255_from_hash` requires 64 bytes of input for uniform distribution over the group. libsodium (`crypto_core_ristretto255_from_hash`) and swift-sodium already expose this operation.

### Message Types

One announcement extension and two new `NoisePayloadType` values:

```
AnnouncementPacket TLV 0x05: swapFlags (1 byte bitmask)
  Bit 0: Swap mode active
  Bit 1: Swap marked urgent (critical needs — medical, water)

NoisePayloadType:
  swapInit     = 0x30   // Initiate swap session
  swapExchange = 0x31   // Blinded sets or double-blinded response
```

All swap messages are carried inside `MessageType.noiseEncrypted (0x11)` packets, using the existing `BitchatPacket` framing. The `0x30`/`0x31` values are payload types inside the decrypted Noise envelope — they never appear on the wire unencrypted. No new encryption layer or top-level message types are needed.

### Flow

**Goal:** Alice learns (Alice's WANTS) ∩ (Bob's HAVES), and Bob learns (Bob's WANTS) ∩ (Alice's HAVES).

```
Phase 1: Discovery (unencrypted broadcast)
  Alice's ANNOUNCE includes swapFlags TLV (+3 bytes)
  Bob's device sees swap-active peer

Phase 2: Noise Handshake (0x10, if no session exists)
  If no established Noise session exists, the party with the
  lexicographically lower Noise static public key initiates a
  standard Noise XX handshake. Both parties already know each
  other's Noise static keys from the ANNOUNCE packet (TLV 0x02),
  so both can compute the tiebreaker independently.
  If a session already exists, this phase is skipped.
  Session recovery: if a peer receives an encrypted swap message it
  cannot decrypt (e.g., the other side's session was lost to a
  restart), it initiates a fresh Noise handshake. The swap restarts
  from Phase 3 after the new session is established.

Phase 3: Swap Init (0x30, Noise-encrypted)
  The party with the lexicographically lower Noise static public key
  sends swapInit. Both parties can determine this independently,
  preventing duplicate exchanges.
  
  Initiator → Responder: { session_id, protocol_version }

Phase 4: Swap Exchange Round 1 (0x31 step=1, Noise-encrypted)
  Each party picks two independent random secret exponents — one for
  wants (a_w, b_w) and one for haves (a_h, b_h) — and blinds their
  items. Order doesn't matter — each sends once init is received/sent:
  
  Alice → Bob: { session_id, step: 1,
    blinded_wants: [H(w)^(a_w) for w in WANTS],   // 32 bytes each
    blinded_haves: [H(h)^(a_h) for h in HAVES] }
  Bob → Alice: (same structure, exponents b_w, b_h)

Phase 5: Swap Exchange Round 2 (0x31 step=2, Noise-encrypted)
  Each party double-blinds the other's WANTS with their own HAVES
  exponent and sends back in the same positional order as round 1.
  Each party locally double-blinds the other's HAVES with their own
  WANTS exponent. This cross-role pairing ensures only
  wants ∩ counterparty haves is computable.

  Alice → Bob: { session_id, step: 2,
    double_blinded_wants: [W_b^(a_h) for each of Bob's wants] }
  Bob → Alice: { session_id, step: 2,
    double_blinded_wants: [W_a^(b_h) for each of Alice's wants] }
  
  Round 2 arrays MUST preserve the positional order from round 1
  so the receiver can identify which specific items matched.

  Alice locally computes: [H_b^(a_w) for each of Bob's haves]
  Bob locally computes: [H_a^(b_w) for each of Alice's haves]

Phase 6: Local Intersection (no network traffic)
  For Alice_WANTS ∩ Bob_HAVES: H(item)^(a_w · b_h) appears in both.
  For Bob_WANTS ∩ Alice_HAVES: H(item)^(b_w · a_h) appears in both.
  Non-matching items produce unrelated group elements → no leak.

Phase 7: Chat (optional)
  Chat opens only when BOTH sides found matches (two-way barter).
  The party with the lexicographically lower Noise static public
  key initiates the chat over the existing Noise session.
  Sessions not completed within 30 seconds are silently discarded.
```

Note: Round 2 only transmits the double-blinded wants, not both wants and haves. Each party already has the other's blinded haves from round 1 and can double-blind them locally. This halves the round 2 payload.

### Message Sizes

| Message | 20 wants, 20 haves |
|---------|---------------------|
| swapInit (one-way) | 19 bytes |
| swapExchange round 1 (each direction) | 17 + 32×(N+M) = 1,297 bytes |
| swapExchange round 2 (each direction) | 17 + 32×N' = 657 bytes |
| **Total both directions** | **~3,927 bytes** |

N' in round 2 = the other party's number of wants (each party only sends back the double-blinded wants, not haves). For comparison: a typical bitchat chat message is 200-500 bytes, a file transfer is 10KB-1MB. A swap exchange sits between the two. No special transport handling needed.

## Catalog

Items are drawn from a versioned catalog distributed with the app:

```json
{
  "version": "1",
  "categories": {
    "medical": ["bandage_small", "bandage_large", "antiseptic", "painkillers", ...],
    "power": ["battery_aa", "battery_aaa", "powerbank", "solar_charger", ...],
    "communication": ["sim_card_local", "sim_card_intl", "radio_handheld", ...],
    "food_water": ["water_bottle", "water_purification", "ration_pack", ...],
    "exchange": ["cash_local", "cash_usd", "labor", "barter_open"]
  }
}
```

**Why a shared catalog (not free-text):**
- Hash-to-group requires both parties to use the same string for the same item
- Free-text matching ("bandages" vs "bandage" vs "first aid supplies") would fail silently
- Catalog can be localized (translated item names map to canonical IDs)
- Catalog updates can be distributed via mesh (small JSON, versioned)

Initial catalog: ~100-200 items across categories relevant to crisis scenarios. For items not in the catalog, a free-text extension is supported where both parties must type the same string for a match. Both sides normalize free-text before hashing: NFC Unicode normalization, then locale-independent Unicode lowercase (ICU `toLower` with no locale). This preserves non-Latin scripts while ensuring cross-platform determinism.

## Security

**Non-matching items hidden:** The blinded group element `H(X)^a` is computationally indistinguishable from random in Ristretto255.

**Role separation:** Each party uses independent exponents for wants and haves. A single shared exponent would allow either party to compute wants ∩ counterparty wants (mutual unmet demand), leaking sensitive need information even when no trade is possible. Separate exponents ensure only the intended cross-role intersections (wants ∩ counterparty haves) are computable.

**Session isolation:** Each swap session uses fresh random exponents. Results from one session can't be correlated with another. Toggling swap mode off and back on generates fresh state.

**Observable behavior during the swap exchange is identical** whether there's a match or not. A subsequent private chat is observable but reveals only that a match occurred, not what matched.

### Adversarial Probing

The protocol protects against honest-but-curious peers. It does **not** protect against a determined adversary who controls multiple devices and probes systematically. An adversary running their own node could configure WANTS = large subset of catalog, swap with many peers, and progressively map inventories. Rate limiting slows this but doesn't prevent it if the adversary mints fresh identities.

**Mitigations (progressive):**

1. **Rate limiting** slows probing but doesn't stop a resourced adversary:
    ```
    max_items_per_set: 50  (protocol constant — not negotiated)
    max_concurrent_swaps: 4
    max_swaps_per_hour: 20
    cooldown_after_swap: 30 seconds
    ```
    Round-1 messages exceeding `max_items_per_set` are invalid;
    the receiver aborts the session.

2. **Require prior trust before swap.** Only allow swap with verified or favorited peers. This is the strongest mitigation — an adversary must first establish a trust relationship (QR code scan, mutual contact) before they can probe. Trade-off: reduces the "swap with strangers" use case.

3. **Social-graph gating.** Only allow swap with peers who share N mutual contacts. Lighter than full verification but still requires the adversary to embed in the social graph.

Which mitigation level to default to is a UX decision. The protocol supports all three. For high-risk environments, option 2 or 3 should be the default.

### Other Considerations

**Active MITM:** An attacker who intercepts the Noise handshake could intercept swap messages. Mitigation: out-of-band fingerprint verification, same as for private chat.

**Set-size padding:** Set sizes can be padded to a fixed count with random group elements if set-size hiding is desired. Adds ~32 bytes per pad element.

## Implementation Notes

The crypto core is ~200 lines of Ristretto255 point operations. The only new dependency beyond what bitchat already uses is Ristretto255 hash-to-group (available in libsodium, swift-sodium). The bulk of the implementation work is the UI — catalog browser, peer list, match display.

## References

- Meadows, "A More Efficient Cryptographic Matchmaking Protocol for Use in the Absence of a Continuously Available Third Party" (IEEE S&P 1986) — original DH-PSI
- De Cristofaro & Tsudik, "Practical Private Set Intersection Protocols with Linear Complexity" (FC 2010) — efficient DH-PSI constructions
- bitchat Whitepaper v1.1 (July 2025) — protocol stack, message format, Noise integration
