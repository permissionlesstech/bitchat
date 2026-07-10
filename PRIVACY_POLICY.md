# bitchat Privacy Policy

*Last updated: July 2026*

## Our Commitment

bitchat is designed for private, account-free communication. This policy describes what the app keeps on your device, what it sends when you use mesh or optional internet features, and how long local data can remain.

## Summary

- **No project-operated accounts or messaging servers** — Bluetooth mesh is peer-to-peer; optional internet features use public or user-selected Nostr relays.
- **No analytics, advertising, telemetry, or tracking** — the app does not contain an analytics or advertising SDK.
- **No sale of data** — the project does not sell user data or build advertising profiles.
- **Open source** — the storage, networking, and cryptography described here can be inspected in the source code.

## What bitchat Stores on Your Device

1. **Identity and cryptographic keys**
   - Noise, signing, group, prekey, and optional Nostr identity material is generated locally.
   - Secret keys are stored in the system keychain. Public keys are shared when required for messaging, verification, groups, or Nostr events.
   - Keys remain until they are rotated, removed by the relevant feature, erased with panic wipe, or removed with the app.

2. **Nickname, preferences, and relationships**
   - Your nickname, settings, favorites, petnames, read-receipt identifiers, and bounded operational metadata are stored locally.
   - The share extension briefly places content you choose to share in the app-group preferences so the main app can import it.

3. **Private group state**
   - Group names, rosters, creator identity, and key epoch are stored as protected files in Application Support.
   - Current group keys are stored in the keychain. Group state remains until you leave or remove the group, panic-wipe the app, or remove the app.

4. **Queued and carried private messages**
   - An outgoing private message that has not been acknowledged may remain for up to 24 hours in a bounded, encrypted outbox. The outbox is sealed with ChaCha20-Poly1305 and its key is stored in the keychain.
   - A device acting as a courier may store a bounded opaque end-to-end encrypted envelope for another user for up to 24 hours. The courier cannot read its message content.
   - A panic wipe deletes both stores.

5. **Recent public mesh messages and notices**
   - Signed public mesh messages may be kept in a protected local gossip archive for up to 15 minutes so they can cross mesh partitions and survive a short relaunch.
   - Public bulletin-board posts and deletion tombstones persist until the post's author-selected expiry, at most seven days. Both stores are bounded and panic-wipeable.
   - These items are public to the mesh or board where they are posted; they are not confidential messages.

6. **Media attachments**
   - Voice notes and images you send or receive can be stored under Application Support so they remain playable while referenced by the app.
   - Incoming media is subject to a 100 MB quota with oldest-file eviction. Media is deleted by panic wipe or app removal; some outgoing media can otherwise remain on disk.

7. **Optional location-channel state**
   - Your selected geohash channel, bookmarks, teleport flags, and bookmark display names are stored locally so the UI can restore them.
   - Per-geohash Nostr identities are derived locally from a device seed stored in the keychain.
   - bitchat does not persist exact latitude or longitude and does not include exact coordinates in mesh or Nostr messages.

## Temporary Session Data

While running, bitchat maintains active connections, routing state, deduplication state, and bounded in-memory conversation timelines. Closing the app clears the in-memory timelines and active connections, but it does not erase the persistent stores listed above.

## What Is Shared

### With Nearby Mesh Users

Depending on the feature you use, nearby peers can receive:

- Your chosen nickname and public Noise/signing identity material.
- Announce metadata such as supported capability flags and a bounded list of short direct-neighbor identifiers. When the bridge is enabled, an announce can also include its coarse rendezvous geohash cell.
- Public mesh messages, public notices, and group-control packets you intentionally send.
- Private ciphertext addressed to them, or opaque courier ciphertext they agree to carry.
- Radio metadata available to the receiver, such as approximate Bluetooth signal strength.

Noise identity keys can persist across sessions; do not treat them as anonymous identifiers. Panic wipe rotates local identity state.

### With Private Group Members

Private group members receive the group's name, roster, key epoch, and encrypted group traffic needed to participate. Group messages are confidential to devices holding the current group key, subject to the security of those devices and members.

### With Nostr Relays and Internet Gateways

Internet-backed features are optional. When enabled or used:

