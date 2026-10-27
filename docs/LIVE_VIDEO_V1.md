# Live video v1 wire protocol

This document defines live video streaming over the bitchat mesh. It follows
the shape of live voice (see [PUSH-TO-TALK-DESIGN.md](PUSH-TO-TALK-DESIGN.md)): live packets are ephemeral and
best-effort, and when the recording is small enough the sender follows the
stream with an ordinary, reliable video file that replaces the viewers' live
copy.

All multi-byte integers use network byte order (big-endian).

## Design summary

- **Codecs.** Video is H.264 Constrained Baseline in Annex B. Every IDR access
  unit carries its SPS and PPS in-band, so any keyframe can start decoding.
  Audio is optional raw AAC-LC at 16 kHz mono, the same encoding live voice
  uses. Every Android device has these hardware codecs (`MediaCodec`), and
  iOS and macOS have them in VideoToolbox and AudioToolbox.
- **Loss resilience.** Media units are aggregated (small) or fragmented
  (large) into self-describing shards, in the spirit of RTP STAP-A/FU-A. Each
  shard fits one unfragmented BLE packet, so a lost packet damages only the
  units it carried. Consecutive shards form a block protected by systematic
  Reed-Solomon parity. Any `k` of a block's `k + r` packets rebuild it, and
  parity costs latency only when something is actually lost.
- **Error containment.** A video unit is released to the decoder only if it
  is a keyframe or if every reference before it arrived. Otherwise the viewer
  holds the last good picture until the next keyframe, rather than showing
  corrupted frames.
- **No feedback channel.** Public streams have many receivers and none of
  them answer. Senders bound latency locally: they pace to a per-route packet
  budget, back the encoder off when their own queue grows, and drop packets
  that are older than a deadline instead of sending them late.

## Type assignments

| Layer | Name | Value | Purpose |
| --- | --- | --- | --- |
| Outer mesh packet | `MessageType.videoFrame` | `0x2D` | Signed public-mesh live video packet |
| Noise inner payload | `NoisePayloadType.videoFrame` | `0x0A` | Encrypted direct-message live video packet |
| Outer private packet | `MessageType.noiseEncrypted` | `0x11` | Existing recipient-directed Noise envelope |

Receivers cap the decoded `VIDEO_FRAME` payload at 4 KiB, the same control
ceiling as `voiceFrame` (see `PacketPayloadLimits` in BitFoundation).
Clients that do not know these values ignore them. `0x2A` and `0x2B` are
reserved for courier spray acknowledgements and `0x2C` is `announceV2`, so live
video takes `0x2D`. `0x09` is the prerelease alias of the private-file Noise
payload, so the inner type is `0x0A`.

## Transport envelopes

Envelopes, signatures, admission and relay rules are the same as live voice,
with `videoFrame` substituted:

- **Public mesh.** Version 1 packet, broadcast recipient, origin TTL 7,
  Ed25519-signed. Receivers accept it only from a known peer with a verified
  announcement, with a broadcast recipient, and within 30 seconds of their own
  clock. Rejected packets are not relayed. Clients without a video player
  (Wear OS) still validate the packet structure and relay it.
- **Direct message.** `[0x0A][VideoBurstPacket]`, encrypted in a
  recipient-directed `NOISE_ENCRYPTED` packet over an established Noise
  session.
- **Relays.** Same jitter (8–25 ms, applied off the per-peer processing queue),
  same TTL cap of 5 in meshes larger than six peers, and never added to gossip
  sync. A relay does not forward a live video packet to a neighbor that its mesh
  graph shows is directly connected to the packet's origin, because that
  neighbor already heard the origin.

## `VideoBurstPacket`

```text
+-------------+-------------+-------------+------------------+
| streamID    | sequence    | kind        | body             |
| 8 bytes     | UInt16 BE   | UInt8       | kind-specific    |
+-------------+-------------+-------------+------------------+
```

`streamID` is random per stream. `sequence` increments with every packet of
any kind (starting at 0) and is used only for loss statistics. A whole packet
is at most **352 bytes**. That keeps a Noise-wrapped, signed packet with up to
four source-route hops below the 512-byte BLE fragmentation threshold.
Receivers reject larger packets.

### START (`kind = 0x01`)

```text
[version: UInt8 = 1][videoCodec: UInt8][width: UInt16][height: UInt16]
[fps: UInt8][bitrateKbps: UInt16][audioCodec: UInt8]
```

| Field | Values |
| --- | --- |
| `videoCodec` | `0x01` H.264 Annex B |
| `audioCodec` | `0x00` none, `0x01` raw AAC-LC 16 kHz mono |
| `width`, `height` | even, 16…1920 |
| `fps` | 1…60 |

