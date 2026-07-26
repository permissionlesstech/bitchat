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
- **First feature-owned state**: `BLEMeshPingTracker` holds the /ping
  probe map and per-link response budget as pure state with unit tests —
  the template for peeling the remaining features.

Full suite green throughout (1,953 tests), identical wall-clock — BLE
throughput is nowhere near what one serial queue sustains.

## Remaining roadmap (in order)

1. **Feature peeling.** Move each feature's state maps and handlers into
   a module in the `BLEMeshPingTracker` mold: private media (six
   generation-keyed maps + policy resolution — its main-actor reads
   become a lock-backed store inside the module), courier, prekeys,
   board, voice, file transfer, groups. The engine keeps a registry of
   handled message types instead of a giant switch. Each module lands as
   its own PR with its state's invariants unit-tested.
2. **Transport protocol split.** Continue what the capability ports
   started: `Transport` shrinks to lifecycle + identity + snapshots +
   basic messaging; files/voice/courier/board/diagnostics/verification
   become capability protocols; `NostrTransport` drops its inert stubs;
   coordinators declare the capability they need instead of receiving
   the whole god-protocol (~48 call sites across 14 files).
3. **Link-layer extraction.** With the file slimmed, move the CB
   delegates, scheduling, duty cycle, and buffers behind
   `LinkEvent`/`LinkCommand` ports. Decide the link-auth boundary here:
   `noiseAuthenticatedLinkOwners` and the rebind containment rules are
   mesh security state that currently lives on bleQueue for atomicity
   with bindings — the port design must keep "binding + auth check" one
   critical section or make bindings engine-owned.
4. **Sans-I/O engine core + simulator.** Make the engine formally
   `handle(event) -> [Effect]`, feed it from a `SimulatedLinkLayer`, and
   move the multi-node E2E suite onto deterministic simulation (no
   `waitUntil`, no timing hygiene battles). Property tests become
   possible: relay-storm bounds, partition-heal convergence, dedup
   soundness under duplicate floods.

## What this is not

No wire changes: packet formats, signing (padding is signed), the
peerID identity binding, and courier tag construction are untouched —
see the wire-landmines notes before assuming any of that is local.
