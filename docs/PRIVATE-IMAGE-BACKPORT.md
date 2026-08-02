# Private Image Backport

This fork keeps private image transfer on the `permissionlesstech/bitchat` v1.7.0 architecture while backporting the private-media security goals needed for original-quality images. The user goal is strict: a private image should arrive byte-identical to the selected source file, without resizing, recompression, metadata stripping, or a downgrade from end-to-end encryption.

The fork did not merge or rebase onto v1.7.1. Upstream v1.7.1 split the old monolithic BLE service into many smaller BLE/private-media files and introduced a different private-media design. Directly adopting that refactor would overlap with the local private-image work, so this branch backports the relevant architectural ideas while keeping the v1.7.0 code shape.

## Phase 1: Private-File Noise Envelope

Before this work, private image/file sends could use the legacy `MessageType.fileTransfer` path: signed and addressed, but still observable by mesh relays. Phase 1 moved private original-image sends onto an explicit Noise payload envelope.

The first design used multiple small Noise chunks. The final Phase 1 design replaced that with one `PrivateFileTransferPacket` envelope, encrypted once and then carried by the existing BLE fragmentation train. The envelope contains:

- `transferID`
- `fileSHA256`
- the encoded `BitchatFilePacket`

`BLENoisePayloadFactory.privateFileTransferPayload` creates one typed `NoisePayloadType.fileTransfer` payload and records the SHA-256 of the exact file bytes. `BLEService.sendOriginalImagePrivate` encrypts that single typed payload through the established Noise session and uses `fragmentTrainId: transferId` for the BLE train.

The ordinary Noise cap stays unchanged:

- `NoiseSecurityConstants.maxMessageSize = 65535`

Private-file payloads get separate caps:

- `maxPrivateFilePlaintextSize = FileTransferLimits.maxFramedFileBytes`
- `maxPrivateFileCiphertextSize = maxPrivateFilePlaintextSize + 20`

This is intentionally not treated as a complete DoS guard equivalent to the normal 64 KiB cap. The payload type is encrypted, so oversized ciphertext must be decrypted before the receiver can prove it is a private-file payload. To bound that trade-off, Phase 1 added a separate oversized-ciphertext rate limit:

- per peer: `maxLargeCiphertextsPerSecond = 3`
- global: `maxGlobalLargeCiphertextsPerSecond = 10`

After decrypt, the receiver still validates type, encoded size, packet structure, and SHA-256 before saving. `ChatMediaTransferCoordinator.handlePrivateFileTransferPayload` rejects malformed envelopes, duplicate transfer IDs, and any content whose SHA-256 differs from `fileSHA256`.

## Phase 2: Media Retention

Phase 2 added retention cleanup for managed media. `BLEIncomingFileStore.defaultMediaRetention` is seven days, and `expireAgedMedia` sweeps these subdirectories:

- `voicenotes/incoming`
- `voicenotes/outgoing`
- `images/incoming`
- `images/outgoing`
- `files/incoming`
- `files/outgoing`

The trigger is launch-only and best-effort: `AppRuntime.performMediaMaintenance` starts a detached utility task after app startup. This keeps startup independent from walking the media tree and avoids adding periodic background behavior.

In-flight live voice captures are deliberately skipped. Any file whose name starts with `voice_live_` is ignored by both quota eviction and retention cleanup, because deleting a progressively written capture can unlink the file under an active writer. Orphaned live captures are handled by the live-voice coordinator startup path instead.

## Phase 3: Capability And Fallback

Phase 3 added two independent capability bits:

- `privateFileNoiseEnvelope`
- `largeNoiseFileCiphertext`

Both are required. A peer that lacks either bit is treated as unsupported for encrypted original private-image transfer. This is fail-closed: the sender does not optimistically transmit a large ciphertext and then discover after the fact that the peer could not parse or accept it.

When the peer does not support the new path, the app asks for explicit consent before using the legacy compatibility path. The alert says:

> The peer does not support sending original images with end-to-end encryption. You can send the original image with the older compatibility mode, but mesh relays may be able to read the file.

The default action is "Don't Send". The destructive confirmation is "Send without E2EE". If the user cancels, no legacy transfer is sent and the message is marked failed with a clear unsupported-peer reason. If the user confirms, the app uses the old `sendFilePrivate` compatibility path for that one image.

This fallback preserves original bytes but does not preserve confidentiality. It exists only as explicit user-approved compatibility behavior.

## Phase 4: Selected v1.7.1 Fixes

Phase 4 cherry-picked only narrow upstream fixes that did not touch the local private-media/BLE custom area. The exclusion rule was strict: no upstream BLE refactor/private-media files, no `BLEIncomingFileStore.swift` from upstream, no custom Noise/private-file/capability paths, and no project/entitlement changes.

Applied commits:

- `733098bb` - fix low-precision geohash country resolution. This patch was already present in local `main`, so no new commit was created.
- `6101e819` from `e8f95e9a` - fix built-in relay actor isolation.
- `54ff5034` from `ab835e58` - do not suggest blocked people in `@mentions`.
- `415dcc55` from `4ef5558d` - replace trapping regex construction with `SafeRegex`.
- `95aa021b` from `e7f4ef09` - show the verified seal next to verified sender names in chat.
- `058d487c` from `c671e3df` - keep the composer focused after sending with the return key.
- `fbd9e69f` - local fix-up for the relay actor-isolation backport, preserving the v1.7.0 relay API while keeping immutable relay constants `nonisolated`.

Two higher-review upstream commits were later found to already be present in local `main`:

- `84d315e6` - bridge dedup with `MeshMessageIdentity`; independent from private-file `transferID` and `fileSHA256`.
- `a4d29401` - canonical direct messages across transport aliases; does not touch media transfer or capability negotiation.

## Verification State

Automated verification is green as of Phase 4:

- `git diff --check` passed.
- `just build` passed.
- `xcodebuild test -scheme 'bitchat (macOS)' -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` passed with 1653 tests and 0 failures.

This is not hardware validation. Real two-device BLE behavior, timing, radio conditions, and interoperability still need manual verification using `TESTING_HARDWARE_VERIFICATION.md` before treating the feature as production-ready.

## Deliberately Open Work

These items remain open by choice, not because they were missed:

- Phase B: opt-in "Original" sending for public/broadcast images. Public images still use the compressed path by default.
- Phase C: transfer progress and cancel UI. The transport has internal progress accounting, but there is no complete user-facing progress/cancel workflow yet.
- Reconsidering a full v1.7.1 update may still be useful later, especially if Android compatibility or upstream media retention semantics become more important than keeping this fork close to v1.7.0.

