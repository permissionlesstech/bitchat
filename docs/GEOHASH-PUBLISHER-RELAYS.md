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
| `pubkey` | Ephemeral identity derived for that geohash (not the person's long-term key) |

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
2. Rank the geo-relay directory by haversine distance.
3. Take the nearest **5** relays (`TransportConfig.nostrGeoRelayCount`).
4. Ties break by hostname so every device with the same directory picks the
   same set — publishers and subscribers must agree.

### Directory source of truth

Do **not** rely only on the CSV bundled inside an older app build. At runtime
the client refreshes and caches the reviewed copy on `main`:

https://raw.githubusercontent.com/permissionlesstech/bitchat/refs/heads/main/relays/online_relays_gps.csv

That URL is `GeoRelayDirectory`'s `remoteURL`. External publishers should rank
against this same file (or a freshly synced cache of it). A snapshot shipped
with an old binary can diverge after relay GPS rows change, so messages land
on hosts current clients no longer subscribe to.

### Empty-directory fallback

`closestRelays` returns `[]` only when the in-memory directory has no entries
(or `count <= 0`). In that case the publish path does **not** refuse — it
falls back to `NostrRelayManager`'s default relay list (built-in + any custom
relays). See `ChatPublicConversationCoordinator.sendPublicRaw`: empty
`targetRelays` → `sendEvent(event)` with no explicit `to:`.

Publishers should still prefer proximity selection against the live CSV.
Default-relay fallback is a last resort when the geo directory failed to load;
relying on it intentionally will miss clients that *did* load the directory
and are subscribed only to the nearest five.

## Sparse cells (stale directory rows)

A "sparse" cell is about **directory freshness**, not geographic remoteness.
Haversine ranking always returns the nearest five hosts from whatever GPS rows
the CSV currently has — including for oceans or deserts. When those rows are
stale or thin for a region (relay moved, GPS never updated, host offline), the
selected five can be the wrong place for live traffic even though they look
"close" on paper.

The channel UI still opens normally — there is no separate "undeliverable"
banner — but live messages may not round-trip. Treat an empty timeline in those
cells as a stale/coverage problem in the relay directory, not a client bug.
Refreshing from the canonical CSV above is the first fix to try.

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
2. Fetch the **current**
   [`online_relays_gps.csv`](https://raw.githubusercontent.com/permissionlesstech/bitchat/refs/heads/main/relays/online_relays_gps.csv)
   (same URL the app refreshes from). Rank by haversine to the geohash center
   and take the nearest ~5 `wss://` hosts (hostname tie-break). Optionally
   publish to a strict **superset** that covers both that selection and any
   older bundled snapshot you still support.
3. Publish the signed kind-`20000` event to those relays with a correct `g` tag.
4. Expect no backlog for late subscribers; design tools around live delivery.
5. Do not assume App Store / mesh Bluetooth peers will see Nostr-only publishes
   — mesh and geohash are separate transports.

## Related code

- `bitchat/Nostr/GeoRelayDirectory.swift` — proximity ranking, `remoteURL`, cache
- `bitchat/ViewModels/ChatPublicConversationCoordinator.swift` — empty-selection
  fallback to default relays
- `bitchat/Services/GeohashPresenceService.swift` — subscribe/publish wiring
- `bitchat/Services/TransportConfig.swift` — `nostrGeoRelayCount`, lookback limits
- `bitchat/Nostr/NostrProtocol.swift` — kind `20000` / `20001` builders
- `relays/online_relays_gps.csv` — reviewed directory checked into this repo
