# Service UUID Detectability

**Status:** Analysis for cross-platform review. **No implementation is proposed.** This documents why the obvious fix — rotating or deriving the service UUID — does not work, so the idea stops being re-raised without its constraints, and records what is achievable instead.
**Audience:** bitchat iOS and Android maintainers.

`docs/PEER-ID-ROTATION.md` §2 lists this as an explicit non-goal: *"Hiding **that** bitchat is in use. The service UUID is a separate problem; BLE requires something discoverable. Tracked separately."* This is that tracking document.

**The conclusion, up front:** hiding that bitchat is running is **not achievable** for an open-source app that supports discovery between strangers. That is a consequence of the threat model, not a gap in the implementation. `docs/privacy-assessment.md:34` already says so; this document explains why, so the honesty there is preserved rather than softened by a scheme that looks like a fix.

---

## 1. What is exposed today

`BLEService.swift:187-191` defines three compile-time constants:

| Constant | Value | Exposure |
|---|---|---|
| `serviceUUID` (mainnet) | `F47B5E2D-…-4B5C` | Advertised; a globally unique constant in the clear |
| `serviceUUID` (testnet, `#if DEBUG`) | `F47B5E2D-…-4B5A` | as above |
| `characteristicUUID` | `A1B2C3D4-…-4C5D` | Reachable by anything that connects and walks the GATT table |

`BLERadioController.advertisementData()` advertises the service UUID and deliberately no local name. In the **foreground** that 128-bit constant goes out in the clear, occupying 18 of the 31 advertising bytes — the strongest possible app fingerprint. Scanning filters on the same constant (`BLERadioController.swift:83`, `BLEService.swift:960`).

Note there are **two** fixed identifiers, not one. Even if the advertised UUID changed, `BLEService+LinkLayerPeripheralRole.swift:38-46` builds one primary service containing one characteristic, both constants, so an active prober that connects still identifies bitchat.

---

## 2. Why rotating the service UUID does not work

Two reasons. The first is sufficient on its own; the second constrains whatever survives it.

### 2.1 The threat model forecloses it

Rotation only helps if an adversary cannot compute the current value. But:

- iOS **requires** background scanners to name the exact service UUIDs they want (§3.1). A UUID that a stranger's phone cannot pre-compute is a UUID it cannot scan for.
- So any value a **stranger** can derive in order to find us, an adversary running the same open-source binary derives identically.

Stranger discovery (`PEER-ID-ROTATION.md` goal **G4**) and invisibility-to-a-code-reading-adversary are therefore mutually exclusive in the same advertisement. Rotation from a *public* input defeats a scanner using a stale hardcoded list; it does not defeat a censor who runs our algorithm.

Covert rendezvous with an adversary who knows the algorithm requires a **pre-shared secret**. That is the consistent finding of the literature — secret handshakes (Balfanz et al.), matchmaking encryption (PriSrv), Bluetooth 5.4 Encrypted Advertising Data, and the covert-communication square-root law all assume one. Public-key steganography is the near-miss that lets parties who never met communicate covertly, but the sender must know the *recipient's* key; for an open-source app that reduces to a key in the binary, which the adversary extracts.

The closest real-world analogue is Tor's twenty-year bridge-distribution problem — let unknown strangers find a resource without letting the censor find it. Every mitigation that works (Salmon, Lox, rBridge) gates on social trust and thereby gives up open stranger access. There is no known escape from that trade.

### 2.2 iOS constrains it mechanically

- **Third-party iOS apps cannot control advertisement contents.** Only `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey` are supported; other keys error. Manufacturer data and service data — where every comparable system puts its rotating payload — are unavailable to us. MASHaBLE, the one BLE secret-handshake prototype, could not be built on iOS for exactly this reason and fell back to Windows Phone.
- **Advertised services cannot be changed while backgrounded (iOS 14+).** A wall-clock rotation cannot advance while the app is in the background — which is the state during the scenario this feature exists for. *Undocumented by Apple; needs device verification (§6).*
- **Backgrounded, the UUID is not transmitted at all.** iOS re-encodes it as Apple manufacturer data (`0x004C`) plus a 128-bit bitmask, one bit per advertised UUID. This is worth understanding precisely, because it cuts both ways: background exposure is already only ~7 bits with genuine collisions against every other backgrounded Apple advertiser — but the mapping is stable and empirically discoverable with a free Android app, so an adversary installs bitchat once, notes the bit, and matches passively forever.

