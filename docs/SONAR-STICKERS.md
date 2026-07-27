# Sonar Stickers Specification

## Overview

Sonar stickers let peers send image stickers from shared, content-addressed
sticker packs over bitchat. A sticker is **not** sent as image bytes on the
mesh; instead the sender emits a small *sticker reference* as ordinary
message content, and receiving clients resolve the reference to an image via
Nostr + Blossom. This keeps the BLE mesh payload tiny while allowing
arbitrarily large sticker art.

The upstream pack specification (pack format, Blossom publication, signing)
lives at **https://sonarprivacy.xyz/docs#SONAR-STICKERS**. This document
specifies only the bitchat wire format and client behavior. The reference
implementation is byte-identical to sonar-ffi's `mesh_sticker_content` /
`mesh_parse_sticker_content`.

## Wire Format

### Content Prefix

A sticker reference is encoded as message **content** (UTF-8 text) with the
following exact layout:

```
␟sticker␟<pack-coordinate>␟<shortcode>␟<plaintext-sha256>
```

where `␟` is ASCII **Unit Separator (0x1F)**. In Swift:

```swift
"\u{1F}sticker\u{1F}\(coordinate)\u{1F}\(shortcode)\u{1F}\(sha256)"
```

Field order and count are fixed:

| # | Field              | Validation |
|---|--------------------|------------|
| 0 | *(empty sentinel)* | MUST be empty (leading `0x1F`) |
| 1 | tag                | MUST be the literal ASCII string `sticker` |
| 2 | pack-coordinate    | `30031:<64 lowercase hex>:<identifier>`; identifier is 1–80 chars of `[A-Za-z0-9._-]` |
| 3 | shortcode          | 1–64 chars of `[A-Za-z0-9_]` |
| 4 | plaintext-sha256   | exactly 64 lowercase hex chars (SHA-256 of the decrypted sticker plaintext) |

### Parsing Rules

Parsers MUST:

1. Split the content on `0x1F` with **at most 4 splits**, preserving empty
   subsequences.
2. Accept only if the split yields **exactly 5 parts**, `parts[0]` is empty,
   and `parts[1] == "sticker"`.
3. Validate fields 2–4 against the table above; any violation MUST cause the
   whole parse to fail.
4. Treat a failed parse as ordinary text (see *Old-Client Behavior*).
5. Never crash on malformed input: this content is attacker-controlled on
   public channels.

Senders MUST NOT emit a reference whose fields fail validation. The pack
service SHOULD reuse the same validators (`StickerRef.isValidCoordinate`,
`isValidShortcode`, `isValidSha256`) rather than re-implementing them.

## Where References May Appear

Sticker references are always carried as **ordinary message content**:

- **Private DMs** — inside the existing encrypted Noise envelope, exactly
  like a text message. The reference (and thus sticker choice) is never
  visible to relays or passive observers.
- **Public mesh channel** — as ordinary broadcast message content.
- **Geohash / Nostr channels** — as the content of the usual geohash chat
  event (kind 20000), inside the existing encryption for that channel.

No new message type, TLV, or Nostr kind is introduced for sending stickers.
Clients SHOULD gate sending on the peer's advertised capabilities (below);
receiving clients MUST accept sticker content regardless.

## Capability Bit

Support is advertised via the `PeerCapabilities` bitfield in announce
packets (see `localPackages/BitFoundation/.../PeerCapabilities.swift`):

- **`.stickers` = bit 11** (`1 << 11`)

Bit 10 remains reserved (`nonDestructiveNoiseReplacement`, decodable but
unused) and MUST NOT be reused. A peer that advertises `.stickers`
understands the `␟sticker␟` content prefix and can render refs to images.
Senders SHOULD prefer sending a ref only to peers advertising the bit, and
MAY fall back to a short textual description (`:shortcode:`) otherwise.

## Pack Resolution

Resolution is a client-side cache/fetch concern and never touches the mesh:

1. **Pack lookup (Nostr, kind 30031).** The pack-coordinate is an
   addressable Nostr pointer: kind `30031`, author = the 64-hex pubkey,
   `d` tag = the identifier. Clients fetch the pack definition event from
   relays and extract the sticker list.
2. **Image fetch (Blossom).** Sticker image bytes are fetched over
   **HTTPS only** from Blossom servers, **pinned by SHA-256**: the
   downloaded bytes MUST hash to the `plaintext-sha256` from the reference
   (and to the hash in the pack entry) before caching or rendering.
3. **Media constraints.** Decoders MUST enforce the MIME allowlist
   (`image/webp`, `image/png`, `image/apng`, `image/gif`) and dimensions
   ≤ 4096×4096. Packs contain ≤ 200 stickers.
4. **Install list (Nostr, kind 10031).** A user's installed packs are
   published as a replaceable kind-`10031` event whose `a` tags are
   `30031:<pubkey>:<identifier>` pointers, deduplicated in first-seen
   order. Clients SHOULD merge relays' versions keeping the newest event.

See https://sonarprivacy.xyz/docs#SONAR-STICKERS for the full pack and
publication spec.

## Old-Client Behavior

Clients that predate this spec (or do not advertise `.stickers`) see the
reference as a plain UTF-8 string. Because Unit Separator is a non-printing
control character, the content renders as roughly
`sticker 30031:…:my-pack wave deadbeef…` — ugly but harmless. Old clients
MUST NOT crash on this content, and this spec adds no bytes outside the
existing content field, so no migration is required.

## Security Rules

Receivers and pack services MUST:

- **Verify before caching.** Never cache or render image bytes whose
  SHA-256 does not match the expected `plaintext-sha256`.
- **Untrusted-state rendering.** If the currently resolved pack does not
  contain the `(shortcode, hash)` pair from a reference, render an
  "untrusted / unknown sticker" placeholder — not whatever image the pack
  currently has under that shortcode.
- **HTTPS only.** Never fetch or render non-HTTPS URLs, regardless of what
  a pack event claims.
- **Never crash on input.** All parsing of references, pack events, and
  image metadata is attacker-controlled; treat every field as hostile.
