## Clarified Problem Statement

**Goal:** Add Sonar sticker support (sonar-sticker-pack-v1) to bitchat iOS: send/receive sticker references in BLE mesh chat, resolve packs from Nostr (kind 30031), download sticker bytes from Blossom HTTPS, and cache them in-app like Sonar does — adapted to bitchat's BLE-only mesh constraints.

**Context (grounded):**
- Spec: sonarprivacy.xyz/docs#SONAR-STICKERS == bitchat-to-sonar `docs/SONAR-STICKERS.md` (kind 30031 packs, kind 10031 installed list, Blossom assets, plaintext sha256 pinning).
- Sonar impl: `core/sonar-ffi/src/lib.rs` `mesh_sticker_content`/`mesh_parse_sticker_content` — encodes refs as `\x1Fsticker\x1F<pack-coordinate>\x1F<shortcode>\x1F<sha256>` inside a normal mesh message content string (Unit-Separator delimited, no new packet type). Sent refs pin the plaintext hash so pack edits can't rewrite history.
- Sonar caching: `MarmotService.fetchStickerPack` / `fetchStickerImage` (Rust core, relay + HTTPS fetch) + in-memory LRU (500 entries) keyed by sha256 in `MarmotChatView`/`SonarAppStore.stickerImageData`.
- bitchat: message content is a String (media already uses content prefixes, see `BitchatMessage+Media.swift` + `MimeType.Category.messagePrefix`). BLE fragmentation at 512-byte MTU, Noise-padded frames. No SonarCore FFI in this repo — encoding must be re-implemented in pure Swift (trivial, ~20 lines).
- bitchat has internet paths despite BLE-only chat: `Nostr/NostrRelayManager.swift`, geohash channels, `ChatViewModel+Tor.swift`. Private media already has an encrypted BLE path (`NoisePayloadType.privateFile 0x20`, `BitchatFilePacket` TLV, docs/PRIVATE-MEDIA-MIGRATION.md).

**Constraints:**
- BLE-only mesh: peers may have no internet. A sticker ref must degrade to a placeholder, never block or corrupt chat.
- No new BLE MessageType needed if content-prefix encoding is used (refs are ~120-160 bytes ASCII — fits easily in one fragmented message).
- Fetch of packs/images is the only internet-dependent step; must match bitchat privacy posture (Tor when enabled).
- Wire compat: reusing sonar's `\x1Fsticker\x1F` encoding keeps interop with Sonar mesh clients; old bitchat clients render it as (odd) text, not a crash.
- Must validate like the spec: HTTPS-only URLs, sha256-in-URL + verify hash before caching, MIME allowlist (webp/png/apng/gif), dim <= 4096.

**Non-goals (to confirm):**
- Publishing/importing packs (Signal import, sonar-cli flow) — out of scope for the app.
- Android implementation (separate repo; wire format must just be documented for it).
- Marmot/MLS group stickers (bitchat has no Marmot).

**Success criteria:**
- User can install/browse a sticker pack and send a sticker in a BLE private chat (and/or public channel per scope answer).
- Recipient with internet renders the sticker; recipient offline sees a clean placeholder, renders later once fetched.
- Sticker bytes are cached on disk keyed by sha256 (content-addressed); reopening chat doesn't re-download.
- Edited-pack attack: ref hash mismatch renders "untrusted sticker", never a substituted image.

## Approaches Considered

### Approach A: Reference-only + lazy fetch + disk cache (port of Sonar mesh encoding)
- Sketch: Pure-Swift port of `mesh_sticker_content` parse/format. Sending = content string in normal private message. Receiving = parse prefix, resolve pack via NostrRelayManager (kind 30031 by author+d), download image via URLSession (Tor-aware), verify sha256, cache in Application Support/stickers/<sha256>. Render via new StickerMessageView; placeholder state when unfetchable.
- Affected files: `Models/BitchatMessage+Media.swift` (new .sticker case), new `Services/StickerPackService.swift` + `Services/StickerCache.swift`, `Views/Media/` new StickerMessageView, `ViewModels/Extensions/ChatViewModel+PrivateChat.swift` (send path), `Nostr/NostrRelayManager.swift` (pack query), picker UI in `Views/`.
- Tradeoffs: smallest BLE footprint, zero protocol risk, wire-compatible with Sonar. Offline peers see placeholders until online. No picker pack-install UX unless added (needs kind 10031 handling or local-only list).
- Effort: M

