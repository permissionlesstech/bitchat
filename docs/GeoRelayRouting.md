# Geographic relay routing

Both clients use the same reviewed relay directory at
`permissionlesstech/bitchat`, `main`, `relays/online_relays_gps.csv`.
Cached/bundled data remains usable when a refresh fails. Different directory
versions can still produce different routes until the clients refresh.

## Primary and backup relays

Decode the channel geohash to its center, order unique relay URLs by great-circle
distance, and break equal-distance ties by relay URL. The normal primary count is
five. Route to the nearest twice that count, capped at ten relays total, or all
entries if fewer exist. A zero count selects no relay.

The first five entries are the original primary set; the next five are warm
backups. Subscribe and publish to the entire bounded set, including when the
primaries work. Publishing only to a locally healthy set partitions peers when
an outage affects different users differently. Keeping backups in both directions
allows peers to meet on any mutually reachable candidate without a new event kind,
relay-list announcement, identity, or location signal.

When all primaries fail, traffic continues on any connected backup. Retry failed
connections with exponential backoff capped at five minutes (iOS adds jitter);
DNS and handshake failures are retryable too. WebSocket pings detect silent
connections. If all ten candidates are unreachable, keep retrying and retain
bounded in-memory pending writes; there is no unbounded directory scan. Pending
writes are best effort, not a persistent outbox or relay acceptance guarantee.
Older clients only using the first five cannot communicate through backups when
those five are unavailable to them.

## Directory refresh

On replacement of the directory, recompute every active geographic subscription
and pending geographic publication with the same routing rule. Preserve filters,
subscription IDs, handlers, and signing identities. Close removed subscription
targets and send the original REQ to new targets. Reconnecting a removed socket
must not restore an obsolete REQ. Retain non-geographic/private-message routing.

Retarget pending deliveries to the new set and exclude destinations already
written successfully. Temporarily empty directories retain geographic intent so
later refreshes can repair it. Retire obsolete geographic sockets only when no
subscription or pending delivery still needs them; shared/default sockets remain.

Android must preserve each subscription and pending event's live-location consent
token. Directory notifications and delayed socket callbacks must not recreate
revoked subscriptions, publications, or location-only connections. Explicitly
selected channels remain independent of live-location consent.

## Compatibility vectors

Both clients carry identical `geo-relay-routing-vectors.json` fixtures in their
test resources. All fixture coordinates and geohashes are synthetic. The vectors
cover distance ordering, URL tie breaking, small directories, and zero fanout.
The event wire format is unchanged.