START is sent at sequence 0 and repeated immediately before every keyframe's
block, so a viewer who joins mid-stream configures itself at its first
keyframe. A START with different parameters reconfigures the decoder.

### DATA (`kind = 0x00`)

```text
[block: UInt16][index: UInt8][entries region]
```

`index` is the shard's position (0-based, below 32) among the source shards
of `block`. The entries region holds one or more entries:

```text
[flags: UInt8][unitSeq: UInt16][ptsMs: UInt32][fragIndex: UInt8]
[fragCount: UInt8][length: UInt16][bytes: length]
```

- `flags`: bits 0–1 track (`0` video, `1` audio), bit 2 keyframe (video only).
  Any other bit set is invalid.
- `unitSeq`: per-track unit counter, starting at 0 and wrapping at 2^16.
- `ptsMs`: presentation time from the start of the stream.
- `fragIndex < fragCount ≤ 255`; `length ≥ 1`.

A video unit is one H.264 access unit. An audio unit is one raw AAC access
unit, covering 64 ms. The entries region is at most 332 bytes.

### PARITY (`kind = 0x03`)

```text
[block: UInt16][parityIndex: UInt8][k: UInt8][r: UInt8][symbolLen: UInt16][symbol]
```

The FEC symbol of source shard `i` is `[regionLength: UInt16][entries region]`,
zero-padded to `symbolLen`, which is 2 plus the longest region in the block.
Parity row `j` is computed over GF(2^8) with field polynomial `0x11D`:

```text
parity_j = Σ_i  inv(i XOR (k + j)) · symbol_i      for 0 ≤ i < k, 0 ≤ j < r
```

That is a Cauchy generator, so the code is MDS. Bounds are
`1 ≤ k ≤ 32`, `1 ≤ r ≤ 16`, and `symbolLen ≤ 334`. A block is closed when it
reaches the sender's shard limit, when its time window passes, or just before
a keyframe (which starts its own block). Senders choose `r` from a parity
ratio, with at least two parity shards once `k ≥ 4`. Keyframe blocks use a
higher ratio.

### END (`kind = 0x02`)

```text
[durationMs: UInt32][videoUnits: UInt16][audioUnits: UInt16][packets: UInt16]
```

These are the unit totals per track and the total packets sent before END.
Receivers finish once both tracks have released or skipped up to the totals.
Senders emit END three times (consecutive sequence numbers, same body), so a
single lost END cannot leave viewers waiting. Receivers ignore the copies.

### CANCELED (`kind = 0x04`)

No body. Receivers discard the stream and remove its bubble.

## Receiver behavior

- Source shards are parsed when they arrive. Parity rebuilds missing shards as
  soon as `k` symbols of a block are present.
- Units are released per track in `unitSeq` order. A gap is skipped after
  900 ms, which is longer than the widest block window plus relay jitter.
- After any skipped video unit, delta frames are withheld until the next
  keyframe.
- Decoded frames are paced by `ptsMs` behind a 350 ms jitter buffer. A frame
  more than 1.5 s late rebases the clock instead of being shown late.
- Released units are also muxed into a local MP4 (`video_<streamID>_…mp4`).
  This is the viewer's copy if no final file arrives.
- Resource bounds: 4 concurrent streams, 24 MiB per stream, 96 kB/s per stream
  with a 3 s allowance, 48 tracked blocks, and 192 pending or ready units per
  track.
- **Dropouts.** A stream that goes quiet for 4 s is shown as reconnecting. It
  stays open, and it continues at the next keyframe when packets return. A
  quiet stream whose END has arrived finishes instead. A stream with no END
  closes after 90 s of silence. If packets for that stream ID arrive later, the
  same chat bubble goes live again in a new recording segment, and the segments
  are joined into one MP4 when the stream finishes. A stream ended by END or
  CANCELED (or closed for exceeding a bound) never reopens.

## Sender behavior

| Preset | Size | fps | Video | Audio | Parity (delta / key) |
| --- | --- | --- | --- | --- | --- |
| Low (default) | 144×192 | 8 | 18 kbps | 12 kbps | 0.20 / 0.40 |
| Medium | 240×320 | 12 | 56 kbps | 16 kbps | 0.20 / 0.35 |
| High | 480×640 | 24 | 360 kbps | 24 kbps | 0.15 / 0.30 |

- **Pacing.** The sender paces to the lower of the preset's rate and the
  route's packet budget: 24 packets/s over BLE, 300 over Wi-Fi Aware
  (Android only).
- **Congestion control.** The controller reacts to the deeper of its own
  pacing queue and the busiest BLE link queue. It backs the H.264 bitrate off
  multiplicatively, probes back up additively once the queue stays short, and
  skips video (audio continues) when the queue is far behind. Packets that wait
  longer than 1.2 s in the pacing queue, or 1.5 s in a BLE link queue, are
  dropped.
