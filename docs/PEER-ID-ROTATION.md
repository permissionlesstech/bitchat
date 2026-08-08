# Peer ID Rotation Specification

**Status:** Draft for cross-platform review. The derivations and the wire format **are implemented and tested**; nothing is wired into the shipping mesh.
**Audience:** bitchat iOS and bitchat Android maintainers.
**Requires agreement before going further.** This changes the wire protocol, so neither platform can ship it alone.

**Where the code is:**

| Piece | File |
|---|---|
| Epochs, ID derivation, recognition tags, tag block, binding message | `localPackages/BitFoundation/Sources/BitFoundation/PeerIDRotation.swift` |
| `announceV2 = 0x2C` wire format | `localPackages/BitFoundation/Sources/BitFoundation/AnnounceV2Packet.swift` |
| Executable test vectors | `localPackages/BitFoundation/Tests/BitFoundationTests/PeerIDRotationTests.swift` |
| How to author golden vectors | [`docs/BITFOUNDATION-GOLDEN-VECTORS.md`](BITFOUNDATION-GOLDEN-VECTORS.md) |
| Wire-format tests | `localPackages/BitFoundation/Tests/BitFoundationTests/AnnounceV2PacketTests.swift` |

The code is deliberately an **opinionated working base, not a finished feature**. Every number and context string in it is a concrete proposal you can disagree with by changing one function and watching a test vector move. What is *not* implemented is the part that carries risk: nothing emits a v2 announce, and `BLEService` parses the type and explicitly ignores it, because consuming it needs both the replacement identity binding (§4.5) and a decision on how unverified presence appears in the peer list (O4).

Three policy decisions were forced by the compiler when the new message type was added, and are worth reviewing as part of this:

- **Not gossip-synced** (`SyncTypeFlags`). Syncing presence would defeat the purpose: a device never in radio range could collect tag blocks, turning a local beacon into a network-wide one.
- **Not padded** (`BLEOutboundPacketPolicy`). At ~75 bytes the smallest bucket would triple the airtime of the most frequent packet in the protocol. The format is already near-constant width; making the capability and geohash fields fixed-width would be cheaper than padding. Open for argument.
- **Parsed but ignored** on receive (`BLEService`), as above.

---

## 1. The problem

Today a passive listener with a BLE dongle, standing in a crowd, can do the following with no cryptographic attack and no active participation:

1. **Detect that a phone is running bitchat.** The service UUID is a fixed constant.
2. **Assign that phone a permanent identifier.** The 8-byte sender ID in every packet header is `SHA-256(noiseStaticPublicKey)[0..8]`, and the Noise static key is generated once and kept in the keychain. It does not rotate. Same phone, same bytes, next week, next city.
3. **Learn the phone's long-term public keys and its self-chosen nickname.** The announce carries the 32-byte Noise static key, the 32-byte Ed25519 signing key, and the nickname, all in cleartext, re-broadcast every 4–30 seconds and on demand to anything that connects and subscribes.
4. **Reconstruct who was standing near whom.** The announce also carries up to ten neighbour IDs, so one receiver gets the local adjacency graph without needing several receivers or signal-strength trilateration.

For the people this app is explicitly built for, (2) and (4) are the dangerous ones. A protest attendee's phone announces a stable pseudonym and its social graph to anyone within radio range.

iOS BLE address randomization does not help. It randomizes the link-layer address underneath an application layer that publishes a stable identifier above it.

**The correction that matters most:** rotating the peer ID *alone* accomplishes nothing. As long as the announce carries the static keys in cleartext, a rotated ID is re-linked to the same device on its first announce. Rotation and announce confidentiality have to land together or not at all.

## 2. Goals and non-goals

**Goals**

- **G1.** A passive listener cannot link two observations of the same device across rotation periods.
- **G2.** A passive listener cannot learn a device's long-term identity keys or nickname.
- **G3.** Peers who already know each other (mutual favourites) still recognise each other automatically, without an interactive handshake, so existing UX does not regress.
- **G4.** Strangers can still discover and handshake, so the mesh still forms among people who have never met.
- **G5.** Old and new clients interoperate. A mixed mesh keeps working, in both directions, with no flag day.
- **G6.** Rotation does not make identity spoofing easier than it is today.

**Non-goals, explicitly out of scope here**

