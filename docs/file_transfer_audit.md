# File Transfer Audit (Android PR #440 vs iOS current)

This document catalogs the Android implementation in PR #440 and audits the current iOS codebase, producing a gap analysis and concrete interoperability requirements.

## 1) Android PR #440 Summary (Key Artifacts)

- Message types and protocol
  - New MessageType: FILE_TRANSFER (0x22)
  - BinaryProtocol now supports version v1 and v2
    - v1: 2-byte payload length (UInt16)
    - v2: 4-byte payload length (UInt32) to allow large payload frames
    - Decoding is backward compatible; encoding chooses based on packet.version
  - Fragmentation: FragmentManager creates fragments from the encoded frame; broadcaster paces and tracks progress.

- TLV: BitchatFilePacket (app/src/main/java/com/bitchat/android/model/BitchatFilePacket.kt)
  - TLVs
    - 0x01 FILE_NAME: UTF-8 string; TLV length: 2 bytes (UInt16)
    - 0x02 FILE_SIZE: 4-byte integer (UInt32); TLV length is 2 bytes with value 4
    - 0x03 MIME_TYPE: UTF-8 string; TLV length: 2 bytes (UInt16)
    - 0x04 CONTENT: bytes; SPECIAL CASE – encoded length uses 4 bytes (UInt32) immediately after type (not the 2-byte TLV length)
      - Decoder tolerates multiple CONTENT TLVs (concatenate)
  - Logging & bounds checks; overall size intended to be under a configured cap

- Transfer orchestration
  - BluetoothMeshService
    - sendFileBroadcast(): FILE_TRANSFER packet with version = 2 (to unlock 4-byte payload length)
    - sendFilePrivate(): wrap BitchatFilePacket in NoisePayloadType.FILE_TRANSFER and broadcast as NOISE_ENCRYPTED
  - BluetoothPacketBroadcaster
    - Creates fragments via FragmentManager and sends with pacing (20 ms)
    - TransferProgressManager events keyed by transferId (sha256 of file payload)
    - Cancel via cancelTransfer(transferId)
  - FragmentManager
    - More robust logging and error handling wrapping MessagePadding.unpad and encoding logic

- Utilities & Features
  - FileUtils: save, copy, mime detection, format sizes, saveIncomingFile()
  - VoiceRecorder (MediaRecorder → .m4a AAC, 32 kbps mono) and waveform helpers
  - UI integration: ChatScreen hooks to send voice/image/file notes; full-screen image viewer
  - Permissions & FileProvider setup (Android specific)

- Limits: PR text implies keeping existing limits; code indicates use of v2 frames and BLE fragmentation to support >64KB content. Typical app cap remains around a few MB.

## 2) iOS Current State (Key Findings)

- Message types and protocol (bitchat/Protocols)
  - MessageType: announce(0x01), message(0x02), leave(0x03), noiseHandshake(0x10), noiseEncrypted(0x11), fragment(0x20)
  - No FILE_TRANSFER type in iOS yet
  - BinaryProtocol.swift
    - Fixed header with 2-byte payload length (UInt16)
    - No support for version 2 / 4-byte payload length

- Inline file transfer (current minimal support)
  - BLEService.sendInlineFile(to:filename:mimeType:data:)
    - Builds a simple TLV: [fnameLen(2)][fname][mimeLen(2)][mime][dataLen(4)][bytes]
    - Prefixes with NoisePayloadType.fileInline; sends as NOISE_ENCRYPTED
    - Validates size using NoiseSecurityConstants.maxMessageSize = 5 MB (but BinaryProtocol is limited to 64 KiB frame payload length due to UInt16 length field)
  - ContentView has attach button using .fileImporter, sends via BLE inline file for private chats, or Nostr geohash file event (kind 20001) for public location channels
  - Reception path posts BitChatIncomingInlineFile with TLV bytes; UI parses via parseInlineTLV()

- Fragmentation
  - BLEService maintains incomingFragments for reassembly and handles MessageType.fragment, but full fragment creation/relay path and v2 framing parity with Android’s FragmentManager are missing