The practical consequence: **the real identification exposure is foreground advertising**, where the raw constant is on the air. iOS does permit rotation there — a foreground app can stop advertising, swap the service, and start again under a new UUID, the same stop / remove / add / start cycle `BLEService+LinkLayerPeripheralRole.swift` already runs at runtime — so the mechanics alone do not foreclose it. What they foreclose is rotation in the **background**, where the app spends most of its life in the scenario this feature exists for, and any scheme that puts the rotating value in manufacturer or service data. Foreground rotation would defeat a scanner holding a stale UUID list; it would not defeat an adversary running the public derivation (§2.1), and GATT connect-and-probe (§4) identifies us regardless of what is advertised.

---

## 3. What comparable deployments chose

Every large deployment faced this and made the same call: **fix the identifier, rotate the payload.**

| System | Identifier | Rotates? |
|---|---|---|
| Exposure Notification | service UUID **`0xFD6F`** | Fixed; 16-byte Rolling Proximity Identifier rotates ~15 min |
| Apple Find My / Offline Finding | mfr data, OF type **`0x12`** | Type byte fixed; only the key rotates |
| Google Fast Pair | service UUID **`0xFE2C`** | Fixed; salted account-key filter rotates |
| Eddystone-EID | service UUID **`0xFEAA`** | Fixed; EID in service data rotates |

Exposure Notification is the most instructive. Its byte budget left no room for a 128-bit UUID alongside a 16-byte identifier — flags (3) + 16-bit UUID section (4) + service data (24) is exactly the 31-byte legacy maximum — and iOS↔Android background interop requires a registered service UUID regardless. Hiding participation was never a goal, and detecting EN users promptly became a shipped consumer app. France's use of a *different* UUID (`0xFD64`) meant the identifier revealed which country's app you ran.

The transferable lesson is **not** "rotate the UUID." It is that the EN spec mandates the payload *"shall not include other data types"*, so every EN advertiser is byte-identical in structure. They gave up hiding participation and hardened against distinguishing *which app, version, or user*. That is the achievable goal.

Fast Pair's salted account-key filter is the best deployed example of private group rendezvous — only holders of the account key recognise it — and it lives **inside** a fixed, public service UUID. Same shape: hide *who*, not *what*.

### 3.1 The mesh apps, from their shipped source

Not one of the comparable mesh messengers rotates or derives its identifier from a shared secret:

| | Identifier | Also broadcast |
|---|---|---|
| Bridgefy | service UUID = `SHA-256(app API key)[0:16]` — derived, but from a per-app licensing constant | full user ID in service data |
| Berty | `0x4240` alias, hardcoded | last 4 chars of the libp2p PeerID in service data |
| qaul | hardcoded (currently *different* UUIDs on Android vs iOS/Rust) | mfr data, company `0xFFFF`, 5 bytes of node ID |
| Meshtastic | `6ba1b218-…` hardcoded | device name pattern `Meshtastic_ab3c` (MAC-derived) |
| Briar | **no BLE at all** — Bluetooth Classic RFCOMM/SDP | — |

Bridgefy is the instructive near-miss: its UUID *is* cryptographically derived, but from a value that never changes, so every user of a given app advertises the identical UUID forever — derivation without rotation buys nothing.

Two observations that matter for us:

- **bitchat's advertisement is already cleaner than all of them.** Every app above leaks a stable **per-user** identifier alongside the app identifier — so BLE MAC randomization buys them nothing at all. bitchat advertises the service UUID and deliberately nothing else: no local name, no service data, no manufacturer data. Our advertisement says "a bitchat device is here", not "this person is here". The per-user leak in bitchat lives one layer up, in the announce payload (stable peer ID, cleartext static keys, nickname, neighbour list) — which is precisely what `PEER-ID-ROTATION.md` addresses, and another reason §7.1 is where the effort belongs.
- **Briar is the only structurally different answer**, and it is not a UUID trick: it does not broadcast. It uses Bluetooth Classic and dials a contact's known MAC directly, requesting discoverability only during in-person QR pairing — where it *does* derive a per-session rendezvous UUID from the key commitment. That is contact-scoped rendezvous with an in-person secret (our §7.4), achieved by giving up broadcast discovery entirely.