- Hiding *that* bitchat is in use. The service UUID is a separate problem; BLE requires something discoverable. Tracked separately.
- Traffic-analysis resistance in general: padding coverage, send-time jitter, TTL randomization, and the neighbour-list leak each need their own change. Rotation does not fix them and they do not fix rotation.
- Resistance to an active attacker who connects and completes a handshake. Anyone you handshake with learns your identity; that is what a handshake is for.

## 3. What currently binds an identity, and why rotation breaks it

This is the part most likely to be underestimated, so it is stated precisely.

`peerID == SHA-256(noiseStaticPublicKey)[0..8]` is not merely a convention. It is **the mechanism that makes peer IDs unforgeable**, and it is enforced in two places:

**Announce preflight** — `BLEAnnounceHandlingPolicy.swift:32-35`:

```swift
let derivedPeerID = PeerID(publicKey: announcement.noisePublicKey)
guard derivedPeerID == peerID else { return .reject(.senderMismatch(derivedPeerID: derivedPeerID)) }
```

**Handshake completion** — `NoiseSessionManager.swift:1106-1122`:

```swift
private func authenticatedRemoteKey(_ remoteKey: Curve25519.KeyAgreement.PublicKey,
                                    matches claimedPeerID: PeerID) -> Bool {
    let rawKey = remoteKey.rawRepresentation
    if claimedPeerID.isShort { return PeerID(publicKey: rawKey) == claimedPeerID }
    …
}
```

Failure throws `NoiseSessionError.peerIdentityMismatch`.

If the peer ID becomes independent of the key, **both checks fail for every peer** and there is nothing left proving that a sender ID belongs to the sender. Any rotation design must therefore ship a *replacement* binding in the same change. This is why the work is a protocol revision and not a patch.

Note also what the existing announce signature does and does not prove. The packet signature covers the sender ID (`BitchatPacket.toBinaryDataForSigning()` zeroes only TTL and the RSR flag), but it is verified against the Ed25519 key carried *inside the same announce* — a self-signature. The code says so plainly (`BLEAnnounceHandlingPolicy.swift:94-103`): an attacker can replay a victim's peer ID and Noise key with their own signing key and a valid self-signature, and only trust-on-first-use pinning of the signing key stops it. So today's binding is "derived ID + TOFU", and a replacement must be at least that strong.

## 4. Design

### 4.1 Epochs

Rotation is on a wall-clock schedule so that two devices that have never met agree on the current period without negotiation.

```
epoch = floor(unixTimeSeconds / ROTATION_PERIOD)
ROTATION_PERIOD = 3600   (1 hour, proposed — see open question O1)
```

`epoch` is a `UInt32`, big-endian wherever it is hashed. Implementations MUST accept `epoch-1`, `epoch`, and `epoch+1` when matching (the ±1 window absorbs clock skew and boundary crossings), following the precedent already set by courier recipient tags (`CourierEnvelope.candidateTags`).

### 4.2 The rotating peer ID

```
K_rot   = HKDF-SHA256(ikm: noiseStaticPrivateKey,
                      salt: "",
                      info: "bitchat-peer-rotation-v1",
                      length: 32)

peerID_e = HMAC-SHA256(key: K_rot,
                       message: "bitchat-peer-id-v2" || uint32be(epoch))[0..8]
```

Properties:

- Derived from the **private** key, so no observer can compute or predict it, and two epochs' IDs are unlinkable.
- Deterministic, so the device recomputes the same ID after a restart within the same epoch.
- Still 8 bytes, so the packet header layout is unchanged.

**It must be derived from private key material.** Deriving from the *public* key would let anyone who has ever seen that key compute every past and future ID, which is worse than doing nothing because it would look like protection. This mistake already exists in the codebase: `CourierEnvelope.recipientTag` is `HMAC(key: recipient's **public** static key, epochDay)`, and since that public key is broadcast in cleartext today, any observer in radio range can compute a peer's courier tags for any day. The whitepaper's claim that couriers "cannot link it across days" does not currently hold. Fixing that is out of scope here but should be tracked; do not copy the pattern.

### 4.3 Recognising peers you already know

With the static keys off the air, mutual favourites need another way to spot each other. Each announce carries a set of **pairwise recognition tags**. For a device A announcing under `peerID_e` to mutual favourite B:

