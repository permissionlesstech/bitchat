# Wi-Fi LAN transport (v1)

A phone-to-phone transport that finds other bitchat users on the **same
Wi-Fi network** and exchanges end-to-end encrypted messages with them,
without an internet connection and without any relay.

It sits next to the existing transports, it does not replace them:

| Transport | Role |
| --- | --- |
| BLE mesh | default, unchanged, works without a router |
| **Wi-Fi LAN (new)** | direct link to a peer on the same local network |
| Nostr | unchanged, needs the internet |

A peer keeps **one identity** across transports: the LAN transport reuses
the Noise static key from the keychain, so the peer ID and the fingerprint
shown in the UI are the same as on BLE.

> **Status.** The code, the settings toggle, the peer-list badge and the
> denied/unavailable states are implemented. This feature was written on
> Linux, where no Swift toolchain, no Xcode and no Apple simulator exist, so
> the compile and unit-test result comes from macOS CI
> (`.github/workflows/swift-tests.yml`). A build on a Mac and a run on two
> physical devices are still required — see [Verification](#verification).

---

## 1. Feature flag

The transport is **off by default** and stays completely inert while it is
off: no listener, no browser, no local-network permission prompt, no
sockets. Nothing in the BLE or Nostr path changes.

| Setting | Key | Default |
| --- | --- | --- |
| Feature flag | `bitchat.lan.enabled` (`UserDefaults`) | `false` |

`LANTransportSettings` wraps the flag so it can be exercised in tests against
an isolated `UserDefaults` suite. `LANTransport.startServices()` returns
immediately when the flag is off.

The same flag is exposed in **Settings → connectivity → wi-fi direct**. It is a
runtime switch: enabling starts discovery immediately, disabling cancels the
listener, browser and every link. The first enable starts Bonjour, which is
what makes iOS/macOS show the Local Network prompt.

## 2. Discovery

Discovery is **local only**. There is no cloud broker, no internet relay, no
DNS rendezvous and no account: peers find each other with Bonjour on the
local link.

* Service type: `_bitchat._tcp` (declared in `NSBonjourServices`).
* Advertised name: `bitchat-<peer id>`, e.g. `bitchat-1a2b3c4d5e6f7890`.
  The peer ID is the first 16 hex characters of the SHA-256 fingerprint of
  the Noise static key — the same short ID the BLE mesh uses.
* The browser only accepts names that carry a valid peer ID; any other
  service on the network is ignored.
* Our own advertisement is ignored, and a peer we already have a link to is
  not connected twice.

The transport runs an `NWBrowser` (Bonjour) and an `NWListener` that
advertises the same service type, both over plain TCP on the local network.

## 3. Wire format

The LAN link adds **only a length prefix** to the existing BitChat packet
format. Every frame carries exactly one `BitchatPacket` binary encoding —
the same encoding the BLE mesh uses — so the protocol stays a single
protocol, not two.

```text
+---------------------------+-------------------------------+
| length (4 bytes, BE u32)  | payload (length bytes)        |
+---------------------------+-------------------------------+
```

* The length prefix turns the TCP byte stream into a message boundary.
* `length == 0` is a legal (empty) frame.
* A frame whose declared length exceeds `1 MiB`
  (`LANTransportConfig.maximumFramePayloadBytes`) is rejected and the link
  is dropped: the stream cannot be resynchronised after an oversized frame.
* A frame that is not a decodable `BitchatPacket` is dropped; the link
  stays up.
* Writes are framed and sent in order; a frame may be split across many TCP
  reads and is reassembled by the decoder.

Packet types used on the LAN link:

| Type | Value | Meaning |
| --- | --- | --- |
| `announce` | `0x01` | the signed hello (identity exchange) |
| `message` | `0x02` | public chat message (UTF-8 payload) |
| `noiseHandshake` | `0x10` | Noise XX handshake message |
| `noiseEncrypted` | `0x11` | encrypted payload (private message, receipt, ack) |

### 3.1 The hello (identity exchange)

The side that opened the TCP connection speaks first.

1. The client sends an `announce` packet. Its payload is the existing
   `AnnouncementPacket` TLV (nickname, Noise static public key, Ed25519
   signing public key) and the whole packet is signed with the sender's
   Ed25519 key (`NoiseEncryptionService.signPacket`).
2. The server verifies the signature with the announced signing key and
   checks that the claimed peer ID is derived from the announced Noise key
   (`PeerID(publicKey:) == senderID`). A mismatch or a bad signature is
   dropped and the handshake never starts.
3. The server answers with its own `announce` packet.

The hello is a hint, not an authentication: the Noise handshake below is
what proves possession of the static key.

### 3.2 The Noise handshake over the link

The transport runs the **existing** Noise XX handshake
(`NoiseEncryptionService` / `NoiseSessionManager`) over the TCP link:

1. The client (the side that opened the connection) sends message 1
   (`noiseHandshake`, payload = raw Noise message).
2. The server answers with message 2.
3. The client answers with message 3.
4. Both sides hold an established Noise session for that peer.

The transport uses its **own** `NoiseEncryptionService` instance, created
from the same keychain. Consequences:

* the Noise static key (and therefore the peer ID and the fingerprint) is
  the same as the BLE mesh identity — one identity across transports;
* the session table is per link, so a session established over BLE is never
  silently reused over Wi-Fi (a Noise transport cipher belongs to exactly
  one physical link).

After the handshake, every frame is a `noiseEncrypted` packet whose payload
is a typed noise payload: the first decrypted byte is the
`NoisePayloadType` (`privateMessage`, `readReceipt`, `delivered`, …), the
rest is the payload. The LAN transport emits the existing typed transport
event `.noisePayloadReceived(peerID:type:payload:timestamp:)`, so the
inbound path is the one the app already uses for BLE.

The side that opened the connection always drives the handshake, so the two
peers never cross their initiations.

## 4. Peer state machine

`LANPeerRegistry` is a pure state machine (no clock of its own: every
mutation takes an explicit `now`).

```text
discovered ──► handshaking ──► authenticated
     │               │                │
     └─────► timedOut ◄──────────────┘
                     authenticated ──► disconnected
```

| State | Meaning |
| --- | --- |
| `discovered` | the peer was found, no identity exchange yet |
| `handshaking` | the Noise handshake is running |
| `authenticated` | the Noise session is established, payloads can flow |
| `disconnected` | the link was closed, or an authenticated peer went silent |
| `timedOut` | the peer never completed the handshake |

Timeouts (`LANTransportConfig`): discovery 30 s, handshake 10 s, idle
120 s (refreshed by any received frame). The peer table is bounded at 32
peers.

Rules that the unit tests pin down:

* a repeated discovery **never** downgrades an authenticated peer;
* a peer seen again after a disconnect restarts at `discovered`;
* an authenticated peer that goes silent becomes `disconnected`, a peer that
  never finished the handshake becomes `timedOut`;
* timed-out peers are not published to the peer list.

## 5. Transport selection

`LANTransportSelector` is a pure value type that encodes the policy:

1. **Wi-Fi wins** only for a peer that is directly reachable over the local
   network: the flag is on, the local-network permission is granted and the
   peer's LAN session is authenticated.
2. Otherwise the **existing** behaviour is untouched: BLE first (connected,
   then reachable), Nostr last, nothing when no transport can reach.
3. A denied, unavailable or not-yet-granted permission never blocks
   BLE/Nostr — the LAN transport simply becomes ineligible and the reason is
   reported (`permissionDenied`, `permissionUnavailable`,
   `permissionNotGranted`, `featureDisabled`, `peerNotOnLAN`,
   `peerNotAuthenticated`).

In the app the router receives the transports as
`[lan, ble, nostr]`, so the LAN transport is only consulted first and the
BLE/Nostr order is preserved for every other peer.

## 6. Permissions

| Platform | What is needed |
| --- | --- |
| iOS 14+ | the *Local Network* prompt, triggered by the first Bonjour browse/advertise after the user enables the flag |
| macOS 11+ | the same prompt (the app is sandboxed) |

`Info.plist` (shared by the iOS and macOS targets) contains:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>bitchat uses your local network to find other bitchat users on the same Wi-Fi and exchange end-to-end encrypted messages directly, without an internet connection.</string>
<key>NSBonjourServices</key>
<array>
    <string>_bitchat._tcp</string>
</array>
```

The macOS target already carries `com.apple.security.network.client` and
`com.apple.security.network.server` in `bitchat-macOS.entitlements`.

The permission state is tracked as `unknown` → `granted` / `denied` /
`unavailable`. iOS does not expose an API to query the local-network
permission, so the state is derived from the browser/listener state
(`ready` → granted, a `posix` `EACCES`/`EPERM` failure → denied). The
mapping is a pure function (`LANPermissionStateResolver`) and is unit
tested. `unknown` is allowed to start on purpose: that first Bonjour call is
what triggers the prompt. A known `denied` or `unavailable` state keeps the
transport inert. **A denied permission is not fatal**: BLE/Nostr keep
working and the Settings row shows the denial with an *open settings* and
*try again* action.

## 7. Security limits

* The LAN link is **not** an anonymity network: the IP addresses of the two
  devices are visible to the local network, and the peers learn each
  other's presence. Use BLE or Nostr when that matters.
* The payload is end-to-end encrypted with the existing Noise XX session, so
  a router or another device on the Wi-Fi cannot read the messages. The
  transport does not change the Noise security model.
* The peer ID and the Noise public key are advertised in cleartext in the
  Bonjour service name and in the signed hello — exactly as the BLE mesh
  advertises them. They are linkable identifiers, not secrets.
* The hello is signed and the advertised peer ID is checked against the
  advertised Noise key, so a peer cannot claim another peer's identity.
* A frame that is malformed or oversized drops the link; there is no
  resynchronisation and no partial-frame state.
* Every packet must claim the peer ID that its TCP link authenticated as,
  and every addressed packet must be addressed to us. A peer cannot inject a
  packet under a third party's sender ID on its own link.
* A public (`message`) packet is accepted only after the Noise handshake and
  only after its Ed25519 signature verifies against the signing key from the
  authenticated hello. The LAN path does not trust an unsigned public frame.
* Noise handshake frames are ignored until the signed hello arrived, and a
  completed handshake is accepted only when its remote static key is the one
  announced in that hello (and still derives the claimed peer ID). A service
  that advertises somebody else's Bonjour name cannot hijack their identity.
* A link accepts exactly one hello. A second hello, or a hello whose sender
  differs from the advertised Bonjour name, drops the link. When both peers
  connect at once, a deterministic rule keeps one crossed link (the outbound
  link of the smaller peer ID) so there is no duplicate session.
* Unauthenticated connections are bounded (64 open links) and expire after
  the discovery/handshake timeouts, so a local attacker cannot hold slots.
* The transport has **no** key rotation of its own, no forward secrecy
  beyond what Noise XX provides, and no anti-replay window on the LAN link
  beyond the Noise message counters.
* A panic wipe stops and quarantines the LAN transport before the keychain
  is erased: it owns an in-memory copy of the old Noise identity and may
  hold live local-network links. The transport is not restarted in the same
  session; a fresh app launch creates it under the new identity. A
  follow-up should rebuild the transport in place instead of requiring a
  relaunch.

## 8. Not supported in v1

* No file/media transfer, no live voice bursts, no group messaging, no
  courier/store-and-forward over the LAN link (the payload types exist in
  the protocol, but the transport only wires the text paths).
* No peer capabilities are exchanged, so a LAN peer reports no capabilities
  to the app (private media stays on the BLE path).
* No gossip/history sync over the LAN link.
* No relay of LAN traffic through a third device: the link is a direct
  peer link only.
* No IPv6-only or peer-to-peer (Wi-Fi Direct) special handling: the
  transport uses the interfaces Network.framework offers.
* No peer-count or traffic display specific to the LAN link beyond the wifi
  badge in the peer list and the permission state in Settings.
* No bandwidth limits beyond the 32-peer table and 64-link caps.

## 9. Code map

| File | Content |
| --- | --- |
| `bitchat/Services/LAN/LANFrameCodec.swift` | length-prefixed framing, incremental decoder |
| `bitchat/Services/LAN/LANPeerRegistry.swift` | peer state machine, snapshots |
| `bitchat/Services/LAN/LANTransportSelector.swift` | transport selection policy |
| `bitchat/Services/LAN/LANInboundPolicy.swift` | sender/recipient checks for inbound packets |
| `bitchat/Services/LAN/LANTransportConfig.swift` | feature flag, permission state, constants |
| `bitchat/Services/LAN/LANConnection.swift` | `NWConnection` wrapper with framing |
| `bitchat/Services/LAN/LANTransport.swift` | discovery, hello, handshake, `Transport` conformance |
| `bitchatTests/LANFrameCodecTests.swift` | codec: round trip, malformed, partial write, oversized |
| `bitchatTests/LANPeerRegistryTests.swift` | state machine and timeouts |
| `bitchatTests/LANTransportSelectorTests.swift` | priority and fallbacks |
| `bitchatTests/LANTransportConfigTests.swift` | flag, service names, permission mapping, start gate |
| `bitchatTests/LANInboundPolicyTests.swift` | sender and recipient identity checks |

## 10. Verification

The pure core (`LANFrameCodec`, `LANPeerRegistry`,
`LANTransportSelector`, `LANTransportConfig`, `LANInboundPolicy`) was
compiled with Swift 6.1 on Linux against small `BitFoundation` stubs, and
**43 tests pass**. That harness is not part of this repository and does not
cover UIKit, Network.framework or the app targets.

The macOS CI (`.github/workflows/swift-tests.yml`) is the executable gate for
those parts: `swift build --build-tests`, the unit tests, the iOS simulator
test job, the SwiftLint job and the universal Release builds of both app
targets. It has not reported a result on this change yet.

**Not** executed here, because this workstation is Linux (no Xcode, no Apple
simulator):

* a build of the iOS/macOS app targets;
* SwiftLint;
* a run of the app on a Mac;
* a run on two physical devices on the same Wi-Fi;
* the iOS local-network permission prompt (denied, granted and "ask every
  time" paths).

To verify on a Mac, from a checkout of this pull request:

```bash
# 1. unit tests
swift test --filter LAN

# 2. build both app targets
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (iOS)" \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" \
  -destination 'generic/platform=macOS' build

# 3. run on two physical iPhones on the same Wi-Fi
#    (enable the flag first, e.g. with a defaults write or a debug build):
#      defaults write chat.bitchat bitchat.lan.enabled -bool true
#    Install the app on both phones, accept the Local Network prompt,
#    and check that the peer appears in the peer list and that a private
#    message arrives.
```

The physical-device run is the only way to confirm the Bonjour
advertisement, the permission prompt and the end-to-end handshake on real
hardware; the simulator cannot exercise two devices on one Wi-Fi.