---

## 4. What still identifies bitchat after any UUID change

Rotation would leave all of these intact:

Ordered by how cheaply an adversary can actually use them — which is not the order they are usually discussed in.

- **GATT connect-and-probe — the one to worry about, and the reason rotation cannot succeed.** Cheap, active, decisive, and completely unaffected by anything done to the advertisement. Any central connects and enumerates our one primary service containing one read/write/notify characteristic (§1).

  The distinction that matters, because the literature is easy to misread here: the well-known GATT-fingerprinting results are about telling *devices apart* — and by that measure the attack is weak against phones (only 4.28% of randomizing addresses uniquely identified; 85.49% of iPhones sit in anonymity sets of ≥100). But **"does this phone run bitchat" is a lookup, not a discrimination problem.** A custom 128-bit service UUID paired with a custom characteristic UUID is a categorical exact match. The measured cost of collecting a profile was ~**3.7 seconds** per device on a **Raspberry Pi 3 with four USB dongles** — squarely a cheap dragnet.

  This is what forecloses rotation as a fix rather than merely complicating it. A prober reads whatever the values *currently* are, so rotating them changes nothing for an attacker who connects; and the **structure** — exactly one custom primary service, exactly one custom read/write/notify characteristic — is invariant under any rotation scheme. Worse, `characteristicUUID` is a *separate* constant today, so rotating only the service UUID would leave it as a static relink handle: the textbook out-of-sync-identifier failure that has repeatedly re-linked devices across MAC rotations in deployed Apple protocols. Gating characteristic *values* behind authentication (the mitigation that paper recommends) reduces what is served but does **not** hide the UUIDs or the shape from an enumerator.