- **Link usage.** Live packets go to each neighbor once, preferring the GATT
  client link. Client links request high connection priority while a stream is
  being sent or watched.

### Final file

The sender muxes the same encoded samples into `video_<streamID>.mp4` (the
stream ID as 16 lowercase hex characters). If the file fits one mesh file
transfer (at most 100 KiB, because file transfers are limited to 256
fragments), it is sent as an ordinary `video/mp4` file, and receivers replace
their live bubble with it, exactly as finalized voice notes do. Longer streams
are not resent: viewers keep their reconstruction, and the sender shows its
own recording locally.

Recorded clips and gallery videos are sent as ordinary `video/mp4` files named
`clip_*.mp4`, never `video_<16 hex>.mp4`. They are transcoded to fit 100 KiB:
the bitrate comes from the duration, the source is trimmed to 60 s, the aspect
ratio is kept in 16-pixel blocks, and audio is dropped below about 30 kbps.

## Golden vectors

For stream ID `01 02 03 04 05 06 07 08`:

```text
# START, seq 0: H.264, 144x192, 8 fps, 24 kbps, AAC
01 02 03 04 05 06 07 08 00 00 01 01 01 00 90 00 C0 08 00 18 01

# DATA, seq 5, block 2, shard 0: one video keyframe entry, unit 1, pts 64, bytes DE AD BE
01 02 03 04 05 06 07 08 00 05 00 00 02 00 04 00 01 00 00 00 40 00 01 00 03 DE AD BE

# PARITY, seq 6, block 2, row 0 of k=1 r=1, symbol AA BB CC
01 02 03 04 05 06 07 08 00 06 03 00 02 00 01 01 00 03 AA BB CC

# END, seq 42: 2688 ms, 16 video units, 41 audio units, 42 packets
01 02 03 04 05 06 07 08 00 2A 02 00 00 0A 80 00 10 00 29 00 2A

# CANCELED, seq 3
01 02 03 04 05 06 07 08 00 03 04
```

The executable vectors are `VideoBurstPacketTest.goldenVectorsMatchSpecification` (Android) and `VideoBurstPacketTests` in `bitchatTests/Features/Video` (iOS).

## Platform notes (iOS and macOS)

- **Link usage.** Broadcasts already go once per peer (duplicate links to the
  same peer are collapsed). Public live video is exempt from the per-packet
  neighbour subset other broadcasts use, so every direct neighbour of the
  sender gets every packet. CoreBluetooth lets only the peripheral role ask
  for a faster connection interval, so while a stream is sent or watched,
  subscribed centrals get `setDesiredConnectionLatency(.low)`.
- **Deadlines.** Public live voice and video waiting more than 1.5 s in a BLE
  pending write or notification queue are dropped instead of sent late.
- **Congestion signal.** The deeper of the per-peripheral pending write
  queue and the pending notification queue.
- **Private packets.** A 352-byte packet inside Noise pads to the 512-byte
  bucket, which still fits one write on a 512-byte link.
- **Capture.** The Simulator has no camera, so the video screen uses a
  synthetic test card and tone there.

## Implementation references

Android:

- `app/src/main/java/com/bitchat/android/features/video/VideoBurstPacket.kt`: wire format (also compiled into Wear OS for relay validation)
- `.../features/video/ReedSolomonErasure.kt`: GF(2^8) Cauchy erasure code
- `.../features/video/VideoStreamPacketizer.kt`, `VideoStreamAssembler.kt`: sender and receiver state machines
- `.../features/video/LiveVideoCapture.kt`, `LiveVideoCongestionController.kt`: capture, pacing, congestion control
- `.../features/video/LiveVideoManager.kt`, `LiveVideoDecoder.kt`: receive, decode, reconstruction
- `.../features/video/VideoTranscoder.kt`: clip and gallery transcoding

iOS and macOS:

- `bitchat/Protocols/VideoBurstPacket.swift`: wire format
- `bitchat/Features/video/ReedSolomonErasure.swift`, `VideoStreamPacketizer.swift`, `VideoStreamAssembler.swift`: FEC and the sender and receiver state machines
- `bitchat/Features/video/LiveVideoSendSession.swift`, `LiveVideoCongestionController.swift`: encoding, pacing, congestion control
- `bitchat/Features/video/LiveVideoH264Encoder.swift`, `LiveVideoH264Decoder.swift`, `LiveVideoMp4Writer.swift`, `VideoTranscoder.swift`: VideoToolbox and AVFoundation media
- `bitchat/ViewModels/ChatLiveVideoCoordinator.swift`: receive, decode, reconstruction, absorbing the final file
- `bitchatTests/Features/Video/`: wire, FEC, loss-simulation, congestion and coordinator tests
