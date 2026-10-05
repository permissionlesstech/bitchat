# Publishing to geohash channels

External publishers of BitChat public geohash messages must send signed Nostr
kind 20000 events to the relays selected for the exact channel. A successful
relay acknowledgement does not prove that a BitChat client received or displayed
the event. These messages are ephemeral and are not a durable mailbox.

This guide describes the current iOS and macOS implementation. Android relay
selection may differ; do not assume identical delivery across clients until
both implementations select the same relay set.

## Choose the channel and relay set

Use the exact lowercase geohash displayed by the target channel. A shorter
prefix is a different channel: a subscription to `s000` does not match `s0000`.
Examples in this guide use synthetic channel identifiers, not device locations.

1. Obtain the reviewed directory at `relays/online_relays_gps.csv` in this
   repository, rather than a fixed set of generic relays or an unreviewed
   upstream directory. Runtime clients prefer a validated cache, then bundled
   data, and periodically refresh from the reviewed main-branch copy. Different
   snapshots can select different endpoints.
2. Validate the entire CSV before replacing a working copy. It has three
   columns, `Relay URL,Latitude,Longitude` (also accepting `Lat,Lon`). Identical
   normalized endpoints with identical coordinates collapse to one entry;
   conflicting coordinates or any malformed row reject the entire directory.
   Addresses normalize to lowercase public DNS names, with the default port
   443 omitted. Only secure endpoints without credentials, paths other than
   `/`, queries, or fragments are accepted. See
   [the validator](../bitchat/Nostr/GeoRelayDirectory.swift) and
   [the directory validation tool](../scripts/validate_georelays.py).
3. Decode the geohash to its bounding-box center. Calculate the great-circle
   Haversine distance from that center to every directory entry, using Earth
   radius 6371 km. Sort by `(distance, normalized endpoint)`; the endpoint
   breaks ties deterministically.
4. Select the first five unique endpoints, or all available entries when fewer
   than five exist, and connect using `wss://`. There is no maximum-distance
   cutoff: sparse or ocean cells still select the nearest available entries,
   even when those entries are far away.

The executable selection is `GeoRelayDirectory.closestRelays`, and the channel
count is `TransportConfig.nostrGeoRelayCount`. Distance ranks candidates; it
neither probes reachability nor guarantees delivery. If the directory is empty,
selection returns no relays. Channel existence in the UI does not establish
that any selected relay is reachable or accepts a publisher's events.

## Construct and sign the event

Create a normal signed Nostr event with these fields:

| Field | Value |
| --- | --- |
| `kind` | `20000` |
| `created_at` | Current Unix time in seconds |
| `pubkey` | Publisher's 32-byte secp256k1 public key, hex encoded |
| `tags` | Required `g` tag for the exact geohash; optional `n` nickname |
| `content` | Plaintext message text |
| `id`, `sig` | Standard Nostr event ID and BIP-340 signature |

For a synthetic channel, tags could be `[["g", "s000"], ["n", "synthetic publisher"]]`.
Do not insert an encrypted DM envelope or a BLE packet into `content`.
Geohash public chat is plaintext to relay operators and other subscribers.
A `t` tag with value `teleport` marks a remote participant, when appropriate.
Kind 20001 is a presence heartbeat with empty content and no nickname tag;
it is not a chat message. Persistent location notes use kind 1 and have a
separate subscription and user interface.

Publish the signed event as `["EVENT", event]` to every selected relay and
record each relay's acceptance or rejection locally. NIP-13 proof of work may
help satisfy user-configured filters and rate limits. Include a valid `nonce`
tag and compute the ID and signature after mining; an asserted difficulty
without sufficient leading zero bits does not count. Block lists, proof-of-work
preferences, deduplication, and rate limits can suppress a valid received event.
See [event construction](../bitchat/Nostr/NostrProtocol.swift) and
[inbound handling](../bitchat/ViewModels/NostrInboundPipeline.swift).

## Understand the delivery limit

The client subscribes to kinds 20000 and 20001 with an exact `#g` filter on the
selected relays. The subscription can include `since` and `limit`, but those
fields do not turn ephemeral events into stored history. Relays normally
forward ephemeral events to current subscriptions without retaining them;
NIP-01 treats this as a convention, and implementations may differ.
A client that subscribes later, reconnects later, or uses a disjoint relay set
may miss the message permanently. See
[NIP-01 event kinds](https://github.com/nostr-protocol/nips/blob/master/01.md#kinds).

A relay's `OK` response acknowledges its handling of the publish request;
there is no end-to-end recipient receipt for public geohash messages. Report
that distinction in external tools. For delivery checks, use a controlled
subscriber on the same synthetic channel and relay set. Do not repeatedly
publish to real channels as a reachability test. If durable bulletin content
is required, use the location-note format and its retention semantics instead
of assuming that kind 20000 can be fetched after the fact.