- **Automated, at-scale UUID mining.** The precedent that matters: a 2019 field study fingerprinted **5,509 of 5,822 real BLE devices (94.6%)** across ~1.3 square miles, using a UUID→app mapping built *automatically* by mining app stores. For a closed-source app that mapping takes reverse engineering; for us it is a grep of the repository. This is the detector that rotation would actually defeat — and the one that got Bridgefy's users tracked.
- **Traffic metadata.** Packet sizes and inter-packet timing alone identify devices from *encrypted* BLE traffic at ~0.97 F1. The same work tested padding, delaying, and dummy traffic as defences and found they "do not provide sufficient protection … and introduce significant costs" — worth knowing before cover traffic is proposed elsewhere as a fix.
- **Behavioural timing.** Our scan duty cycle is a published constant (`TransportConfig.swift`: 5 s on / 10 s off, tightening when dense). Scanning is not transmitted, but the connect cadence it produces is observable, and that rhythm is distinctive. On iOS the *advertising* interval is not ours to choose, which is good camouflage — it makes us look like every other iOS app. On Android `AdvertiseSettings` mode **is** app-chosen, so a non-default choice is a cross-platform tell worth a few bits.
- **Mesh structure itself.** Multiple nearby devices exchanging correlated bursts with propagation delays is a signature no single-device fingerprint has, and no identifier change touches it. It is exactly what the Bridgefy social-graph and topology attacks exploited, and exactly what a published ML pipeline — built on Bridgefy traffic and framed as assisting law enforcement — set out to classify.
- **Physical-layer RF fingerprinting — real, but a targeted tool, not a dragnet.** I stated this too strongly in an earlier draft and am correcting it. The IEEE S&P 2022 field study found only **~40–47% of devices uniquely identifiable**, needed ~50 clean packets to enrol, used a USRP N210 rather than a cheap dongle, and degraded badly with temperature (at ΔT ≈ 25 °C carrier-frequency offset "becomes useless for identification"); same-vendor confusion was ~3× the median false-positive rate, which matters in an Apple-heavy crowd. Later work (INFOCOM 2024's transient fingerprints, and 2026 work aimed explicitly at aggressively-rotating trackers) attacks the temperature caveat and reports much stronger results, so the trend is unfavourable — but it still requires per-device SDR capture. Treat it as "can this adversary target a person they have already gotten close to", not "can they enumerate everyone in the square".

---

## 5. Two ways a rotation scheme would make things worse

This is the part that matters most, because each is counter-intuitive.

1. **A derived UUID shrinks the anonymity set.** A global constant hides an individual inside the entire bitchat population. A per-group or per-user derived UUID is a *stronger* selector for a targeted adversary — it identifies not "a bitchat user" but "a member of this cell." Against blanket blocking that is a gain; against targeted work it is a gift.
2. **State restoration becomes a stale-identifier trap.** If iOS terminates the app while scanning, the system continues scanning for the **old** UUID indefinitely and relaunches the app *into the background*, where §2.2 says the advertisement cannot be updated. A restored device could sit advertising a dead epoch's UUID — undiscoverable by current peers *and* wearing a distinctive stale identifier. Strictly worse than the fixed UUID for that device.

---

## 6. What needs device verification before anyone relies on this

Two load-bearing claims are undocumented by Apple and were established from reverse-engineering and engineer forum statements:

- **Can a backgrounded app change its advertised services?** (§2.2). Everything in §5.2 follows from "no". Test: advertise UUID A, background, attempt a switch to B, observe from a second device.
- **Is there a hard cap on the scan-filter array?** Undocumented. Note the structural ceiling regardless: background advertising collapses to 128 bit positions, so at most 128 mutually distinguishable UUIDs exist, and each extra UUID scanned costs roughly 1/128 of *all* backgrounded Apple advertisers as false wakeups. A ±1 epoch skew window is defensible; a wide window degenerates into a near-wildcard scan.

Unresolved and not guessed at here: whether the overflow payload rides in the primary ADV PDU or the scan response, and the exact GATT cache lifetime for unbonded peers.

---

## 7. What is actually available

Ranked by value per unit of risk, given everything above.

1. **Fix linkability, not detectability.** The far larger exposure is that today a stable 8-byte peer ID, cleartext static keys, a nickname, and a neighbour list identify a **specific person**, not merely "a bitchat user." `docs/PEER-ID-ROTATION.md` targets exactly that and is achievable. Invisibility is not. If effort is going anywhere, it should go there.
2. **If anything is done to the advertisement, it must be *blending in*, not *removing*.** Adopting a widely-shared service UUID in place of a globally unique constant trades a perfect app fingerprint for genuine cover from unrelated devices. But note the trap in the obvious version of this idea: **an advertisement with no local name, no manufacturer data, and no service UUID is itself a distinctive negative signature.** Ordinary crowd BLE is dominated by Apple Continuity (`0x004C`) and Microsoft (`0x0006`) manufacturer data; stripping our identifier does not put us in the crowd, it puts us in a small, odd bucket. Any such change must also carry the §4 GATT problem, which it cannot solve, and it invites the well-supported "unobservability by imitation is fundamentally flawed" critique. A maintainer decision with real downside, not an obvious win.
3. **Uniformity, per the Exposure Notification lesson.** Make every bitchat advertisement byte-identical in structure and timing so implementations, versions, and users do not distinguish themselves from each other. This is achievable unilaterally and has no discovery cost.
4. **Contact-scoped covert rendezvous is genuinely possible** — a UUID derived from a shared secret, for peers who have already exchanged one. Group keys with epochs already exist (`Services/Groups/GroupStore.swift`). But it cannot coexist with stranger discovery in the same advertisement, it inherits the §5.1 anonymity-set problem, and §2.2 constrains when it can rotate at all. If it is ever built it should be an explicit, opt-in mode whose costs are stated plainly, not the default.

**What to tell users:** bitchat does not hide that it is running, and no known technique would let it while strangers can still find each other. `docs/privacy-assessment.md` already states this correctly. That honesty is the right posture and should be preserved.
