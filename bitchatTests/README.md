# Test Harness Guide

This test suite uses an in-memory networking harness to make end-to-end and integration tests deterministic, fast, and race-free without touching production code.

## In-Memory Bus

- **File:** `bitchatTests/Mocks/MockBLEService.swift`
- **Registry/Adjacency:** Global `registry` maps `peerID` to a `MockBLEService` instance; `adjacency` records simulated links between peers.
- **Setup:** Call `MockBLEService.resetTestBus()` in `setUp()` to clear state between tests; use `_testRegister()` when creating a node to register immediately.
- **Topology:** Use `simulateConnectedPeer(_:)` and `simulateDisconnectedPeer(_:)` to add/remove links. `connectFullMesh()` helpers in tests build larger topologies.
- **Handlers:** Tests can observe data via `messageDeliveryHandler` (decoded `BitchatMessage`) and `packetDeliveryHandler` (raw `BitchatPacket`).
- **De‑duplication:** A thread-safe `seenMessageIDs` prevents duplicate deliveries during flooding/relays.

## Broadcast Flooding

- **Flag:** `MockBLEService.autoFloodEnabled`
- **Intent:** When `true`, public broadcasts propagate across the entire connected component (ignores TTL for reach) while still de‑duping to prevent loops.
- **Usage:** Enabled in Integration tests (`setUp`) to simulate large-network broadcast; disabled in E2E tests to keep routing explicit and verify TTL behavior (see `PublicChatE2ETests.testZeroTTLNotRelayed`).

## Rehandshake Flow (Noise)

- **Why:** The legacy NACK recovery path was removed; recovery now relies on Noise session rehandshake after decrypt failure or desync.
- **Manager:** `NoiseSessionManager` manages per-peer sessions.
- **Pattern:** On decrypt failure, proactively clear the local session and re-initiate a handshake. The peer accepts and replaces their session.
- **Test:** `IntegrationTests.testRehandshakeAfterDecryptionFailure`
  - Corrupts ciphertext to induce a decrypt error.
  - Calls `removeSession(for:)` on the initiator’s manager before `initiateHandshake(with:)` to avoid `alreadyEstablished`.
  - Verifies encrypt/decrypt succeeds post-rehandshake.

## Tips

- **Determinism:** Add small async delays only where handler installation/topology changes could race the first send.
- **Scoping:** Keep `autoFloodEnabled` toggled only within Integration tests; always reset in `tearDown()` to avoid cross-test contamination.
- **Direct vs Relay:** Private messages target a specific peer when adjacent; otherwise they are surfaced to neighbors for relay and, if known, also delivered to the target.

## Quick Start

- Create nodes with `_testRegister()` and connect them:
  - `let svc = MockBLEService(); svc.myPeerID = "PEER1"; svc._testRegister()`
  - `svc.simulateConnectedPeer("PEER2")`
- Observe messages:
  - `svc.messageDeliveryHandler = { msg in /* asserts */ }`
- Enable broadcast flooding for Integration suites only:
  - `MockBLEService.autoFloodEnabled = true`