- Private fallback messages use encrypted NIP-17 gift wraps. Relays can observe event and network metadata but not the message plaintext.
- Public location-channel messages, notes, notices, and presence include a geohash tag, event kind, timestamp, and a public key. A geohash reveals an approximate area; finer precision reveals a smaller area.
- The optional mesh bridge publishes bridge-enabled public mesh messages and presence to a neighborhood rendezvous cell. Those messages are public to participants and relays for that cell. A per-message “nearby only” choice prevents that message from crossing the bridge.
- Bridge courier drops contain opaque end-to-end encrypted envelopes and a rotating recipient tag. Relays still observe timing and network metadata.
- A device with gateway features enabled may relay signed bridge/location traffic or opaque courier envelopes for nearby mesh devices.

Nostr relays are operated by third parties. Their retention, logging, availability, and privacy practices are outside the project's control. Public events and encrypted events may remain on relays according to each relay's policy.

## Location and Apple Services

Location permission is optional and requested as when-in-use access. It is used to compute geohash channels, bridge rendezvous cells, and nearby place labels.

- Exact coordinates are not included in bitchat mesh or Nostr payloads and are not persisted by bitchat.
- A selected geohash can still reveal an approximate area to peers and relays.
- When bitchat asks the operating system for a friendly place name, Apple's `CLGeocoder` service may process the location under Apple's privacy terms.
- Revoking location permission stops live location sampling. Saved bookmarks remain until you remove them, panic-wipe the app, or remove the app.

## Microphone, Camera, and Media Permissions

- Microphone access is used only while you record a voice note or actively hold live push-to-talk. The resulting audio is sent to the mesh conversation you selected; public-conversation audio is public to that mesh, while private-conversation audio uses the private transport protections described below.
- Voice-note and live-audio files can remain in Application Support under the media retention rules above.
- Camera access is used to scan peer-verification QR codes. Photo-library access is used when you choose an image to send.
- These permissions can be revoked in system settings. bitchat does not record microphone or camera input while the related capture UI is inactive.

## Cryptography

Private and public features use different protections:

- Mesh private sessions use Noise XX with X25519, ChaCha20-Poly1305, and SHA-256.
- Private group messages use ChaCha20-Poly1305; group state and relevant mesh packets use Ed25519 signatures.
- Nostr events use secp256k1 Schnorr signatures. NIP-44 v2 private payloads use secp256k1 key agreement, HKDF-SHA256, and XChaCha20-Poly1305.
- The persistent private-message outbox uses ChaCha20-Poly1305 with a key held in the keychain. Some other protected local identity state uses AES-GCM.
- Public mesh, bridge, geohash, and board content is signed or authenticated as appropriate but is intentionally not confidential.

No cryptographic system can protect content after a recipient reads, copies, screenshots, or exports it.

## Data Retention Summary

- **In-memory chat timelines and active connections:** until the app closes or state is cleared.
- **Queued outgoing private messages:** until acknowledged, dropped by bounded policy, or 24 hours, whichever comes first.
- **Opaque courier envelopes:** until handed off, evicted by bounded policy, or 24 hours, whichever comes first.
- **Recent public mesh gossip:** up to 15 minutes.
- **Public board posts and tombstones:** until expiry, at most seven days.
- **Groups, favorites, preferences, identity keys, bookmarks, and media:** until removed by the feature, panic wipe, quota eviction where applicable, or app removal.
- **Nostr data:** according to the policies of the relays that receive it.

## Your Controls

- **Panic wipe:** Triple-tap the logo to clear local keys, sessions, preferences, groups, queues, carried mail, public archives, board data, and media managed by the app.
- **Feature controls:** Location channels, mesh bridge, internet gateway, and related internet behaviors can be disabled in the app. Some already-published relay data cannot be recalled.
- **System permissions:** Bluetooth, location, microphone, camera, and photo-library access can be revoked in system settings.
- **No account:** The project operates no account record for you to request or export.

## What the Project Does Not Do

bitchat does not:

- Operate an account database or project-owned messaging backend.
- Include advertising, analytics, or tracking SDKs.
- Sell user data or create advertising profiles.
- Include exact GPS coordinates in bitchat mesh or Nostr message payloads.

## Children's Privacy

The project does not knowingly operate a service that collects children's personal data. The app has no account registration or age-verification system. Users and guardians should understand that public mesh, board, bridge, and location-channel posts are visible to other participants and may be relayed.

## Changes to This Policy

Material behavior changes will be reflected in this document and its “Last updated” date. Updating this policy cannot retroactively retrieve data that remained only on a user's device.

## Contact

bitchat is an open source project. For privacy questions:

- View the source: [https://github.com/permissionlesstech/bitchat](https://github.com/permissionlesstech/bitchat)
- Open an issue on GitHub.

---

*This policy is released into the public domain under The Unlicense, like the project itself.*
