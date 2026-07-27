# Geohash Publisher Relay Selection & Delivery

Guide for external tools that publish into BitChat location channels (kind
`20000` chat, kind `20001` presence). BitChat clients do **not** use a fixed
global relay set for these channels — they pick relays by proximity to the
geohash cell. A publisher that targets the wrong relays will never reach those
clients.

## Event shape

Location chat messages are ephemeral Nostr events:

| Field | Value |
|-------|--------|
| `kind` | `20000` (chat) or `20001` (presence heartbeat) |
| `tags` | Must include `["g", "<geohash>"]`. Chat may also carry `["n", "<nickname>"]`. |
| `content` | Message text for kind `20000`; empty for kind `20001` |
| `pubkey` | Ephemeral identity derived for that geohash (not the user's long-term key) |

Clients subscribe with filters equivalent to:

```json
{ "kinds": [20000, 20001], "#g": ["<geohash>"], "limit": 200 }
```

See [GeohashPresenceSpec.md](GeohashPresenceSpec.md) for presence broadcast
rules (precision limits, heartbeat cadence).

## How clients choose relays

On subscribe and publish, BitChat asks `GeoRelayDirectory` for the closest
relays to the geohash center:

1. Decode the geohash to a lat/lon center.
2. Rank the bundled geo-relay directory by haversine distance.
3. Take the nearest **5** relays (`TransportConfig.nostrGeoRelayCount`).
4. Ties break by hostname so every device with the same directory picks the
   same set — publishers and subscribers must agree.

With an empty or unreachable directory for that cell, the client refuses to
publish rather than falling back to unrelated default relays.

**Implication for external publishers:** replicate the same proximity selection
(or publish to a strict superset that includes those five hosts). Publishing
only to a personal fixed relay list is the most common reason a message never
appears in the app.

## Sparse and ocean cells

Some geohashes (oceans, deserts, polar regions) map to few or unreachable
nearby relays. The channel UI still opens normally — there is no separate
"undeliverable" banner — but live messages may not round-trip. Treat an empty
timeline in those cells as a relay-coverage problem, not a client bug.

## Ephemerality and late joiners

Kind `20000` / `20001` events are ephemeral. Relays typically do not store them
for historical replay. A client that subscribes minutes later cannot retrieve
messages that already left the relay's ephemeral buffer. Initial lookback on
subscribe is on the order of one hour for chat sampling
(`nostrGeohashInitialLookbackSeconds`), but that only recovers what the chosen
relays still hold.

For durable geographic notes, BitChat uses persistent kind `1` events tagged
with `g` (location notes / drops) — a different surface from live channel chat.

## Practical checklist for external publishers

1. Compute the target geohash at the precision the channel uses (`block` ≈ 7,
   `neighborhood` ≈ 6, `city` ≈ 5, etc.).
2. Resolve the closest ~5 `wss://` hosts from the same geo-relay directory the
   app ships (or an equivalent proximity ranking over that list).
3. Publish the signed kind-`20000` event to those relays with a correct `g` tag.
4. Expect no backlog for late subscribers; design tools around live delivery.
5. Do not assume App Store / mesh Bluetooth peers will see Nostr-only publishes
   — mesh and geohash are separate transports.

## Related code

- `bitchat/Nostr/GeoRelayDirectory.swift` — proximity ranking
- `bitchat/Services/GeohashPresenceService.swift` — subscribe/publish wiring
- `bitchat/Services/TransportConfig.swift` — `nostrGeoRelayCount`, lookback limits
- `bitchat/Nostr/NostrProtocol.swift` — kind `20000` / `20001` builders
