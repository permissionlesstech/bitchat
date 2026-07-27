# 02 — BLE Transport

**Spec:** 1.0.0  
**Canonical source:** `bitchat/Services/BLE/BLEService.swift`,  
`BLEOutboundFragmentPlanner.swift`, `BLEFragmentAssemblyBuffer.swift`,  
`TransportConfig.swift`

---

## 1. Role model

Every BitChat node is **simultaneously** a GATT Central and Peripheral
(dual-role). There is no pairing requirement and no BLE bonding for the mesh
data path.

---

## 2. GATT UUIDs

| Item | UUID | Notes |
|------|------|-------|
| Service (release / “mainnet”) | `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C` | Production builds |
| Service (debug / “testnet”) | `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A` | `DEBUG` builds only |
| Characteristic | `A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D` | Single char on the service |

Characteristic properties (reference):

- Notify, Write, Write Without Response, Read  
- Permissions: readable + writable

iOS restoration identifiers (informational):  
`chat.bitchat.ble.central`, `chat.bitchat.ble.peripheral`.

Independent clients **MUST** use the release service UUID to interoperate with
App Store / production Android builds. Debug UUID traffic will not be seen by
release peers.

---

## 3. Advertising and discovery

Advertisement payload:

```
CBAdvertisementDataServiceUUIDsKey → [serviceUUID]
```

| Field | Policy |
|-------|--------|
| Local name | **MUST NOT** be included (privacy) |
| Manufacturer data | Not used |
| Scan filter | `withServices: [serviceUUID]` |

Discovery may observe a peer-supplied local name if some other stack adds one;
BitChat itself does not advertise a name.

Typical lifecycle:

1. Add GATT service → start advertising service UUID.
2. Scan for the same service UUID.
3. On connect (as central): discover service → discover characteristic →
   subscribe for notifications; write frames to the characteristic.
4. As peripheral: accept writes; push frames via notify.

Connection scheduling is RSSI-gated; duty-cycled scan windows conserve battery
(see §7).

---

## 4. Link framing (ATT → BinaryProtocol)

Each write/notify carries opaque bytes that are assembled into complete
`BinaryProtocol` frames by a stream assembler (`NotificationStreamAssembler`):

- Accepts leading version byte `1` or `2`.
- Strips leading PKCS#7-style padding runs when present.
- Computes expected frame length from header flags + payload length (+
  recipient / signature / route).
- Hard cap: **8 MiB** (`bleNotificationAssemblerHardCapBytes`).
- Incomplete-frame stall reset: **250 ms**.

Preferred write mode: **Write Without Response**, bounded by
`maximumWriteValueLength` / `maximumUpdateValueLength`. Hard ceiling considered
by the stack: **512** (`bleMaxMTU`).

---

## 5. Fragmentation

When an encoded `BinaryProtocol` blob exceeds the link chunk size, the sender
emits one or more packets of type `fragment` (`0x20`).

### 5.1 Chunk sizing

| Knob | Default |
|------|---------|
| Default chunk | **469** bytes (`bleDefaultFragmentSize`) |
| Minimum chunk | **64** bytes |
| Private-media Android contract | ≤ **256** fragments per transfer |

Link-aware sizing may shrink the chunk using
`max(64, linkLimit − overhead)` when source routes inflate headers.

### 5.2 Fragment payload layout

Minimum 13 bytes, then chunk data:

```
 offset  size  field
 0       8     fragmentID (random)
 8       2     index   (uint16 BE, 0-based)
 10      2     total   (uint16 BE, 1…10000)
 12      1     originalType (MessageType of the inner packet)
 13…           chunk bytes of the original encoded frame
```

Fragment packet fields:

- `type` = `0x20`
- `senderID`, `timestamp`, `ttl`, optional `route` / `isRSR` inherited from the
  original
- `signature` = **nil** on fragments (inner packet carries its own signature
  after reassembly)
- `version` = `1`, or `2` when the original carried a source route
- `recipientID` = directed peer when applicable; broadcast may use nil or
  `FF×8`

### 5.3 Reassembly

| Rule | Value |
|------|-------|
| Assembly key | `(senderID as u64 BE, fragmentID as u64 BE)` |
| Max concurrent assemblies | **128** (evict oldest) |
| Assembly lifetime | **30 s** |
| Size cap (typical) | 1 MiB payload |
| Size cap (`fileTransfer` / `noiseEncrypted`) | `maxFramedFileBytes` |
| Stall → `requestSync` | after **5 s**; retry every **10 s** |
| Inter-fragment spacing (broadcast) | **30 ms** |
| Inter-fragment spacing (directed) | **25 ms** |
| Max concurrent large transfers | **2** |

Validation:

- `total ∈ [1, 10000]`, `index < total`
- First accepted fragment header is authoritative for `(total, originalType,
  broadcast scope)`; conflicting later fragments **MUST** be rejected (not
  stored, not relayed)
- Duplicate index: do not double-count size toward the assembly budget
- Oversize fragments **MUST NOT** destroy an assembly they did not create

On completion, concatenate chunks in index order and run `BinaryProtocol.decode`
on the result; then dispatch as `originalType`.

---

## 6. Default TTL and flood behaviour

| Knob | Default |
|------|---------|
| Origination TTL | **7** (`messageTTLDefault`) |
| Dense-graph broadcast clamp | often **5** when degree ≥ 6 |
| Dedup | LRU seen-set (~1000 entries, ~5 min) keyed by sender/timestamp/type/digest |
| Relay jitter | randomized tens–hundreds of ms (wider when dense) |
| Fanout | deterministic subset (~log₂ degree) for many broadcasts; full fanout for announces/fragments/sync |
| Directed traffic | TTL−1, tight jitter, never subset |

Full routing prose: `WHITEPAPER.md` §4 and `docs/SOURCE_ROUTING.md`.

---

## 7. Presence and duty cycle (informative)

Reference client behaviour (not hard wire requirements, but useful for
interoperability timing):

| Behaviour | Typical value |
|-----------|---------------|
| Isolated announce interval | ~4 s |
| Connected announce | ~15–30 s base + jitter |
| Scan duty on/off (sparse) | 5 s / 10 s |
| Reachability retention (verified) | 60 s since lastSeen |
| Initial announce delay after start | ~0.6 s |

---

## 8. Implementer checklist

- [ ] Advertise and scan **only** the release service UUID in production.
- [ ] Use the shared characteristic UUID with notify + write-without-response.
- [ ] Do not put a local name in advertisements.
- [ ] Reassemble ATT notifications into BinaryProtocol frames before parsing.
- [ ] Fragment at ≤469 B chunks with the 13-byte fragment header.
- [ ] Cap assemblies (128 / 30 s) and reject conflicting fragment metadata.
- [ ] Originate mesh packets with TTL 7 unless a documented exception applies.
