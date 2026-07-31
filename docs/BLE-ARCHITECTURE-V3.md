# BLE Transport Architecture V3

The plan of record for restructuring `BLEService` from an 8.3k-line god
object into a layered mesh stack. ARCHITECTURE_V2 rebuilt the app layer
above the transport and deliberately deferred the transport itself; this
document covers that remainder: what already landed, the target shape, and
the order for the rest.

## Why the satellite strategy stalled

V2's transport approach was to peel pure policies and closure-driven
handlers out of `BLEService` while the class kept coordinating. The ~30
pure policy structs were a clear win. The five big handler extractions
were not: each needed an "environment" of 20–30 closures that weakly
capture the service and hop queues back into its state. Logic left, but
state ownership and synchronization never moved, so extraction paid a
plumbing tax that grew as fast as the logic shrank — the five
`make*HandlerEnvironment()` factories alone were ~1.5k lines. The file
held ~60 mutable fields across four concurrency domains whose ownership
lived in comments, and every new feature added Transport requirements,
state maps, and switch cases to the same class.

Two chronic costs came straight from that structure: queue-order
deadlocks (the July 9 main↔bleQueue ABBA freeze), and timing-dependent
tests (correctness only observable through real queues and real time).

## Target shape

A packet-radio stack with one rule per layer about state and threads:

1. **`BLELinkLayer`** — the only CoreBluetooth import. Owns both managers,
   scanning/advertising, duty cycle, connection scheduling, MTU, write
   and notification backpressure buffers, state restoration. Speaks
   `LinkEvent` up (link up/down, bytes in, writable) and `LinkCommand`
   down (send bytes on link, scan/advertise policy). Knows nothing about
   packets, peers, or Noise. bleQueue-confined. A `SimulatedLinkLayer`
   implementing the same port gives multi-node tests real topologies with
   no radios and no wall-clock waits.
2. **Mesh engine** — one serial queue owning all protocol state: wire
   codec, fragmentation, dedup, relay policy, peer registry, topology,
   gossip sync, Noise orchestration. Synchronous single-writer logic; the
   pure policy satellites slot in unchanged. Endgame: the engine core
   becomes `handle(event, now) -> [Effect]` (sans-I/O), which makes the
   whole mesh property-testable and fuzzable in simulation.
3. **Feature modules** — courier, board, prekeys, private media, file
   transfer, voice, diagnostics, groups, verify/vouch each own their
   state and register for their message types. A new feature is a new
   module, not edits to the engine.
4. **App boundary** — a small `Transport` core both transports genuinely
   implement, plus capability protocols discovered with `as?`
   (`MeshBridgingTransport` etc.), replacing the ~90-requirement
   god-protocol and its inert defaults.

### Concurrency contract

State is owned one of three ways:

- **Engine-confined** — mutated only on the serial engine queue
  (`mesh.message`). Cross-thread callers use `onEngine`.
- **bleQueue-confined** — link-layer state next to CoreBluetooth objects
  (link store, write/notification buffers, link-auth maps).
- **Lock-backed store** — state with legitimate cross-domain readers
  (peer registry, local identity/capabilities, traffic monitor). Writes
  still come from one domain; the lock exists so readers never block on
  a queue. Every mutation is a single whole-transition method, so
  readers never observe torn state.

Sync-edge order (deadlock freedom by construction, debug-enforced in
`onEngine`):

```
main / test threads ──sync──▶ engine ──sync──▶ bleQueue
                                  └──sync──▶ noise / identity queues (leaves)
```

Nothing may sync-wait in the reverse direction: bleQueue and the crypto
queues reach the engine only via `async`, and nothing sync-dispatches to
main. Two subtleties worth knowing:

- A closure executed inside a noise-manager critical section entered
  *from* an engine slot may touch engine state directly (the blocked
  slot makes it exclusive) but must never sync-re-enter the engine —
  that is a self-deadlock.
- bleQueue critical sections (e.g. the verified-announce link rebind)
  must receive engine-derived values as arguments rather than fetching
  them through `onEngine`.

## What landed in this pass

- **Lock-backed peer state** (`BLEPeerRegistryStore`): every main-actor
  Transport read (`isPeerConnected`, nicknames, snapshots, capability
  queries) reads a lock, not a queue. Runtime capability bits moved into
  `BLELocalIdentityStateStore` beside the identity they ride announces
  with.
