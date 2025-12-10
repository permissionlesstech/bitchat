# BitLink

Decentralized P2P messenger with dual transport: Bluetooth mesh for offline and Nostr for internet. No accounts, no phone numbers, no servers.

## What is this

BitLink creates a mesh network from nearby devices via Bluetooth. Messages hop between devices (up to 7 hops), so you can communicate even if you're not directly nearby. When internet is available — connects to global Nostr network.

## Features

- **Bluetooth mesh** — works offline, messages relay through chain of devices
- **Nostr** — geographic channels by geohash (block, neighborhood, city, country)
- **Encryption** — Noise Protocol for Bluetooth, NIP-17 for Nostr
- **Privacy** — no accounts, no identifiers
- **Remote Terminal** — control Mac from iPhone via Bluetooth (QR pairing, 6 security layers)

## Architecture

```
┌─────────────────────────────────────────┐
│             BitLink App                 │
├─────────────────────────────────────────┤
│           ChatViewModel                 │
│        (coordinates all)                │
├──────────┬──────────┬───────────────────┤
│ BLEService│MessageRtr│  NostrTransport  │
│(Bluetooth)│(routing) │   (internet)     │
├──────────┴──────────┴───────────────────┤
│         NoiseEncryption                 │
│         (E2E crypto)                    │
└─────────────────────────────────────────┘
```

### Bluetooth layer

- `BLEService` — peer discovery, packet send/receive
- `BitchatPacket` — binary protocol (13 byte header + payload)
- `NoiseSessionManager` — encryption sessions per peer
- Bloom filter for deduplication, TTL for hop control

### Nostr layer

- `NostrTransport` — connects to 290+ relays
- Geohash channels (precision 2-7 for different scales)
- NIP-17 gift-wrapped messages
- Optional Tor

### Remote Terminal (iOS → Mac)

Run commands on Mac from iPhone via Bluetooth:

1. **Pairing** — scan QR code on Mac
2. **Authorization** — 3 command levels (safe/approval/blocked)
3. **Execution** — command runs on Mac, output returns
4. **Security** — Noise Protocol + Keychain + rate limiting + audit log

## Build

```bash
# Xcode
open bitchat.xcodeproj

# or via just
brew install just
just run
```

For device:
1. `cp Configs/Local.xcconfig.example Configs/Local.xcconfig`
2. Add your DEVELOPMENT_TEAM to Local.xcconfig
3. Replace `group.chat.bitchat` with your bundle id in entitlements

## License

Public domain. See [LICENSE](LICENSE).