### Approach B: A + inline BLE delivery of sticker bytes
- Sketch: Same reference encoding, but sender optionally pushes the sticker image over the existing encrypted privateFile (0x20) BitchatFilePacket path so fully-offline BLE peers render immediately; receiver caches by sha256 and skips the HTTPS fetch entirely.
- Affected files: all of A + `Services/BLE/BLEFileTransferHandler.swift`, `BLEIncomingFileStore.swift`, `Models/BitchatFilePacket.swift` (sticker MIME/category), capability bit in `Protocols/PeerCapabilities+Local.swift`.
- Tradeoffs: true BLE-only experience, no internet ever needed between two peers. Costs BLE bandwidth (stickers ~50-300 KB over a 512-byte-MTU fragmented link is slow), more protocol surface (capability negotiation like privateMedia bit 8/9), sender must have the bytes cached. Still needs A's fetch path for pack browsing.
- Effort: L

### Approach C: Full Sonar feature port (install lists, picker, kind 10031 sync)
- Sketch: A + pack install/uninstall synced via kind 10031, full sticker picker sheet (like `SonarEmojiPickerView`), pack discovery via `t=sonar-sticker-pack-v1` relay queries.
- Affected files: all of A + new picker views, `Nostr/NostrIdentity.swift` signing of 10031, pack-management UI.
- Tradeoffs: complete UX parity with Sonar, but pulls Nostr identity publishing into bitchat (which today only reads/geohash-publishes) — bigger privacy and scope footprint. Can be layered on A later.
- Effort: L

## Recommendation

**Approach A first**, designed so B and C layer on without rework: isolate the wire codec (`StickerRef` format/parse, unit-tested against sonar-ffi vectors), the cache (content-addressed by sha256), and the fetch service behind one `StickerPackService`. A matches "download and cache like sonar" exactly, touches no BLE protocol code, and the only real design decisions are fetch privacy (Tor) and offline placeholder UX.

## Decisions (2026-07-27)
1. Transport scope: all text channels — refs are content strings, so rendering works everywhere for free; send UI enabled in DMs + public mesh + geohash channels. (default, user may override)
2. Fetch privacy: follow bitchat's existing Tor setting — relay queries via NostrRelayManager, Blossom HTTPS fetches Tor-routed when Tor is on. (default)
3. Wire: reuse sonar `\x1Fsticker\x1F<coord>\x1F<shortcode>\x1F<sha256>` prefix for interop with Sonar mesh clients. (confirmed lean)
4. Offline peers: placeholder-only in v1 (Approach A); BLE inline-byte delivery (Approach B) deferred. (default)
5. Pack sources: **full kind-10031 install sync like Sonar** (user choice, option C) — scope grows to include Approach C's install-list handling: local install/uninstall, kind 10031 publish/fetch via Nostr identity, pack picker UI, pack discovery optional.

## Scope impact of decision 5
v1 = Approach A + the kind-10031 layer of Approach C:
- `StickerPackService` gains install/uninstall + installed-list sync (fetch 10031 on launch, publish on change, dedupe preserving first-seen order per spec).
- Signing: kind 10031 events signed with the bitchat Nostr identity (`Nostr/NostrIdentity.swift`); confirm which identity is canonical before publishing.
- Picker UI: port the shape of Sonar's `SonarEmojiPickerView` (pack tabs + sticker grid + install from coordinate), reusing `StickerCache` for thumbnails.
- Still out: Signal import/publishing packs (stays in sonar-cli), Android impl, Approach B inline BLE bytes.