- **bleQueue owns the link buffers**: `pendingPeripheralWrites`,
  `pendingNotifications`, `pendingWriteBuffers` are bleQueue-confined
  (their producers and drains already ran there); the notification drain
  no longer invokes CoreBluetooth from a transport queue.
- **One serial engine queue**: the concurrent message queue and the
  collections queue it guarded state with are one serial domain; every
  barrier flag and per-field ownership comment deleted; ~98 cross-queue
  hops removed. `onEngine` documents and debug-enforces the sync-edge
  order — and its trap caught two latent inversions during migration
  (the announce-rebind path and the noise session-generation closures).
- **Capability ports**: gateway/bridge/courier wiring, the panic
  lifecycle, and radio-state reads go through `MeshBridgingTransport`,
  `PanicResettingTransport`, and `BluetoothStateReporting`; no app code
  casts to `BLEService` anymore.
- **Feature-owned state**: `BLEMeshPingTracker` (the /ping probe map and
  per-link response budget) and `BLEPrivateMediaSessionStore` (the six
  generation-keyed private-media maps plus the convergence-deferral set,
  as whole-transition methods under a leaf lock), both with direct unit
  tests. The private-media store also took the last routine main-actor
  sync reads off the engine and turned the noise-critical-section
  transitions into ordinary leaf-lock calls. Remaining feature state
  (courier, board, prekeys) already lives in injected stores.
- **Transport split**: the mesh-only surface left the god-protocol.
  `Transport` is core only (lifecycle, identity, snapshots, basic
  messaging, noise wrappers); files/private media, voice, courier,
  groups, board, diagnostics, verification, and the public archive are
  eight capability protocols discovered with `as?`, alongside the
  bridging/panic/radio-state ports. The inert-defaults extension is
  gone; consumers that relied on a default keep its safe floor
  explicitly at the call site.
- **Contract pinning**: `BLEQueueContractTests` greps the transport
  sources — only `onEngine` may sync-enter the engine, transport code
  never sync-dispatches to main, and the collections queue stays
  deleted (waivable per line with `queue-contract-ok:` plus a reason).

Full suite green throughout (1,964 tests), identical wall-clock — BLE
throughput is nowhere near what one serial queue sustains.

## Remaining roadmap (in order)

