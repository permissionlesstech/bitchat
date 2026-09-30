# Geohash relay selection and delivery (external publishers)

This note answers [#1473](https://github.com/permissionlesstech/bitchat/issues/1473) for tools that publish **kind 20000** geohash chat events to Nostr relays outside the iOS app.

## How BitChat picks relays for a cell

When a user opens a geohash channel, the client subscribes to a **small set of relays near that geohash**, not the user’s global relay list. Selection uses the bundled relay directory (`GeoRelayDirectory`) and haversine distance from the cell center; the nearest relays (typically five) are used for that channel.

Implications for external publishers:

1. **Fixed relay lists miss clients.** If you publish only to `wss://your-relay.example`, BitChat users in that geohash may never subscribe there unless your relay is among the nearest entries for their cell. To reach a cell, replicate the client’s geo selection: choose relays from the same directory ranked by distance to the target geohash.

2. **Sparse and ocean cells are weakly served.** Remote or low-density areas may map to few or unreachable relays in the directory. The app still shows the channel UI; delivery can be poor with **no in-app “undeliverable cell” signal**. Test publishes in the target geohash with a BitChat client on the same cell before assuming reach.

3. **Kind 20000 is ephemeral.** Relays and clients treat these events as short-lived. A user who opens the channel **minutes after** your publish will not backfill recent messages. External tools should not assume store-and-forward semantics like long-lived Nostr notes.

## Related reading

- In-app custom relay configuration (#1486) changes **where the user connects**, not which relays every geohash channel uses by default.
- A fuller protocol spec is tracked in [#1448](https://github.com/permissionlesstech/bitchat/issues/1448); this document is a narrow publisher-facing summary until that spec lands.
