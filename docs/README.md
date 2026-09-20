# bitchat documentation index

This directory holds the technical design and reference documents for bitchat.
For the user-facing README, see the [repository root](../README.md). For
contributing, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Architecture and design

- [ARCHITECTURE_V2.md](ARCHITECTURE_V2.md) — the app-layer rebuild: `AppRuntime`
  as composition root, `AppEventStream`, and the separation between app and
  transport.
- [BLE-ARCHITECTURE-V3.md](BLE-ARCHITECTURE-V3.md) — plan of record for
  restructuring `BLEService` from a single god-object into a layered mesh stack.
- [CONVERSATION-STORE-DESIGN.md](CONVERSATION-STORE-DESIGN.md) — `ConversationStore`
  as the sole holder of message state; the migration steps and deviations.
- [GeohashPresenceSpec.md](GeohashPresenceSpec.md) — the ephemeral Nostr event
  kind for presence heartbeats in geohash location channels.
- [PEER-ID-ROTATION.md](PEER-ID-ROTATION.md) — the wire-protocol change for
  peer-ID rotation. Draft for cross-platform review; derivations and wire
  format are implemented and tested but not wired into the shipping mesh.
- [SOURCE_ROUTING.md](SOURCE_ROUTING.md) — the source-based routing extension
  (v2) for unicast across the mesh. Implemented on Android and iOS.
- [PUSH-TO-TALK-DESIGN.md](PUSH-TO-TALK-DESIGN.md) — live voice bursts over
  the BLE mesh, in public chat and Noise DMs, with graceful degradation to
  the voice-note pipeline.
- [REQUEST_SYNC_MANAGER.md](REQUEST_SYNC_MANAGER.md) — the sync-request
  attribution and timestamp validation work, mirroring the Android
  implementation.
- [PRIVATE-MEDIA-MIGRATION.md](PRIVATE-MEDIA-MIGRATION.md) — the
  `NoisePayloadType.privateFile` migration for end-to-end encrypted media.

## Transport and integration

- [TOR-INTEGRATION.md](TOR-INTEGRATION.md) — how Tor (via Arti) is integrated
  for Nostr relay connections.
- [ARTI-BINARY-PROVENANCE.md](ARTI-BINARY-PROVENANCE.md) — provenance and
  review process for the vendored Arti static-library xcframework.

## Security and privacy

- [privacy-assessment.md](privacy-assessment.md) — the privacy assessment for
  the app, covering what the mesh and Nostr transports expose.
- [VERIFYING-A-BUILD.md](VERIFYING-A-BUILD.md) — how to verify a copy of
  bitchat against the per-release source manifest, and what to do when only a
  compiled build is available.
- [../SECURITY.md](../SECURITY.md) — responsible disclosure process for
  security vulnerabilities.
- [../WHITEPAPER.md](../WHITEPAPER.md) — the protocol whitepaper (design
  goals, architecture, delivery guarantees).
- [../BRING_THE_NOISE.md](../BRING_THE_NOISE.md) — the Noise Protocol
  integration notes for the mesh transport.

## Conventions

- Documents here describe **implemented and tested** behaviour. Drafts and
  unshipped work are marked as such at the top of the document.
- When a document is updated, link it from this index if it is new.
- Prefer descriptive filenames (`PUSH-TO-TALK-DESIGN.md`, not `ptt.md`) so
  the index reads as a table of contents.
