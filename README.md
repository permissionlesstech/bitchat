<img width="256" height="256" alt="icon_128x128@2x" src="https://github.com/user-attachments/assets/90133f83-b4f6-41c6-aab9-25d0859d2a47" />

## bitchat

A decentralized peer-to-peer messaging app with dual transport architecture: local Bluetooth mesh networks for offline communication and internet-based Nostr protocol for global reach. No accounts, no phone numbers, no central servers. It's the side-groupchat.

[bitchat.free](http://bitchat.free)

📲 [App Store](https://apps.apple.com/us/app/bitchat-mesh/id6748219622)

## License

This project is released into the public domain. See the [LICENSE](LICENSE) file for details.

## Features

- **Dual Transport Architecture**: Bluetooth mesh for offline + Nostr protocol for internet-based messaging
- **Location-Based Channels**: Geographic chat rooms using geohash coordinates over global Nostr relays
- **Intelligent Message Routing**: Automatically chooses best transport (Bluetooth → Nostr fallback)
- **Decentralized Mesh Network**: Automatic peer discovery and multi-hop message relay over Bluetooth LE
- **Privacy First**: No accounts, no phone numbers, no persistent identifiers
- **Private Message End-to-End Encryption**: [Noise Protocol](https://noiseprotocol.org) for mesh, BitChat private envelopes for Nostr fallback
- **IRC-Style Commands**: Familiar `/slap`, `/msg`, `/who` style interface
- **Universal App**: Native support for iOS and macOS
- **Emergency Wipe**: Triple-tap to instantly clear all data
- **Performance Optimizations**: LZ4 message compression, adaptive battery modes, and optimized networking

## [Technical Architecture](https://deepwiki.com/permissionlesstech/bitchat)

BitChat uses a **hybrid messaging architecture** with two complementary transport layers:

### Bluetooth Mesh Network (Offline)

- **Local Communication**: Direct peer-to-peer within Bluetooth range
- **Multi-hop Relay**: Messages route through nearby devices (max 7 hops)
- **No Internet Required**: Works completely offline in disaster scenarios
- **Noise Protocol Encryption**: End-to-end encryption with forward secrecy
- **Binary Protocol**: Compact packet format optimized for Bluetooth LE constraints
- **Automatic Discovery**: Peer discovery and connection management
- **Adaptive Power**: Battery-optimized duty cycling

### Nostr Protocol (Internet)

- **Global Reach**: Connect with users worldwide via internet relays
- **Location Channels**: Geographic chat rooms using geohash coordinates
- **290+ Relay Network**: Distributed across the globe for reliability
- **BitChat Private Envelopes**: App-specific encrypted private messages over Nostr relays
- **Ephemeral Keys**: Fresh cryptographic identity per geohash area

BitChat's private-envelope format is proprietary and is **not** NIP-17,
NIP-44, or NIP-59 compatible. It uses Nostr as a relay transport but only
interoperates with BitChat clients. New envelopes use provisional,
BitChat-specific public kind 1402 (not a formally reserved Nostr kind),
encrypted inner kinds 1403/1404, and the `bitchat-pm-v1:` content prefix.
For mixed-version delivery, clients publish both the primary kind-1402
envelope and a compatibility kind-1059 copy. There is no date-based cutoff:
kind 1059 must remain enabled until a coordinated iOS/Android release confirms
that supported older clients have migrated. Receivers subscribe to both kinds
and deduplicate the authenticated embedded BitChat payload.

Private-envelope migration compatibility:

| Sender | Receiver | Delivery path |
| --- | --- | --- |
| New iOS | New iOS | Kind 1402 is primary; the kind-1059 twin is deduplicated |
| New iOS | Released iOS | Compatibility kind 1059 |
| New iOS | Current Android | Compatibility kind 1059 |
| Released iOS | New iOS | Kind 1059 with the released empty inner-tag shape |
| Current Android | New iOS | Kind 1059 with exactly the authenticated recipient `p` tag |

New kind-1402 envelopes require an empty inner tag list. The Android recipient
tag exception is intentionally confined to legacy kind 1059 and accepts only
the exact addressed recipient. Mailbox subscriptions cover the 24-hour
delivery window plus Android's full 48-hour timestamp randomization and 15
minutes of clock skew. Recovery uses
one independent 500-event relay filter per wire kind so either format cannot
consume the other's result budget.

The two outbound migration copies are admitted to the relay queue as one
protected batch. Queue pressure evicts ephemeral traffic first, never one copy
of a private pair; if protected capacity is exhausted, the entire new pair is
rejected as a whole. User-message rejection becomes a visible failed delivery;
acknowledgements and favorite notifications retain the exact pair in a
process-wide 256-entry bounded retry queue. A sustained outage beyond that
bound evicts the oldest whole control pair with an explicit warning, never half
a pair.
If either socket write fails, the same queued pair remains pending and both
copies are replayed on the replacement connection. A terminal relay target is
pruned after bounded retries so one dead relay cannot wedge healthy delivery.

### Channel Types

#### `mesh #bluetooth`

- **Transport**: Bluetooth Low Energy mesh network
- **Scope**: Local devices within multi-hop range
- **Internet**: Not required
- **Use Case**: Offline communication, protests, disasters, remote areas

#### Location Channels (`block #dr5rsj7`, `neighborhood #dr5rs`, `country #dr`)

- **Transport**: Nostr protocol over internet
- **Scope**: Geographic areas defined by geohash precision
  - `block` (7 chars): City block level
  - `neighborhood` (6 chars): District/neighborhood
  - `city` (5 chars): City level
  - `province` (4 chars): State/province
  - `region` (2 chars): Country/large region
- **Internet**: Required (connects to Nostr relays)
- **Use Case**: Location-based community chat, local events, regional discussions

### Direct Message Routing

Private messages use **intelligent transport selection**:

1. **Bluetooth First** (preferred when available)

   - Direct connection with established Noise session
   - Fastest and most private option

2. **Nostr Fallback** (when Bluetooth unavailable)

   - Uses recipient's Nostr public key
   - BitChat's app-specific private-envelope encryption
   - Routes through global relay network

3. **Smart Queuing** (when neither available)
   - Messages queued until transport becomes available
   - Automatic delivery when connection established

For detailed protocol documentation, see the [Technical Whitepaper](WHITEPAPER.md).

## Setup

### Option 1: Using Xcode

   ```bash
   cd bitchat
   open bitchat.xcodeproj
   ```

   To run on a device there're a few steps to prepare the code:
   - Clone the local configs: `cp Configs/Local.xcconfig.example Configs/Local.xcconfig`
   - Add your Developer Team ID into the newly created `Configs/Local.xcconfig`
      - Bundle ID would be set to `chat.bitchat.<team_id>` (unless you set to something else)
   - Entitlements need to be updated manually (TODO: Automate):
      - Search and replace `group.chat.bitchat` with `group.<your_bundle_id>` (e.g. `group.chat.bitchat.ABC123`)

### Option 2: Using `just`

   ```bash
   brew install just
   ```

Want to try this on macos: `just run` will set it up and run from source.
Run `just clean` afterwards to restore things to original state for mobile app building and development.

## Localization

- Base app resources live under `bitchat/Localization/Base.lproj/`. Add new copy to `Localizable.strings` and plural rules to `Localizable.stringsdict`.
- Share extension strings are separate in `bitchatShareExtension/Localization/Base.lproj/Localizable.strings`.
- Prefer keys that describe intent (`app_info.features.offline.title`) and reuse existing ones where possible.
- Run `xcodebuild -project bitchat.xcodeproj -scheme "bitchat (macOS)" -configuration Debug CODE_SIGNING_ALLOWED=NO build` to compile-check any localization updates.