1. **Link-layer extraction.** Move the CB delegates, scheduling, duty
   cycle, and buffers behind `LinkEvent`/`LinkCommand` ports.

   **Link-auth boundary (decided): bindings become engine-owned.**
   Today `noiseAuthenticatedLinkOwners`, the rebind containment rules,
   and the peer↔link binding maps live on bleQueue so that "check
   binding + auth, then act" is one critical section (the rebind path
   and the authenticated-send commit point in
   `notifyOrEnqueueIfAccepted`). That atomicity exists to stop a
   binding from changing between a security check and its action — and
   the engine's serial slot provides exactly the same guarantee once
   every rebind is an engine operation. The residual stolen-link risk
   is unchanged: directed payloads are Noise ciphertext, useless on a
   link that changed hands after the decision. Making bindings engine
   state also puts the receive path in its sans-I/O shape: the link
   layer reports `received(bytes, linkID)` and the engine resolves the
   sender binding, instead of the CB delegate resolving peers before
   handoff. The link layer keeps only physical link state (CB objects,
   connect/subscribe lifecycles, backpressure buffers) keyed by opaque
   link IDs.

   Extraction order: (a) the binding-free radio half — scanning,
   advertising, duty cycle, connection budget/scheduling — moves first
   (it makes no peer decisions); (b) bindings + link-auth migrate to
   the engine, converting `readLinkState` callers; (c) the delegates
   shrink to event emission and move behind the port.

   **(a) and (b) are done.** (a) landed as `BLERadioController`
   (#1539). (b) landed in two steps: #1540 cohered the loose maps into
   `BLELinkAuthState` + `BLELinkBindings` (still bleQueue-owned,
   behavior-identical), and the option-B flip then moved ownership to
   the engine. Since the flip:

   - `linkAuth`/`linkBindings` are engine-owned behind a DEBUG
     `dispatchPrecondition` trap; bleQueue code cannot touch them.
   - The receive path is in its sans-I/O shape: bleQueue decodes
     frames and hands `(packet, linkID)` up through
     `ingestDecodedPacket` (which captures the panic lifecycle at the
     handoff); `attributeAndHandlePacket` resolves the sender binding,
     admits or rejects the claimed sender, applies raw-announce
     binding, and records ingress — all on the engine. Per-link frame
     order is preserved end to end (both queues are serial), which
     supersedes the old batch-local TOCTOU binding.
   - The rotation rebind is one engine slot
     (`rebindLinkAfterVerifiedDirectAnnounce`): containment checks,
     proof retirement, binding flip, reconnect decision, and
     rotated-identity retirement, with only CoreBluetooth cancels
     hopping to bleQueue.
   - Authenticated-send eligibility (`notifyOrEnqueueIfAccepted`,
     `writeOrEnqueueIfAccepted`) is checked on the engine — serialized
     against rebinds by construction — and only the physical admission
     (updateValue / write / backpressure queues) runs on bleQueue.
   - Teardown splits: bleQueue delegates do physical work inline
     (`discardPeripheralLinkPhysical`) and queue the identity half
     (`retirePeripheralLinkIdentity`, binding survivor repair) to the
     engine. A binding can briefly outlive its physical link; queries
     that need liveness join against the physical store via
     `readLinkState` (the engine→bleQueue sync direction), and the
     queued retirement converges the two.
2. **Sans-I/O engine core + simulator.** Make the engine formally
   `handle(event) -> [Effect]`, feed it from a `SimulatedLinkLayer`, and
   move the multi-node E2E suite onto deterministic simulation (no
   `waitUntil`, no timing hygiene battles). Property tests become
   possible: relay-storm bounds, partition-heal convergence, dedup
   soundness under duplicate floods. The remaining feature *code* moves
   (courier, board, prekey, voice, file, group handlers out of the
   packet switch) ride this seam as handler-registered modules instead
   of getting closure-environment extractions now.

   **The simulator half is done — simulator-first.** Because the B2
   receive path already hands `(packet, linkID)` up through one choke
   point, `SimulatedMesh` (bitchatTests/Simulation/) wires real
   CB-free `BLEService` engines edge-to-edge through the outbound tap
   and `_test_ingestFrame` (the production attribution path), with
   per-edge synthetic link IDs and manual-scheduler time. Five
   deterministic multi-node tests run in ~40ms: announce/bind
   convergence, end-to-end Noise establishment, line-topology relay
   within a TTL/frame budget, duplicate-flood dedup, and the panic
   rotation single-slot rebind + containment — the scenario that
   previously required two phones. Fidelity boundary: no physical
   links, so fanout planning/backpressure is not exercised; protocol
   behavior is. On its first day the simulator found a real bug: the
   forced-announce throttle survived panic, so a rotation within
   `bleForceAnnounceMinIntervalSeconds` of the last announce left the
   new identity invisible until the next maintenance cycle
   (`BLEAnnounceThrottle.reset()` now runs in the panic slot).
   **The upward port is named and the delegates live behind it.**
   `BLELinkEvent` (frameDecoded + the four physical lifecycle
   transitions) is the enumerable bleQueue→engine surface; every
   crossing goes through `emitLinkEvent` into one engine consumer
   (`handleLinkEvent`), and the simulated mesh drives lifecycle events
   through the identical enum a radio does (see
   `linkDropEventRetiresBindingAndReconnectHeals`). The CoreBluetooth
   delegate extensions moved to their own files —
   `BLEService+LinkLayerCentralRole.swift` /
   `BLEService+LinkLayerPeripheralRole.swift` — as physical
   bookkeeping plus event emission; the physical-domain members they
   share are `internal` with the queue contract enforced by the
   existing traps and grep guards rather than access control.

   **Deliberately not done:** a formal `handle(event) -> [Effect]`
   effect system, and splitting the engine-domain feature handlers
   into more files. Both would flip the engine's private state
   (noiseService, peerRegistry, the identity domain) to internal for
   purely cosmetic file counts — the domains are already uniform
   (one queue, one rule set) and mechanically guarded. The effect
   formalization should ride actual feature-module extractions when a
   feature earns its own module, not precede them.

## What this is not

No wire changes: packet formats, signing (padding is signed), the
peerID identity binding, and courier tag construction are untouched —
see the wire-landmines notes before assuming any of that is local.
