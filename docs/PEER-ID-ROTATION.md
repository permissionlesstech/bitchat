# Peer ID Rotation Specification

**Status:** Draft for cross-platform review. Nothing here is implemented yet.
**Audience:** bitchat iOS and bitchat Android maintainers.
**Requires agreement before implementation.** This changes the wire protocol, so neither platform can ship it alone.

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

With the static keys off the air, mutual favourites need another way to spot each other. Each announce carries a set of **pairwise recognition tags**. For a device A with mutual favourite B:

```
S_AB    = X25519(A_noiseStaticPrivate, B_noiseStaticPublic)      // == X25519(B_priv, A_pub)
K_AB    = HKDF-SHA256(ikm: S_AB, salt: "", info: "bitchat-recognition-v1", length: 32)
tag_AB  = HMAC-SHA256(key: K_AB, message: uint32be(epoch))[0..8]
```

A includes `tag_AB` in its announce. B computes the same value independently (it holds the same shared secret) and matches it against inbound announces. Only A and B can compute it, because it needs one of the two private keys.

On a match, B learns "the device currently using `peerID_e` is A" and can populate its peer list, route DMs, and show A as nearby exactly as today.

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

- the signature against the signing key in the same packet, **and**
- that the signing key matches whatever it has already pinned for this fingerprint, using the existing trust ladder (authenticated key, then TOFU pin), and
- that `peerID_e` equals the ID the session was actually conducted under, and
- that `epoch` is within the ±1 window.

This replaces `authenticatedRemoteKey`'s derivation check with an explicit signed statement. It is strictly stronger than today's self-signed announce, because the signing key is checked against a pin rather than taken from the same message.

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

**Proposed v2 announce.** Because the existing decoder hard-requires the three identity TLVs, a v2 announce cannot simply omit them — that is a parse failure, not a graceful degrade. It therefore needs a distinct message type. Assigned values today are `0x01`–`0x04`, `0x10`–`0x11`, and `0x20`–`0x29`, so **`announceV2 = 0x05`** is proposed: free, and adjacent to `announce = 0x01` so the grouping stays readable (see O3).

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

**Capability bit.** `PeerCapabilities` is a `UInt64` `OptionSet` with minimal little-endian wire encoding, at least one byte, so "no TLV" and "empty set" stay distinguishable. Crucially `BLEPeerRegistry.capabilitiesWereExplicitlyAdvertised(for:)` distinguishes *old client that sent no TLV* from *new client with the bit off*. Add `peerIDRotation` at the next free bit (bit 11; bit 10 is burned and MUST NOT be reused).

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

To be filled in jointly **before** implementation, so both platforms verify against the same numbers rather than against each other's bugs. Each vector should give hex inputs and expected outputs for:

1. `K_rot` from a fixed 32-byte Noise static private key.
2. `peerID_e` for that `K_rot` at three consecutive epochs.
3. `S_AB`, `K_AB`, `tag_AB` for a fixed key pair at a fixed epoch, computed from both sides, showing they agree.
4. A padded 8-slot tag list with two real tags, showing the real tags are recoverable regardless of position.
5. The §4.5 binding `proof` bytes and signature for fixed keys, ID, and epoch.
6. A full v2 announce packet, encoded, as a hex blob.

Whichever platform writes a vector, the other MUST reproduce it independently from this document rather than from the first platform's code.

## 8. Open questions for review

- **O1 — Rotation period.** One hour is a guess balancing unlinkability against churn. Shorter means less linkable and more session/route disruption; longer the reverse. Is there a period that is clearly right, or should it be a build constant both platforms pin?
- **O2 — More than `TAG_SLOTS` favourites.** What is the required convergence guarantee — "every mutual favourite sees a tag within N announces"? Should the slot rotation be deterministic from the epoch so it is testable?
- **O3 — New message type vs. announce version byte.** A distinct `MessageType` is cleanest given the decoder's required TLVs, but it consumes a type value and means two announce paths. Would a version TLV inside the existing type, with the identity TLVs made optional on both platforms first, be preferable?
- **O4 — Unsigned v2 announces.** Is "unverified presence, not shown until recognised or handshaked" an acceptable posture? The alternative is an ephemeral per-epoch signing key with a proof-of-continuity, which is more machinery and more bytes.
- **O5 — Rotation while a session is live.** Defer rotation until sessions are idle, or rotate and migrate? Deferring is simpler and safer, but a long-lived session pins the ID for its lifetime, which weakens G1 for exactly the people who talk most.
- **O6 — Nickname timing.** Moving the nickname into the session means a stranger's name appears only after a handshake. Is that acceptable UX on both platforms, or does the peer list need a "someone nearby" placeholder state?
- **O7 — Android decoder tolerance.** iOS `BinaryProtocol.decodeCore` accepts trailing bytes (`guard offset <= buf.count`) and `decode` also retries after unpadding. Both matter for extending padding to more packet types. Does the Android decoder tolerate trailing bytes the same way? If not, padding coverage has to be gated on the capability bit too.

## 9. Relationship to other work

Rotation is the largest item in the radio-layer metadata cluster but not the only one, and the others are cheaper:

- **Drop the neighbour list** — backward compatible today, no agreement needed, removes the adjacency-graph leak.
- **Randomize origin TTL** — packets currently leave at the default TTL, so `ttl == default` marks the originating hop to any direct listener.
- **Extend padding beyond Noise frames, and fix the length-marker gap** — only `noiseEncrypted` and `noiseHandshake` are padded, and `pad` silently declines when the required padding exceeds the single-byte marker, so frames well below their bucket ship unpadded. Subject to O7.

None of these substitute for rotation, and rotation does not substitute for them: a device with a rotating ID that still publishes its neighbour list, or that still marks its own originated packets by TTL, remains linkable.
