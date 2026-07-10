# Smart Push-to-Talk (PTT) — Design

**Status:** Draft for review — no code yet
**Scope:** Live voice bursts over the BLE mesh, in public chat and Noise DMs, with graceful degradation to the existing voice-note pipeline.

## 1. Goal and core idea

Today, holding the mic button records an AAC `.m4a` and ships it as a `fileTransfer` (0x22) after you release — the receiver hears nothing until the whole file arrives. PTT makes the same gesture *live*: encoded audio frames stream over the mesh while you speak, and nearby receivers hear you with sub-second delay, walkie-talkie style.

The "smart" part is that PTT is not a separate mode the user must choose. It is a **delivery strategy**, picked automatically per conversation:

| Context | Delivery |
|---|---|
| DM, peer connected/reachable on mesh | **Live stream** (Noise-encrypted frames) + finalized voice note for reliability |
| DM, peer only reachable via Nostr | Existing voice-note recording only (no live; media doesn't ride Nostr today) |
| Public mesh chat | **Live broadcast stream** (signed) + finalized voice note, same dedup as DMs |
| Geohash (Nostr) channels | PTT unavailable (matches existing `canSendMediaInCurrentContext` media policy) |

*(Public originally speced as live-only to avoid doubling bandwidth, but dropping the note broadcast would regress mixed-version meshes — old clients that can't decode live bursts would stop receiving public voice entirely — and late joiners/out-of-range peers would get nothing. The note stays; live receivers absorb it silently.)*

One gesture (hold mic), one mental model ("talk"), and the system degrades from live → reliable-note → unavailable based on what the transport can actually do.

**Bandwidth reality check:** the mesh moves ~15 KB/s per link (469 B fragments at 30 ms spacing); our voice codec needs ~2 KB/s. Live voice fits with a wide margin, even relayed.

## 2. What already exists (reused, not rebuilt)

- **Capture UX:** `ContentComposerView.micButtonView` already implements hold-to-record / release-to-send via `DragGesture`, backed by `VoiceRecordingViewModel`'s state machine and `VoiceRecorder` (AAC-LC, 16 kHz mono, 16 kbps). Mic permission string is already in Info.plist.
- **Reliable delivery:** `BitchatFilePacket` TLV + `fileTransfer` (0x22) + fragmentation + transfer progress + `ChatMediaTransferCoordinator`.
- **Playback:** `VoiceNotePlaybackController` + `VoiceNotePlaybackCoordinator` (single active playback), `WaveformView`, `VoiceNoteView`.
- **Transport:** signed public packets, Noise sessions with typed inner payloads, `RelayController` flood control, `MessageDeduplicator`, `MessageRouter.canDeliverPromptly`.

New work is the **streaming path**: a frame encoder/packetizer, a wire format for bursts, a jitter-buffered receiver/player, relay policy, and the live-bubble UI.

## 3. Wire protocol

### 3.1 Burst framing (shared inner format)

A talk burst is a sequence of packets sharing an 8-byte random `burstID`:

```
[burstID: 8][seq: UInt16 BE][flags: 1][payload…]
```

`flags` bits:
- `0x01 START` — payload is a header TLV: codec (1 B enum, 0x01 = AAC-LC/16kHz/mono), frame duration ms, batch size. Sent as seq 0 and re-attached (piggybacked TLV) every ~2 s so mid-burst joiners can sync.
- `0x02 END` — payload: total data-packet count (UInt16), duration ms (UInt32). Lets receivers detect tail loss.
- `0x04 CANCELED` — sender slid-to-cancel; receivers stop playback, discard buffered audio, and drop the bubble.
- `0x00` (data) — payload is N length-prefixed AAC frames: `[len: UInt16 BE][ADTS-less raw AAC frame]…`

Audio math: AAC-LC at 16 kHz has 1024-sample frames = **64 ms/frame ≈ 130 B at 16 kbps**. A greedy packetizer batches frames up to a **210-byte burst-content budget** (`pttMaxBurstContentBytes`), chosen so the Noise ciphertext (content + 1 inner-type byte + 16-byte tag) stays inside `MessagePadding`'s 256-byte bucket — the whole directed packet is 288 bytes and voice **never enters the fragment scheduler** (which caps concurrent transfers at 2 and would starve file sends). At 16 kbps that works out to **1 frame/packet, ~15.6 pkt/s, ~5.3 KB/s wire** for DMs; public bursts (unpadded, planned for phase 2) can batch 3 frames.

### 3.2 Public mesh: new `MessageType.voiceFrame = 0x29`

- Broadcast (no recipient), **signed** like public messages; unsigned or signature-mismatched frames are dropped on receive.
- **No padding** (add to `BLEOutboundPacketPolicy` alongside `fileTransfer`) — padding to the 512 block would push every packet over MTU into fragmentation.
- TTL: `messageTTL` (7) at origin; `RelayController` gets a `voiceFrame` case mirroring the fragment policy — dense clamp to 5, jitter 8–25 ms — so live audio floods like fragments, not like announces. Per-hop cost is ~10–40 ms; 3 hops stays comfortably inside the jitter buffer.
- Dedup: existing `MessageDeduplicator` (timestamp ms + seq make each packet unique).
- 0x29 is the next free code after `nostrCarrier = 0x28`; unknown types are ignored by older clients (iOS and Android), so rollout is compatible — old clients simply don't hear live bursts.

### 3.3 DM: new `NoisePayloadType.voiceFrame = 0x08`

- Inner payload = the same burst framing, wrapped in `noiseEncrypted` (0x11) directed packets — wire-indistinguishable from other DM traffic by size/type (0x04/0x05 are reserved per the comment in `BitchatProtocol.swift`; 0x08 is the first free slot after `groupKeyUpdate = 0x07`).
- Directed encrypted packets are already always-relayed by `RelayController`, so multi-hop DMs work unchanged.
- Requires an established session; PTT-live is only offered when `noiseService.hasEstablishedSession` (otherwise first hold triggers the normal handshake + falls back to voice-note for that burst).
- Fire-and-forget: **no delivery acks, no retransmit** for frames. Late audio is worthless; reliability comes from the finalized note (§5).

### 3.4 Known traffic-analysis tradeoff

A steady ~8 pkt/s cadence for the duration of a burst is a timing fingerprint even under Noise (observers can infer "someone is speaking to someone", not content). This is inherent to live voice; the doc records it as accepted for v1. Block padding is skipped for voiceFrame (size classes would leak little beyond what cadence already does).

## 4. Sender pipeline

`VoiceRecorder` (AVAudioRecorder → file) can't stream, so PTT capture uses a parallel path in a new `PTTStreamEncoder` actor:

```
AVAudioEngine input tap (native format)
  → PTTInputResampler → 16 kHz mono PCM
  → PTTFrameEncoder (AVAudioConverter) → AAC-LC frames → packetizer → BLEService.sendVoiceFrame
  → the same PCM is simultaneously written to an AVAudioFile .m4a (identical settings
    to VoiceRecorder), so finalization needs no remux step
```

- On release: emit `END`, then hand the finalized `.m4a` to the **existing** `sendVoiceNote` flow. The note's `fileName` embeds the burst ID (`voice_<burstID hex>.m4a`) — that links note↔burst with **zero changes** to `BitchatFilePacket`/Android interop.
- On slide-to-cancel: stop tap, emit `CANCELED`, delete local file, skip finalization. UX note: unlike voice notes, live audio already played on the far side cannot be unsent — the recording UI must make "you are live" unmistakable (see §7).
- Caps: max burst 120 s (matching the voice-note recorder's cap), exactly one outbound burst at a time.
- Audio session: reuse `VoiceRecorder`'s `.playAndRecord` config; add `.duckOthers`.

## 5. Receiver pipeline

New `VoiceBurstAssembler` (keyed by sender + burstID) feeding a `PTTBurstPlayer`:

- **Jitter buffer:** start playback after 350 ms of buffered audio or 500 ms wall-clock, whichever first. Frames decode via `AVAudioConverter` → `AVAudioPlayerNode`.
- **Loss handling:** gap in seq → insert silence for the missing frames (64 ms each) and keep going. No PLC in v1; at these frame sizes brief dropouts are acceptable.
- **Burst end:** on `END`, or 3 s with no frames (talker walked out of range).
- **Persistence:** frames append to an incoming ADTS `.aac` file (already an allowed `MimeType`), so every burst becomes a replayable voice-note bubble containing whatever was captured — even a partial one.
- **Dedup with the finalized note:** when a `fileTransfer` arrives whose fileName carries a burstID we already assembled (DM or public), it silently *replaces* the partial file behind the existing bubble (no new message row, no second notification). Receivers that heard everything live just get a lossless copy.
- **Resource caps:** ≤ 8 concurrent assemblies, ≤ 256 KB per burst (60 s × 2 KB/s + slack), 30 s stale cleanup, and drop inbound frames beyond ~2× realtime per sender (spam/flood guard).

## 6. Playback policy — when does it actually make sound?

Auto-playing strangers' audio is the fastest way to make this feature hated. Rules:

1. **Live autoplay** only when *all* hold: app foregrounded, the burst's conversation is the one currently on screen, and the **"live voice messages"** toggle is on (app-level, in the app-info sheet, default on; per-conversation overrides are a v2 refinement). The same toggle gates live *sending* — off means voice behaves exactly like classic notes in both directions.
2. Otherwise the burst appears as a **live bubble**: pulsing waveform + `LIVE` badge + sender name; tapping it joins playback at the live edge. When the burst ends it becomes a normal voice-note bubble.
3. **One voice at a time:** route through `VoiceNotePlaybackCoordinator`. If two people talk simultaneously, the first burst holds the floor; the second shows as a tappable live bubble. No mixing in v1.
4. Notifications: a live burst in a non-focused DM fires the normal message notification once (at START), not per-frame.

**Floor courtesy (public mesh):** while someone else's burst is live in the current channel, the mic button tints "busy" with the talker's name. Holding it still works — a decentralized mesh has no floor arbiter, and rejecting sends would desync under partitions — but the UI discourages talk-over. Hard floor control (token passing) is explicitly out of scope.

## 7. UX

- **Same gesture:** hold mic = talk. When the live path is active, the recording HUD shows a red pulsing **LIVE** treatment (vs. the current neutral recording UI) so the sender knows audio is leaving in real time, not on release. When live isn't available (Nostr-only peer, no session yet), the HUD looks like today's and behavior is unchanged.
- Slide-to-cancel keeps working in both modes, with the §4 caveat surfaced simply: cancel stops and discards; it can't unplay what was heard.
- VoiceOver: mirror the existing `accessibilityAction` toggle-record pattern on the mic button.
- Foreground-only in v1: no `audio` UIBackgroundMode (App Store review + battery implications). If the app backgrounds mid-burst, capture stops cleanly with END. Background listen/talk is a v2 candidate.

## 8. Latency budget (1 hop, DM)

| Stage | Cost |
|---|---|
| Frame accumulation (1 × 64 ms) | 64 ms |
| Encode + packetize | ~5 ms |
| BLE write + delivery | 30–60 ms |
| Jitter buffer | 350 ms |
| **Mouth-to-ear** | **~470 ms** |

Each relay hop adds ~10–40 ms jitter + radio time. 2–3 hops stays under ~800 ms — solidly in walkie-talkie territory (commercial PoC apps run 300 ms–1 s+).

## 9. Security & privacy summary

- Public frames signed with the existing packet signature; verified against the sender's announce before decode. Unsigned → dropped.
- DM frames ride inside Noise; content confidentiality/integrity as any DM.
- Codec input is validated by frame-length prefixes and total-size caps before touching `AVAudioConverter` (malformed frames dropped, assembly aborted over cap).
- Timing fingerprint accepted per §3.4. No PTT in geohash channels (would put voice on public Nostr relays).
- Mic capture only while the button is held; recording state is always visible.

## 10. New components & touch points

| Piece | Where |
|---|---|
| `PTTStreamEncoder` (tap → AAC → packets) | `bitchat/Features/voice/` |
| `PTTBurstPlayer` (jitter buffer → decode → engine) | `bitchat/Features/voice/` |
| `VoiceBurstFramer` / `VoiceBurstAssembler` (wire encode/decode, caps) | `bitchat/Protocols/` + `bitchat/Services/PTT/` |
| `MessageType.voiceFrame = 0x29` | `localPackages/BitFoundation/.../MessageType.swift` + `BLEReceivePipeline` / `BLEService.handleReceivedPacket` |
| `NoisePayloadType.voiceFrame = 0x08` | `BitchatProtocol.swift` + `ChatTransportEventCoordinator` dispatch |
| Relay policy case | `RelayController` (fragment-like clamp/jitter) |
| No-padding rule | `BLEOutboundPacketPolicy` |
| Pacing/cap constants | `TransportConfig` |
| Live bubble + LIVE HUD + busy mic tint + settings toggle | `VoiceNoteView`/`MediaMessageView`, `ContentComposerView`, conversation settings |
| Delivery-mode selection | `ChatViewModel` / `ChatMediaTransferCoordinator` (reuse `isPeerConnected` / `canDeliverPromptly` / `hasEstablishedSession`) |

## 11. Phasing

1. **Phase 1 — DM live (highest value, lowest blast radius):** encoder, framer, Noise inner type, assembler/player, live bubble, finalize-as-note dedup. Single-hop DMs are the dominant real-world case.
2. **Phase 2 — public mesh:** `voiceFrame` 0x29, signing/verification, relay policy, floor-courtesy UI, autoplay defaults.
3. **Phase 3 (v2 candidates):** background audio mode, mid-burst repair requests (piggyback on REQUEST_SYNC), talk-over mixing, AAC-ELD low-delay profile, dedicated walkie-mode screen, media-over-Nostr (unlocks live-ish PTT for internet peers), Android protocol spec sync.

## 12. Testing

- Unit: framer round-trip (START/data/END/CANCELED, seq gaps, oversize frames), assembler caps + stale cleanup + burstID note dedup, packetizer batch sizing vs. MTU (assert no fragmentation), relay-policy clamps.
- Integration: two-simulator loopback via the existing mesh test harness; loss injection (drop every Nth frame) → verify silence-fill + partial-file persistence.
- Device: two-phone live DM (latency measurement vs. §8 budget), three-phone relay chain, talk-over behavior, cancel semantics, mic-permission-denied path.
