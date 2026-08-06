# Conformance

This chapter is a checklist, not a re-explanation of the protocol: each item below is a single checkable point, restating a MUST/MUST NOT/SHOULD/REQUIRED rule already defined normatively in one of the six preceding chapters and linking back to it. An implementation is conformant with a given mechanism when every applicable item under it holds. Items describing a RECOMMENDED default (tuning constants, cache sizes, timing) are non-normative — an implementation MAY use a different value without losing conformance, unless the item says otherwise.

Chapter 6's items are split by the REQUIRED/capability-gated boundary that chapter defines: an implementation MUST satisfy every item under a REQUIRED mechanism, but only needs to satisfy a capability-gated mechanism's items if it advertises that capability at all.

## 1. Wire Format

- [ ] A decoder MUST reject a packet whose version byte is neither `1` nor `2` ([§1](01-wire-format.md#1-packet-versions)).
- [ ] The header is 14 bytes for v1, 16 bytes for v2, both big-endian, with fields in the fixed order `version, type, ttl, timestamp, flags, payloadLength` ([§2](01-wire-format.md#2-header-layout)).
- [ ] A relay MUST NOT forward a packet once its `ttl` reaches `0` ([§2](01-wire-format.md#2-header-layout)).
- [ ] The `flags` bitfield matches the defined table (`hasRecipient` 0x01, `hasSignature` 0x02, `isCompressed` 0x04, `hasRoute` 0x08 v2-only, `isRSR` 0x10, bits 5-7 reserved) ([§3](01-wire-format.md#3-flags)).
- [ ] `hasRoute` MUST NOT be set on a v1 packet ([§3](01-wire-format.md#3-flags)).
- [ ] Reserved flag bits MUST be `0` on encode; a decoder MUST ignore, not reject on, an unrecognized reserved bit ([§3](01-wire-format.md#3-flags)).
- [ ] The variable-section order is fixed: `senderID`, `recipientID` (if `hasRecipient`), source route (if `hasRoute`), `payload`, `signature` (if `hasSignature`) ([§4](01-wire-format.md#4-variable-sections)).
- [ ] A source route is a 1-byte hop count `N` followed by `N` 8-byte peer IDs; `N` MUST NOT exceed 255, and route bytes are excluded from `payloadLength` ([§4.2](01-wire-format.md#42-source-route)).
- [ ] When `isCompressed` is set, the payload begins with a 2-byte (v1) or 4-byte (v2) big-endian original-size preamble, itself counted in `payloadLength` ([§4.3](01-wire-format.md#43-payload-and-compression)).
- [ ] A signature, when `hasSignature` is set, is a 64-byte Ed25519 signature immediately following the payload ([§4.4](01-wire-format.md#44-signature)).
- [ ] A signature is computed over the packet with its `signature` section omitted, `ttl` fixed to `0`, and `isRSR` excluded; a verifier MUST reconstruct this exact frame ([§5](01-wire-format.md#5-signing)).
- [ ] Only `noiseHandshake`/`noiseEncrypted` packets are padded, using PKCS#7-style padding over header-through-payload targeting the smallest of the `256/512/1024/2048`-byte buckets ([§6](01-wire-format.md#6-padding)).
- [ ] A frame needing more than 255 bytes of padding to reach its target bucket MUST be emitted unpadded instead ([§6](01-wire-format.md#6-padding)).
- [ ] A decoder MUST attempt unpadded decode first and retry with PKCS#7 stripping only on failure ([§6](01-wire-format.md#6-padding)).
- [ ] The full `type` byte table MUST be supported for dispatch, and a decoder MUST skip (not reject the enclosing packet for) an unrecognized `type` ([§7](01-wire-format.md#7-message-types)).
- [ ] TLV-8 (`type`:1, `length`:1, `value`:≤255 bytes) and TLV-16 (`type`:1, `length`:2 BE, `value`:≤65535 bytes) are structurally distinct, and both framings require a decoder to skip an unrecognized TLV type using its length field rather than reject the enclosing payload ([§8](01-wire-format.md#8-tlv-encodings)).

## 2. BLE Transport

- [ ] The service UUID, characteristic UUID, and characteristic properties (notify, write, write-without-response, read) match the defined values, with a single characteristic carrying traffic in both directions ([§1](02-ble-transport.md#1-gatt-service-and-characteristic)).
- [ ] A packet exceeding the link MTU MUST be split into `fragment (0x20)` packets ([§3](02-ble-transport.md#3-fragmentation)).
- [ ] The fragment header layout — `fragmentID`(8B), `index`(2B BE), `total`(2B BE), `originalType`(1B), then `fragmentData` — is a 13-byte fixed prefix ([§3.1](02-ble-transport.md#31-fragment-header)).
- [ ] A sender MUST NOT split a packet into more than 256 fragments; a receiver MAY reject a stream whose `total` exceeds this ([§3.2](02-ble-transport.md#32-fragment-cap-and-lifetime)).
- [ ] Reassembly is keyed by `(sender, fragmentID)` and concatenates fragments in `index` order ([§3.2](02-ble-transport.md#32-fragment-cap-and-lifetime)).
- [ ] A v2 source-routed packet's fragments MAY carry the same route, with per-fragment chunk size MAY shrinking, floored at 64 bytes ([§3.3](02-ble-transport.md#33-route-aware-fragmentation-v2)).
- [ ] An advertisement (and scan response) MUST carry only the service UUID — MUST NOT carry local name, TX power, peer ID, or any other peer-identifying bytes ([§4.1](02-ble-transport.md#41-advertisement-contents)).
- [ ] Central scanning is filtered to the service UUID ([§4.2](02-ble-transport.md#42-scanning)).

## 3. Noise

- [ ] Both the `XX` and `X` patterns use Curve25519 DH, ChaCha20-Poly1305 AEAD, and SHA-256 hash/KDF (`Noise_XX_25519_ChaChaPoly_SHA256` / `Noise_X_25519_ChaChaPoly_SHA256`) ([§1](03-noise.md#1-cipher-suite)).
- [ ] The `XX` message sequence and exact byte sizes match: msg1 `e` (32B), msg2 `e,ee,s,es` (96B), msg3 `s,se` (48B) ([§2.1](03-noise.md#21-handshake-message-sequence)).
- [ ] A handshake message MUST NOT exceed 2048 bytes, for either pattern ([§2.1](03-noise.md#21-handshake-message-sequence), [§4.1](03-noise.md#41-handshake-message)).
- [ ] Handshake message bytes ride unwrapped as the entire payload of a `noiseHandshake (0x10)` packet — no extra TLV or length framing ([§2.2](03-noise.md#22-wire-carriage-of-handshake-messages)).
- [ ] `noiseEncrypted (0x11)` payload framing is `nonce`(4B BE) `||` `ciphertext` `||` `tag`(16B) ([§3.1](03-noise.md#31-transport-ciphertext-framing)).
- [ ] Decrypted application plaintext MUST NOT exceed 65,535 bytes ([§3.1](03-noise.md#31-transport-ciphertext-framing)).
- [ ] A receiver maintains a 1024-most-recent-accepted-nonce replay window per direction, and MUST reject a nonce before the window or already accepted ([§3.2](03-noise.md#32-replay-protection)).
- [ ] Application-payload framing inside decrypted plaintext is 1-byte type + data, with no length prefix (the boundary is the plaintext length) ([§3.3](03-noise.md#33-application-payload-framing)).
- [ ] The full `NoisePayloadType` table MUST be supported for dispatch ([§3.3](03-noise.md#33-application-payload-framing)).
- [ ] A decoder MUST accept `0x09` as a legacy alias for `privateFile (0x20)` on decode, and MUST NOT emit `0x09` on encode ([§3.3](03-noise.md#33-application-payload-framing)).
- [ ] The `X` pattern's single message is `-> e, es, s, ss`, with `e` cleartext (32B) and `es,s,ss` ciphertext+tag (48B) ([§4.1](03-noise.md#41-handshake-message)).
- [ ] A courier envelope seal uses the recipient's long-term static key, with no forward secrecy ([§4.2](03-noise.md#42-courier-envelopes)).
- [ ] A prekey MUST NOT be reused across more than one seal, and MUST be discarded from future bundles once consumed ([§4.3](03-noise.md#43-prekey-envelopes)).
- [ ] The `prekeyBundle (0x24)` packet uses TLV-16 framing, with fields `noiseStaticPublicKey`(32B), `prekeys`(repeated 36B entries, MUST NOT exceed 8), `generatedAt`(8B), `signature`(64B Ed25519) ([§5.1](03-noise.md#51-wire-packet), [§5.2](03-noise.md#52-fields)).
- [ ] A recipient MUST verify a prekey bundle's `signature` against the issuer's known signing key before trusting any prekey, and MUST discard the bundle on verification failure ([§5.3](03-noise.md#53-signature)).

## 4. Payloads

- [ ] `announce (0x01)` is TLV-8 with `nickname`, `noisePublicKey`(32B), `signingPublicKey`(32B) REQUIRED; a decoder MUST reject an `announce` missing any of the three ([§2](04-payloads.md#2-presence-announce)).
- [ ] `message (0x02)` (public) and the `leave (0x03)` and `delivered`/`readReceipt` inner payloads carry raw content directly, with no TLV framing ([§3.1](04-payloads.md#31-public-message), [§3.3](04-payloads.md#33-leave), [§4](04-payloads.md#4-delivery-and-read-acknowledgement)).
- [ ] `privateMessage (0x01, inner)` is TLV-8 with `messageID` and `content` ([§3.2](04-payloads.md#32-private-message)).
- [ ] `authenticatedPeerState (0x21)` is a 1-byte version + TLV-8; a decoder MUST reject any `version` other than `0x01`, MUST reject duplicate TLV entries, and MUST reject a non-minimal `capabilities` encoding ([§5](04-payloads.md#5-peer-state-and-capabilities)).
- [ ] `PeerCapabilities` is little-endian and minimal-byte-length (trailing zero bytes stripped); a decoder keeps only the low 64 bits so unknown high bits round-trip ([§5.1](04-payloads.md#51-peercapabilities-bitfield)).
- [ ] The full `PeerCapabilities` bit table MUST be supported for dispatch, bit 10 (`nonDestructiveNoiseReplacement`) MUST never be advertised by a conforming encoder, and bits 11-63 MUST be `0` on encode while a decoder MUST preserve (not reject on) an unrecognized set bit ([§5.1](04-payloads.md#51-peercapabilities-bitfield)).
- [ ] `boardPost (0x23)` is TLV-16; a decoder MUST reject an absent/unrecognized `kind` or a payload missing a field its `kind` requires, and `expiresAt` MUST NOT exceed `createdAt` + 7 days ([§6](04-payloads.md#6-board-posts)).
- [ ] Board post signatures use context strings `bitchat-board-v1` (post) / `bitchat-board-del-v1` (tombstone) over the defined field concatenation ([§6.1](04-payloads.md#61-signing)).
- [ ] `groupInvite (0x06)`/`groupKeyUpdate (0x07)` share the `GroupStatePayload` TLV-16 shape; a receiver MUST require the delivering session peer be the group's creator ([§7](04-payloads.md#7-private-groups)).
- [ ] A private group MUST NOT exceed 16 members; a decoder MUST reject more than 16 roster entries or a `creatorFingerprint` absent from the roster ([§7.2](04-payloads.md#72-roster-encoding)).
- [ ] Group state signatures use context `bitchat-group-v1`, verified against the roster member matching `creatorFingerprint`; a receiver MUST reject an absent or invalid signature ([§7.1](04-payloads.md#71-signing)).
- [ ] `groupMessage (0x25)`'s outer TLV-16 AEAD associated data is `groupID || epoch` ([§7.3](04-payloads.md#73-group-message)).
- [ ] Group message plaintext signatures use context `bitchat-group-msg-v1`; a receiver MUST reject a message whose signer isn't a current member or whose signature fails ([§7.4](04-payloads.md#74-group-message-plaintext)).
- [ ] File payloads (`privateFile 0x20` inner / `fileTransfer 0x22` outer) use the bespoke 1-byte-type + 2-byte-length framing (4-byte BE for `content`'s length), not either general TLV framing ([§8](04-payloads.md#8-files)).
- [ ] A decoder MUST accept the legacy 8-byte `fileSize` length and, on a 4-byte `content`-length mismatch, retry with the legacy 2-byte `content` length; an encoder MUST NOT emit either legacy form ([§8](04-payloads.md#8-files)).
- [ ] An encoder MUST NOT emit `content` over 1 MiB for a general file, or over 512 KiB for a voice note or image ([§8](04-payloads.md#8-files)).
- [ ] Voice (`voiceFrame 0x08` inner / `0x29` outer) is fixed-layout — `burstID`(8B), `seq`(2B BE), `flags`(1B), `payload` — not TLV, and the only defined codec is `0x01 = aacLC16kMono` ([§9](04-payloads.md#9-voice)).
- [ ] `ping (0x26)`/`pong (0x27)` are a fixed 9-byte `MeshPingPayload`; a decoder MUST accept a payload longer than 9 bytes, ignoring the excess ([§10](04-payloads.md#10-mesh-diagnostics)).
- [ ] `vouch (0x12)` batches MUST NOT carry more than 16 attestations, and a receiver MUST reject an attestation timestamped more than 30 days in the past or 1 hour in the future ([§12](04-payloads.md#12-web-of-trust-vouch)).
- [ ] Vouch signatures use context `bitchat-vouch-v1`, verified against the sending session peer's announce-bound signing key ([§12.1](04-payloads.md#121-attestation-signing)).

## 5. Store and Forward

- [ ] A relay MUST NOT re-send a packet it authored, a packet addressed to its own peer ID, or a packet at `ttl` 0 or 1-after-decrement; `requestSync (0x21)` MUST NEVER be relayed regardless of `ttl` ([§1.1](05-store-and-forward.md#11-suppression)).
- [ ] The fanout-subsetting algorithm for broadcasts other than `fragment`/`announce`/`requestSync` — split horizon, link collapse, subset size `k = ⌈log₂ n⌉ + 1` clamped `[1,n]` for `n > 2`, ranked by ascending `SHA-256("{messageID}::{id}")`, ties by `id` — matches the defined procedure exactly ([§1.3](05-store-and-forward.md#13-fanout-subsetting)).
- [ ] `fragment`, `announce`, and `requestSync` bypass fanout subsetting entirely ([§1.3](05-store-and-forward.md#13-fanout-subsetting)).
- [ ] Directed delivery follows the preference order direct link → v2 source route (falling back to flood if the next hop is not connected) → flood ([§1.4](05-store-and-forward.md#14-directed-delivery)).
- [ ] Source-route origination requires all of: locally authored only (a relay MUST NOT attach or alter a route on a packet it didn't originate), a single-peer `recipientID`, `ttl > 1`, the recipient not already directly connected, and a full v2-capable path known ([§1.5](05-store-and-forward.md#15-source-route-origination-policy)).
- [ ] The sender outbox MUST NOT discard an undelivered private message outright; it MUST retain and retry until a `delivered`/`readReceipt` acknowledgement or a limit-based drop ([§2](05-store-and-forward.md#2-sender-outbox)).
- [ ] `courierEnvelope (0x04)` is TLV-16 with `recipientTag`(16B), `expiry`(8B), `ciphertext`(1-16384B) REQUIRED; a decoder MUST reject an envelope missing any of the three, or whose `ciphertext` exceeds 16384 bytes ([§3.1](05-store-and-forward.md#31-wire-format)).
- [ ] The rotating recipient tag is `HMAC-SHA256(recipientStaticKey, "bitchat-courier-tag-v1" || epochDay[4B BE])[0..16]` with `epochDay = floor(unixSeconds/86400)`, and a tag-checking party MUST test `epochDay−1`, `epochDay`, and `epochDay+1` ([§3.2](05-store-and-forward.md#32-rotating-recipient-tag)).
- [ ] An over-quota courier deposit MUST be rejected; at the total cap, eviction is oldest-first with verified-tier evicted before any favorite-tier, and a verified deposit MUST be rejected outright once only favorite-tier mail remains ([§3.3](05-store-and-forward.md#33-deposit-policy-and-trust-tiers)).
- [ ] Spray-and-wait: an envelope with `copies=1` MUST NOT be sprayed further, and the same envelope MUST NOT be sprayed to a peer it has already been sprayed to ([§3.4](05-store-and-forward.md#34-spray-and-wait)).
- [ ] `requestSync (0x21)` is TLV-16 with `p`(1B, 1-32), `m`(4B BE, >0), `data` (GCS bitstream) REQUIRED and always present even for an empty cache; a decoder MUST reject `p > 32` or `m = 0` ([§4.1](05-store-and-forward.md#41-request_sync-payload)).
- [ ] `requestSync` MUST be sent with `ttl = 0` ([§4.1](05-store-and-forward.md#41-request_sync-payload)).
- [ ] The GCS filter construction — packet ID as the first 16 bytes of `SHA-256(type || senderID || timestamp || payload)`, top-bit-cleared 63-bit hash mod `m` bucket mapping (remapping 0→1), Golomb-Rice delta encoding with parameter `p`, MSB-first bit packing, zero-padded final byte — is reproducible bit-exactly from the defined encoding ([§4.2](05-store-and-forward.md#42-golomb-coded-set-filter)).
- [ ] A sync response is sent as the packet's own original type, MUST have `ttl = 0`, and MUST have `isRSR` set; `announce`/`prekeyBundle` responses are exempt from the `sinceTimestamp` cursor ([§4.4](05-store-and-forward.md#44-responses-and-the-rsr-flag)).
- [ ] Gossip-sync scope is exactly `announce, message, fragment, fileTransfer, boardPost, prekeyBundle, groupMessage`, and MUST NOT cover `courierEnvelope`, `ping`/`pong`, `nostrCarrier`, `voiceFrame`, `noiseHandshake`/`noiseEncrypted`, or `requestSync` itself ([§4.5](05-store-and-forward.md#45-cache-scope-and-retention)).
- [ ] Delivery-metric counters, if kept, MUST NOT record message IDs, peer identities, or timestamps, and MUST NOT be transmitted off-device ([§5](05-store-and-forward.md#5-delivery-metrics)).

## 6. Nostr Bridge

Private messages, geohash public channels, relay selection, and courier drops (this section's first four items) are REQUIRED — bitchat's only long-distance transport. `gateway` and `bridge` (the remaining items) are each capability-gated and OPTIONAL to implement overall, but an implementation advertising either `PeerCapabilities` bit MUST implement that mechanism's items exactly.

- [ ] A Nostr event's `id` is the lowercase-hex SHA-256 of its canonical `[0,pubkey,created_at,kind,tags,content]` serialization, and `sig` is a 64-byte BIP-340 Schnorr signature over `id`; an implementation MUST reject a mismatched `id` or a failed `sig` ([§1](06-nostr-bridge.md#1-event-construction)).
- [ ] The private-message envelope's three layers match: rumor (kind 14, empty or single legacy `p`-tag, unsigned), seal (kind 13, empty tags, signature authenticates the sender), gift wrap (kind 1059, `tags` exactly `[["p", recipientPubkey]]`, signed by a fresh one-time key) ([§2.1](06-nostr-bridge.md#21-envelope-layers)).
- [ ] Encryption is ECDH secp256k1 → `HKDF-SHA256(ikm=shared, salt="", info="nip44-v2", L=32)` → XChaCha20-Poly1305 with a random 24-byte nonce → `content = "v2:" || base64url(nonce||ciphertext||tag)`; a decoder MUST reject `content` under 41 bytes after the `v2:` prefix strip or lacking the prefix entirely ([§2.2](06-nostr-bridge.md#22-encryption)).
- [ ] A rumor's content decrypts to `"bitchat1:" || base64url(packetBytes)`, where the embedded packet has `type=noiseEncrypted(0x11)`, no signature, and `ttl=7` ([§2.3](06-nostr-bridge.md#23-embedded-bitchat-packet)).
- [ ] Ephemeral chat (kind 20000) `tags` MUST include exactly one `["g", geohash]`; presence (kind 20001) has empty content and `tags` = exactly `[["g", geohash]]` ([§3.1](06-nostr-bridge.md#31-ephemeral-chat-and-presence)).
- [ ] A location note (kind 1) MUST include exactly one `["g", geohash]` tag; a deletion (kind 5) has `tags` = exactly `[["e", noteEventID]]` and empty content, signed with the original event's key ([§3.2](06-nostr-bridge.md#32-location-notes-and-deletion)).
- [ ] A courier drop (kind 1401) has `content` = standard-padded base64 of the courier-envelope TLV-16 wire bytes, `tags` including exactly one `["x", recipientTagHex]` and exactly one `["expiration", unixSeconds]` matching the envelope's `expiry`, signed with a fresh single-use Nostr identity ([§5](06-nostr-bridge.md#5-courier-drops)).
- [ ] Courier drop retrieval subscribes on candidate recipient tags for `epochDay−1/epochDay/epochDay+1`; on a match, the retriever MUST verify its own computed `recipientTag` against the event's `x` tag before treating it as addressed, and MUST discard (not open or forward) an envelope already expired by its own `expiry` ([§5](06-nostr-bridge.md#5-courier-drops)).
- [ ] `NostrCarrierPacket (0x28)` is TLV-16 with `direction`(1B), `geohash`(1-12B), `eventJSON`(1-16384B) all REQUIRED; a decoder MUST reject a `direction` byte outside `0x01`-`0x04` ([§6.1](06-nostr-bridge.md#61-nostrcarrierpacket-wire-format)).
- [ ] A decoder MUST independently re-verify a carried `eventJSON`'s signature after decoding ([§6.1](06-nostr-bridge.md#61-nostrcarrierpacket-wire-format)).
- [ ] Gateway loop prevention holds: an event learned from a `fromGateway` mesh broadcast MUST NOT be re-published, re-uplinked, or rebroadcast; an already-uplinked event MUST NOT later be downlinked, and no event is published or rebroadcast more than once; uplink is attempted only for a locally-composed event ([§6.4](06-nostr-bridge.md#64-loop-prevention)).
- [ ] A `bridge`-advertising implementation MUST NOT deviate from its rendezvous-cell (geohash precision 6), kind-reuse (20000/20001 with `r` instead of `g` tags), and loop-prevention rules ([§7](06-nostr-bridge.md#7-bridge)).
- [ ] A `fromBridge` carrier MUST be accepted for injection regardless of local `bridge` enablement, since reception is passive ([§7.3](06-nostr-bridge.md#73-receiving-and-the-radio-race)).
- [ ] A radio-received copy of a message MUST take precedence over a bridge-relayed row that only matched on the untrusted `m`-tag hint; the receiver MUST replace the bridge row, not display both ([§7.3](06-nostr-bridge.md#73-receiving-and-the-radio-race)).
- [ ] A client honoring a NIP-09 deletion MUST verify the deleting event's signature matches the original event's key before acting on it, and MUST independently discard an expired courier envelope regardless of relay-side garbage collection ([§8](06-nostr-bridge.md#8-expiration-and-deletion)).

## 7. Test Vectors

[`bitchatTests/Noise/NoiseTestVectors.json`](../bitchatTests/Noise/NoiseTestVectors.json) is the normative test-vector source for the `XX` pattern ([§2](03-noise.md#2-live-sessions-the-xx-pattern)): two independently-sourced vectors for `Noise_XX_25519_ChaChaPoly_SHA256`, each giving the initiator/responder static and ephemeral private keys, the handshake prologue, and the full sequence of handshake and transport message payload/ciphertext pairs. An implementation's `XX` handshake and transport encryption MUST reproduce every `ciphertext` in both vectors from the given keys and payloads.

No equivalent vector file exists yet for the `X` pattern, courier envelopes, or the wire-format/BLE framing layers — conformance to those mechanisms is checked against this chapter's checklist items only, not a hex fixture, for this `0.1.0` release.

## 8. Known Gaps (Non-Normative)

The following capability bits and concepts are used normatively elsewhere in this specification but have no defined wire mechanism of their own. They are not checklist items — there is nothing to check yet — and are noted here so an implementer does not mistake the absence of a checklist entry for the absence of the concept.

- **`wifiBulk`** (`PeerCapabilities` bit 1, [§5.1](04-payloads.md#51-peercapabilities-bitfield) of Payloads) is defined only as "peer supports bulk transfer over a local Wi-Fi side channel." No chapter specifies a wire format, discovery mechanism, or session-establishment procedure for this side channel.
- **`favorite` / `mutual favorite`** gates courier deposit trust tiers ([§3.3](05-store-and-forward.md#33-deposit-policy-and-trust-tiers) of Store and Forward), Nostr private-message reachability, and relay-identity separation ([§2.4](06-nostr-bridge.md#24-sending-and-reachability), [§7.1](06-nostr-bridge.md#71-rendezvous-cell-and-events) of Nostr Bridge), but no chapter specifies how a peer proposes, signals, exchanges, or verifies favorite status on the wire. Only the [glossary](README.md#glossary) defines the term.
- **`privateMediaReceipts`** (`PeerCapabilities` bit 9, [§5.1](04-payloads.md#51-peercapabilities-bitfield) of Payloads) implies delivery/read acknowledgement for private media, but neither `privateFile`/`fileTransfer` ([§8](04-payloads.md#8-files) of Payloads) nor `voiceFrame` ([§9](04-payloads.md#9-voice) of Payloads) defines a `messageID`-equivalent field for a `delivered`/`readReceipt` payload to reference.
