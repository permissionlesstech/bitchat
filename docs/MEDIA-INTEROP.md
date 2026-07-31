# Cross-platform media interop (iOS ↔ Android)

Text messages mesh fine across clients. **Images and voice notes** use the
file-transfer packet (`MessageType.fileTransfer`) plus, for DMs, Noise-sealed
private-media delivery. Failures are usually silent on the receiver: the
sender shows "sent," the receiver never grows a bubble.

This note is for debugging reports like
[#1518](https://github.com/permissionlesstech/bitchat/issues/1518)
(Android → iOS media missing; iOS → Android OK).

## Wire shape both sides agree on

Android documents the TLV file packet in
[`bitchat-android` `docs/file_transfer.md`](https://github.com/permissionlesstech/bitchat-android/blob/main/docs/file_transfer.md).
Canonical MIME strings from Android send paths today:

| Kind | MIME |
|------|------|
| Photo | `image/jpeg` |
| Voice | `audio/mp4` |

iOS accepts those via `MimeType` / `BLEIncomingFileValidator`. A MIME reject
or magic-byte mismatch is logged (`MIME REJECT` / `MAGIC REJECT`) and the
payload is dropped — there is no in-chat error bubble yet.

## Version skew (the #1518 smoking gun)

Reporter stack in #1518:

- Android **1.7.4**
- iOS App Store **1.7.0** (tag `v1.7.0`, 2026-07-08)

After `v1.7.0`, main gained several **private-media** fixes that App Store
1.7.0 does not include, including (non-exhaustive):

- Encrypt private media before BLE fragmentation
- Persist authenticated private-media delivery receipts
- Retry confirmed private media after reconnect
- Earlier: stamp incoming DM images delivered (#1402)

Public / mesh file transfer and private Noise media do not share the same
code path. A skew where Android has newer private-media behavior than iOS
1.7.0 matches "private chat photos die Android→iOS, text is fine."

**First remediation for reporters:** install an iOS build from current
`main` (TestFlight / Xcode) or wait for the next App Store cut that includes
the July private-media stack — do not assume MIME incompatibility until that
is ruled out.

## What to collect if it still fails on matched builds

On the **iOS** device, with verbose logging / Console:

1. `MIME REJECT` / `MAGIC REJECT` / `Failed to decode file transfer`
2. Whether the chat is **mesh/public** vs **private DM**
3. Exact app versions on both ends (build number, not just marketing version)
4. Whether Tor / Nostr relay delivery is involved (geohash) vs BLE-only

On Android, confirm `MediaSendingManager` still emits `image/jpeg` /
`audio/mp4` for the failing send.

## Maintainer release gate

Before cutting an App Store build that claims Android media parity, run the
device matrix in [#1580](https://github.com/permissionlesstech/bitchat/issues/1580)
**plus**:

- [ ] Android → iOS private DM image
- [ ] Android → iOS private DM voice note
- [ ] iOS → Android private DM image (control)
- [ ] Android → iOS public/mesh image (control)

See also Tor / distribution notes in `docs/VERIFYING-A-BUILD.md` when the
store build itself is unreachable.