```
S_AB    = X25519(A_noiseStaticPrivate, B_noiseStaticPublic)      // == X25519(B_priv, A_pub)
K_AB    = HKDF-SHA256(ikm: S_AB, salt: "", info: "bitchat-recognition-v1", length: 32)

tag_A→B = HMAC-SHA256(key: K_AB,
                      message: uint32be(epoch)
                            || A_noiseStaticPublic   (32)
                            || B_noiseStaticPublic   (32)
                            || peerID_e              (8))[0..8]
```

A includes `tag_A→B` in its announce. B computes the same value independently — it holds the same shared secret and both public keys — and matches it against inbound announces. Only A and B can compute it, because it needs one of the two private keys.

Two properties of that MAC input are load-bearing, and an earlier draft of this document got both wrong. They were caught in review of #1487, which is the argument for shipping the code alongside the prose.

**Ordered keys make the tag directional.** The earlier form was `HMAC(K_AB, epoch)`, which is symmetric: A and B would broadcast the *identical* 8 bytes. An observer who saw one value appear in two different announces would learn that those two devices are mutual favourites, and could link their two rotating IDs to each other — handing over precisely the social graph this design exists to hide, and providing a cross-epoch correlation handle. Ordering the keys yields distinct A→B and B→A values, and both parties can still compute both directions because both hold both public keys.

**`peerID_e` binds the tag to the announce carrying it.** Without it a tag depends only on (pair, epoch), so an attacker could lift A's tag out of a recorded announce and replay it in a fresh announce under an ID of their own choosing; B would match and treat that ID as A. Because `epoch-1` is also accepted, the spoof would stay usable into the following period. Binding to the ID reduces this from impersonation-as-any-ID to replaying A's own presence.

**Residual risk, unfixable while announces are unsigned:** an attacker can rebroadcast A's exact announce within the epoch window, making A appear present when absent. Recognition is therefore a **hint only**. A match may populate presence, but anything consequential — routing a DM, showing a verified badge — MUST wait for a completed handshake whose static key equals the favourite that produced the match. See O4.

Rules:

- Tags are **unordered**. Implementations MUST NOT infer anything from position.
- The tag list MUST be padded with uniform random 8-byte values to a fixed count `TAG_SLOTS = 8`, so the number of tags does not disclose how many mutual favourites a device has. Random padding is indistinguishable from a real tag to anyone who cannot compute it.
- With more than `TAG_SLOTS` mutual favourites, a device MUST rotate which favourites occupy the slots across successive announces so all of them eventually see a tag. (Selection strategy is an implementation detail; convergence is not — see O2.)
- A device MUST NOT include a tag for a one-directional favourite, since that would disclose interest to someone who has not reciprocated.

### 4.4 Strangers

Nothing identifying is broadcast for strangers. Discovery still works:

1. A hears an announce from unknown `peerID_e` advertising the rotation capability.
2. A initiates Noise **XX** to that ID.
3. In XX, the responder's static key is sent in message 2 *after* `ee`, and the initiator's in message 3 — both encrypted. A passive observer learns neither.
4. On completion, both sides learn the peer's real static key and fingerprint, exactly as they do today (`handleSessionEstablished`), and the existing `AuthenticatedPeerStatePacket` (Noise payload `0x21`) carries the Ed25519 signing key and capability claims *inside* the session, where they are proven rather than asserted.

So the model becomes **handshake first, identify second**, for anyone who is not already a mutual favourite.

### 4.5 The replacement binding

Inside the completed handshake, each side proves that the rotating ID it was using belongs to its static key:

```
proof = Ed25519-Sign(signingPrivateKey,
                     "bitchat-peerid-binding-v1"
                     || uint32be(epoch)
                     || peerID_e (8 bytes)
                     || noiseStaticPublicKey (32 bytes))
```

Sent as a new TLV in `AuthenticatedPeerStatePacket`, whose existing structure already carries a version byte, a canonicality-checked capability TLV, and the 32-byte signing key. The receiver verifies:

- **that the `noiseStaticPublicKey` inside the proof is byte-equal to the remote static key the Noise session actually established** — see below, this one is load-bearing, and
- the signature against the signing key in the same packet, **and**
- that the signing key matches whatever it has already pinned for this fingerprint, using the existing trust ladder (authenticated key, then TOFU pin), and
- that `peerID_e` equals the ID the session was actually conducted under, and
- that `epoch` is within the ±1 window.