- Transfer progress/cancel
  - No TransferProgressManager equivalent; UI uses simulated progress in FileTransferService.simulateProgress()

- Voice recording
  - No AVAudioRecorder wrapper exists yet

- File utilities
  - Basic UTType usage in FileTransferService/ContentView for MIME detection
  - No central FileUtils utility (save incoming files, thumbnails, size formatting, etc.)

## 3) TLV Keys, Field Sizes, Framing Rules (Interoperability Contract)

- TLV keys (must match exactly)
  - 0x01 filename: string (UTF-8), 2-byte length
  - 0x02 filesize: 4-byte integer, TLV length field = 2 with value 4
  - 0x03 mime type: string (UTF-8), 2-byte length
  - 0x04 content: bytes
    - Special case length: 4-byte big-endian immediately following type
    - Decoder should tolerate multiple CONTENT TLVs (concatenate)

- Packet framing (outer)
  - FILE_TRANSFER broadcast (unencrypted): MessageType.FILE_TRANSFER (0x22), packet version = 2 (4-byte payload length)
  - FILE_TRANSFER private: NoisePayloadType.FILE_TRANSFER within NOISE_ENCRYPTED packet (type 0x11); the inner payload is the encoded BitchatFilePacket TLV

- Fragmentation
  - Fragmentation happens on the encoded wire frame; thus v2 with 4-byte payload length is required before fragmenting large frames
  - BLE pacing ~20 ms between fragments; progress computed from total fragments

- Size limits
  - Cap total file size to 5 MB (NoiseSecurityConstants.maxMessageSize on iOS)

## 4) Comparison Matrix (Gaps to Fill on iOS)

| Area | Android PR #440 | iOS Current | Gap / Action |
|---|---|---|---|
| MessageType | Adds FILE_TRANSFER (0x22) | Missing | Add FILE_TRANSFER to MessageType, and route in packet processor |
| BinaryProtocol | v1 (2-byte len) + v2 (4-byte len) support | v1 only | Add v2 encode/decode (backward compatible) |
| BitchatFilePacket TLV | Implemented with special 4-byte length for CONTENT | Not present | Implement in Swift (encode/decode matching Android) |
| Fragmentation | FragmentManager with robust logging and progress | Partial in BLEService | Implement/create FragmentManager analog or extend BLEService to parity (create fragments from full frame, pace, progress) |
| Progress + Cancel | TransferProgressManager + cancelTransfer | None | Implement TransferProgressManager on iOS and expose cancel |
| Private file send | NoisePayloadType.FILE_TRANSFER wrapper | Inline-only fileInline | Add NoisePayloadType.FILE_TRANSFER and path for private FILE_TRANSFER |
| Voice | VoiceRecorder (M4A AAC, 32kbps) + waveform | None | Add AVAudioRecorder wrapper + simple visualizer later |
| File Utils | FileUtils (mime, save incoming, size fmt) | Ad-hoc code | Add FileUtils.swift with MIME, save, thumbnails, formatting |
| UI | Send image/file/voice; progress bars | Attach and share inline; no progress | Add picker UI, progress indicators, cancel |
| Nostr off-mesh | Broadcast to geohash; also PM path | Geohash file event exists | Add FILE_TRANSFER parity for geohash PM flow, maintain 5MB cap |

## 5) Concrete Next Steps

- Step 2: Implement BitchatFilePacket.swift in iOS (exact TLV semantics)
- Step 3: Add FileUtils.swift (MIME, format size, save incoming)
- Step 4: Implement VoiceRecorder.swift (M4A, 16 kHz mono; stop near 5 MB)
- Prepare BinaryProtocol v2 support (separate step; required for broadcast FILE_TRANSFER frames)
- Define TransferProgressManager and hook into BLE send/reassembly
- UI integration for progress and cancel

## 6) Notes on Backward Compatibility

- Keep existing inline fileInline path working for small attachments
- Introduce new FILE_TRANSFER paths incrementally; ensure receivers can decode both inline TLV and file packet TLV
- Add BinaryProtocol v2 decoding first (accept), then enable v2 encoding for large frames once fragmentation is ready