An earlier draft of this list omitted the first check, which left a hole worth spelling out because it is the kind that survives review. The proof is a self-contained signed blob: nothing in the signature ties it to *the session it arrives on*. So a peer M who has observed A's proof — it travels inside a session, but M can be a peer A legitimately talked to — could replay A's proof verbatim inside M's own session with B. Without the static-key check, B verifies A's signature successfully, sees a well-formed binding, and on **first contact** TOFU-pins A's signing key against M's fingerprint. From then on B attributes M's identity to A's key. Comparing the proof's static key against the key the handshake actually produced closes it: M cannot substitute A's key without also being A.

This replaces `authenticatedRemoteKey`'s derivation check with an explicit signed statement. With the static-key check present it is strictly stronger than today's self-signed announce, because the signing key is checked against a pin rather than taken from the same message. Without it, it is weaker — a reminder that "signed" and "bound to this conversation" are different properties.

Note the canonical-bytes helper for this already half-exists: `NoiseEncryptionService.buildAnnounceSignature` / `verifyAnnounceSignature` / `canonicalAnnounceBytes`, with context `"bitchat-announce-v1"`, are present but unreferenced in production (only tests call them). They sign `context‖peerID(8)‖noiseKey(32)‖ed25519Key(32)‖nickname‖timestampMs`. The binding above is deliberately a **different context string** and a different field set, so the two can never be confused; the dead code should be deleted or repurposed explicitly rather than silently reused.

### 4.6 The announce, before and after

**Today** (`AnnouncementPacket`, TLVs in `Packets.swift:33-40`), all cleartext:

| T | Field | Width |
|---|---|---|
| `0x01` | nickname | var |
| `0x02` | Noise static public key | 32 |
| `0x03` | Ed25519 signing public key | 32 |
| `0x04` | direct neighbours | N × 8, max 10 |
| `0x05` | capabilities | 1–8 |
| `0x06` | bridge geohash | var |

`0x01`, `0x02`, `0x03` are **required** by the decoder (`Packets.swift:147`).

**Proposed v2 announce.** Because the existing decoder hard-requires the three identity TLVs, a v2 announce cannot simply omit them — that is a parse failure, not a graceful degrade. It therefore needs a distinct message type: **`announceV2 = 0x2C`**.

An earlier draft proposed `0x05` on the grounds that it is unassigned today and sits next to `announce = 0x01`. That was wrong. `0x05` has already been recycled twice — `announce`, then `bulkTransferResponse`, then `fragmentStart` until #446 — so a sufficiently old peer may still map it to a fragment header and misparse presence as a partial message. Values above `voiceFrame = 0x29` have only ever been allocated forward, which is the safe direction; `0x2A`/`0x2B` are spoken for by the courier spray-ack work, leaving `0x2C`. Verified never used anywhere in this repository's history (see O3).

TLVs, all cleartext but none identifying:

| T | Field | Width | Notes |
|---|---|---|---|
| `0x01` | epoch | 4 | `uint32be`; lets a receiver match without guessing |
| `0x02` | recognition tags | `TAG_SLOTS` × 8 = 64 | unordered, random-padded |
| `0x03` | capabilities | 1–8 | same minimal-LE encoding as today |
| `0x04` | bridge geohash | ≤12 | unchanged semantics |

Deliberately absent: nickname, both public keys, neighbour list.

Worth noting because it is counter-intuitive: **the v2 announce is smaller than the v1 announce**, despite carrying 64 bytes of tags. A v1 announce with a 10-byte nickname and a full neighbour list is roughly 165 payload bytes plus a 64-byte signature; a v2 announce is roughly 75 bytes and unsigned. Dropping two 32-byte keys, the neighbour list, and the signature more than pays for the tag block, so this reduces airtime rather than adding to it.

- **Nickname** moves inside the session (`AuthenticatedPeerStatePacket`). A nickname is a self-chosen, often reused human label; broadcasting it in cleartext is a linkage vector on its own.
- **Neighbour list** is dropped entirely. It exists to seed source routing, and its documented fallback is flooding. Publishing the adjacency graph of a crowd is not a reasonable price for routing efficiency. (Dropping it is independently backward compatible — the TLV is optional on decode — and can ship ahead of this spec.)

**The v2 announce is unsigned.** This is a real trade-off and needs review (O4). There is no key to verify a signature against without disclosing one, so a v2 announce asserts nothing except "somebody is here, and here are some tags". Consequences:

- An attacker can emit v2 announces with arbitrary IDs and random tags — cheap peer-list noise. This is bounded by the existing announce rate limiting, per-central subscription limiting, and connection rate limits, but it is weaker than today.
- An attacker **cannot** impersonate a specific known peer, because it cannot compute that peer's recognition tags without one of the two private keys.
- An attacker cannot get a Noise session, so it cannot send messages, only occupy a peer-list slot.

Mitigation for review: treat a v2 announce as *unverified presence* only, and do not surface it in the peer list until either a recognition tag matches or a handshake completes. That preserves today's property that the peer list reflects authenticated peers.

## 5. Compatibility and rollout

The repo already has the two mechanisms this needs, both proven in production.

**Capability bit.** `PeerCapabilities` is a `UInt64` `OptionSet` with minimal little-endian wire encoding, at least one byte, so "no TLV" and "empty set" stay distinguishable. Crucially `BLEPeerRegistry.capabilitiesWereExplicitlyAdvertised(for:)` distinguishes *old client that sent no TLV* from *new client with the bit off*. Add `peerIDRotation` at the next free bit — **bit 14** at the time of writing: bit 10 is burned and MUST NOT be reused, bit 11 is claimed by the Nostr double-ratchet work (#1107), bit 12 by courier spray receipts (#1438), and bit 13 is reserved for stickers (#1544). Re-check the claim table in `PeerCapabilities.swift` before assigning; whichever platform implements first pins the number in a shared test vector.

**Observed-version gating.** `MeshTopologyTracker.recordObservedVersion(_:for:)` records the highest protocol version seen from each node, and `computeRoute(…, requiringVersion:)` refuses paths through nodes not observed at that version. `docs/SOURCE_ROUTING.md` records this as the shipped pattern for a compatible rollout. The same shape applies here.

**Phased plan.**

| Phase | Behaviour |
|---|---|
| 1 | Both platforms ship the ability to **parse** v2 announces and advertise the capability, while still sending v1. Purely additive; a v2 announce from a test build is understood rather than dropped. |
| 2 | Send v1 **and** v2 announces, alternating. New clients prefer v2 and ignore the v1 from a peer they have recognised via v2; old clients see only the v1. Costs airtime, buys a no-flag-day transition. |
| 3 | Once telemetry-free judgement says adoption is sufficient, a setting (default on) suppresses v1 announces. A device that suppresses v1 becomes invisible to old clients — that is the intended cost of unlinkability, and it must be stated in the UI, not buried. |

During phases 2–3 a device runs **both** a stable v1 ID and a rotating v2 ID. They must never appear as two peers; a peer recognised by both paths has to collapse to one entry. The repo has the beginnings of this in `MessageRouter.peerIDAliases` and `ChatPeerIdentityCoordinator.migrateChatState`, but they were built for panic-reset rotation, not steady-state rotation.

## 6. Impact inventory

This is what an implementer must handle. Every item below was verified against the iOS source; Android should expect its own equivalents.

### 6.1 Must be fixed or the feature is broken

| Area | Why | iOS reference |
|---|---|---|
| **Handshake identity check** | `authenticatedRemoteKey` re-derives the ID from the static key and fails for every peer once IDs are independent. Replace with §4.5. | `NoiseSessionManager.swift:1106-1122`, enforced `:714-718` |
| **Announce preflight** | Same derivation check rejects any announce whose ID is not the key's hash. | `BLEAnnounceHandlingPolicy.swift:32-35` |
| **Sealed message outbox** | Queued DM plaintext is keyed by peer ID on disk and survives app kill. A recipient's rotation orphans their queue. Needs re-keying by **fingerprint** (stable) with the peer ID as a lookup hint. This is the single worst offender. | `MessageOutboxStore.swift:66`, `:704-707`, `:746` |
| **Private-media durable IDs** | `stableID` hashes sender and recipient short IDs, and the durable receipt ledger keys accept/tombstone records on it. Rotation silently breaks dedup **and user deletion tombstones**, so deleted media could be re-accepted. | `BitchatFilePacket.swift:183-231`, `BLEPrivateMediaReceiptStore.swift` |
| **Initiator tie-break** | Crossed-initiation resolution compares `localPeerID < peerID`. Both sides must reach the same verdict; a rotation mid-negotiation flips it asymmetrically. Needs a rotation-stable comparison key (fingerprint). | `NoiseSessionManager.swift:83`, `:569`, `:582`, `:603` |
| **Fingerprint-prefix lookups** | Several paths recover a peer from `fingerprint.hasPrefix(peerID)`. These silently return empty, and one of them is what lets a public message from a not-yet-registered peer be accepted at all. | `SecureIdentityStateManager.swift:437-444`; `ChatGroupCoordinator.swift:98-102`, `:432`; `FavoritesPersistenceService.swift:188-195`; `BLEService.swift:2552`, `:2823` |
| **`PeerID.routingData`** | Falls back to `toShort()`, i.e. fingerprint-derived routing bytes. | `PeerID.swift:190-202` |

### 6.2 Degrades gracefully but needs handling

| Area | Effect | iOS reference |
|---|---|---|
| **Noise sessions** | A rotation mid-session leaves an established session under the old ID. Rotation should either be deferred while sessions are live or migrate them explicitly. | `NoiseEncryptionService.swift:1010-1019` |
| **Fragment reassembly** | The reassembly key mixes the 8-byte sender ID, so a rotation mid-transfer strands every in-flight assembly until the 30 s timeout. Defer rotation while fragments are in flight. | `BLEFragmentAssemblyBuffer.swift:4-47` |
| **Dedup LRU** | Keys embed the sender ID, so the same packet crossing a rotation boundary can be reprocessed once. Bounded and probably acceptable. | `BLEReceivePipeline.swift:21` |
| **Source routes / topology** | A remote rotation invalidates cached adjacency, and a rotated relay no longer finds itself in an in-flight v2 route, falling back to flooding. Already the documented fallback. | `MeshTopologyTracker.swift`, `BLERouteForwardingPolicy.swift:62` |
| **Gossip archive** | Archived raw packets keep the old sender ID forever, and packet IDs are sender-derived, so attribution and purge-by-peer break for pre-rotation history. | `GossipMessageArchive.swift`, `PacketIdUtil.swift:8-17` |
| **Read receipts** | The wire receipt carries an 8-byte `readerID`; one sent before and matched after a rotation will not correlate. | `ReadReceipt.swift:47-64` |

### 6.3 Already safe — no work needed

Keyed by fingerprint, Noise key, or Ed25519 key rather than peer ID: the identity cache and every map in it (social identities, verified fingerprints, vouches, blocks), favourites (keyed by Noise static key), courier envelopes and recipient tags, prekey bundles, board posts, bridge drop dedup, group rosters, vouch attestations, and all geohash/location state (keyed by Nostr pubkey). Peer registry, link state, and all Noise session maps are in-memory and session-scoped.

## 7. Test vectors

These live as assertions in `PeerIDRotationTests.swift`, so they run on every build rather than rotting in a table.

All three were **cross-checked against an independent implementation written from this document alone** — Python `hmac`/`hashlib`, HKDF as extract-then-expand with an empty salt — and matched byte for byte. That is the property that matters: the spec text is sufficient to reproduce the numbers without reading the Swift.

With `noiseStaticPrivateKey = 0102…20` (bytes 1 through 32):

```
rotationSecret = HKDF-SHA256(ikm: 0102…20, salt: <empty>,
                             info: "bitchat-peer-rotation-v1", len: 32)
               = fb82dfec0c0a2a4677beca44e2f72c80e7c5de773dd5fce6ee47af83d3c25f09

peerID(epoch=100) = HMAC-SHA256(rotationSecret,
                                "bitchat-peer-id-v2" || uint32be(100))[0..8]
                  = f7c08c528506a374
```

With a recognition key derived from a shared secret of 32 × `0x42`, sender key
32 × `0x0A`, recipient key 32 × `0x0B`, and announced ID 8 × `0xA1`:

```
recognitionKey = HKDF-SHA256(ikm: 42×32, salt: <empty>,
                             info: "bitchat-recognition-v1", len: 32)

tag_A→B(epoch=100) = HMAC-SHA256(recognitionKey,
                                 uint32be(100) || 0A×32 || 0B×32 || A1×8)[0..8]
                   = 4568f61d61d6cbfb

tag_B→A(epoch=100)   (same key, keys swapped)
                   = 5313c7731f629959
```

Both directions are given because their *difference* is the security property: if
an implementation produces the same value for both, it has reintroduced the
symmetric-tag flaw.

Also asserted, and worth reproducing on Android because they are the properties rather than the numbers: both sides of a real X25519 pair derive the identical tag from opposite key halves; consecutive epochs produce unrelated IDs; the ±1 epoch window matches across a boundary but two epochs out does not; the tag block is always 64 bytes regardless of how many tags it carries; a match is found regardless of slot position; and the binding message is fixed-width so a short input cannot shift a later field into an earlier field's position.

Still to be written jointly: a full `announceV2` packet as a hex blob, and the §4.5 signature over a fixed key. Whichever platform writes a vector, the other MUST reproduce it from this document rather than from the first platform's code.

## 8. Open questions for review

- **O1 — Rotation period.** One hour is a guess balancing unlinkability against churn. Shorter means less linkable and more session/route disruption; longer the reverse. Is there a period that is clearly right, or should it be a build constant both platforms pin?
- **O2 — More than `TAG_SLOTS` favourites.** What is the required convergence guarantee — "every mutual favourite sees a tag within N announces"? Should the slot rotation be deterministic from the epoch so it is testable?
- **O3 — New message type vs. announce version byte.** A distinct `MessageType` is cleanest given the decoder's required TLVs, but it consumes a type value and means two announce paths. Would a version TLV inside the existing type, with the identity TLVs made optional on both platforms first, be preferable?
- **O4 — Unsigned v2 announces.** Binding tags to the announced peer ID removes impersonation-as-any-ID, but a recorded announce can still be rebroadcast verbatim within the epoch window, so a peer can be made to look present when absent. Is "presence is a hint; nothing consequential until a handshake whose static key matches the favourite that produced the match" acceptable? The alternatives are an ephemeral per-epoch signing key with a proof-of-continuity, or a freshness nonce echoed by the recipient — both more machinery and more bytes.
- **O5 — Rotation while a session is live.** Defer rotation until sessions are idle, or rotate and migrate? Deferring is simpler and safer, but a long-lived session pins the ID for its lifetime, which weakens G1 for exactly the people who talk most.
- **O6 — Nickname timing.** Moving the nickname into the session means a stranger's name appears only after a handshake. Is that acceptable UX on both platforms, or does the peer list need a "someone nearby" placeholder state?
- **O7 — Padding is a coordinated change, not a local one.** This started as a question about decoder tolerance and turned into something firmer. `BitchatPacket.toBinaryDataForSigning()` encodes with padding enabled, so **the padding bytes are inside the signed material for every signed packet**. Changing the padding algorithm therefore changes the signed byte stream, and signatures stop verifying against any peer that has not made the identical change. Both outstanding padding fixes are affected: extending coverage beyond `noiseEncrypted`/`noiseHandshake`, and closing the gap where a frame needing more than 255 bytes of padding is emitted unpadded (encoded *frames* of 241–256, 497–768 and 1009–1792 bytes ship at exact length today — the arithmetic is over the whole encoded packet that `pad` receives, not the payload alone). Two things to settle: whether Android's decoder also tolerates trailing bytes the way iOS's does (`guard offset <= buf.count`, plus an unpad retry), and whether padding changes ride this protocol revision or get their own capability-gated one.

- **O9 — A seized device recomputes every past peer ID.** `K_rot` is a long-lived secret, so `peerID_e = HMAC(K_rot, epoch)` is computable for *any* epoch by whoever holds it. Someone who seizes a phone, or extracts the Noise static key from a backup, can therefore take historical radio captures and identify which of them were this device — retroactively defeating the unlinkability for every past epoch. Rotation protects against the passive observer, not against later key compromise. A hash ratchet (`K_{e+1} = HKDF(K_e)`, discarding `K_e`) would give forward secrecy for the ID stream, at the cost of state that must survive restarts, tolerate clock jumps, and resynchronise after a gap — none of which is free, and all of which interacts with the ±1 window. Worth deciding deliberately rather than inheriting.

## 9. Relationship to other work

Rotation is the largest item in the radio-layer metadata cluster but not the only one, and the others are cheaper:

- **Drop the neighbour list** and **randomize origin TTL** — both landed separately, since neither needs agreement: see the radio-metadata PR.
- **Extend padding beyond Noise frames, and fix the length-marker gap** — only `noiseEncrypted` and `noiseHandshake` are padded, and `pad` silently declines when the required padding exceeds the single-byte marker, so frames well below their bucket ship unpadded. **Not unilateral**: padding is inside the signed bytes, so this needs both platforms. See O7.

None of these substitute for rotation, and rotation does not substitute for them: a device with a rotating ID that still publishes its neighbour list, or that still marks its own originated packets by TTL, remains linkable.
