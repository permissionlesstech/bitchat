# Private media decode failures (#1518)

When authenticated private media fails local validation, bitchat now:

1. Logs a structured reason code (`PrivateMediaDecodeFailureReason.logLabel`).
2. Posts a **system line in the affected DM** with a people-readable explanation.

Public mesh file transfers keep the existing security logging path without spamming the mesh timeline.

## Rate limiting

Decode failures are attacker-triggerable: an authenticated peer can send malformed media as fast as the link allows, and one system line per payload would let them flood a DM thread.

`PrivateMediaDecodeFailureThrottle` posts at most one line per peer per five-minute window. Failures suppressed inside a window are counted, not dropped — the next line that surfaces reports how many were withheld. Peers are throttled independently, so a hostile sender cannot silence a genuine failure from someone else, and windows that closed long ago are pruned so a sender rotating peer IDs cannot grow the throttle's state without bound.

## Blocked senders

A decode failure from a blocked peer is swallowed: no system line is posted, and `handlePrivatePayload` returns `true` where every other failure returns `false`.

The return value distinguishes "consumed, deliberately silent" from "could not handle this". A blocked sender's payload is not a failure to handle — it is a drop we chose, and blocking should produce no local UI. Marking it `false` would file a deliberate policy drop alongside genuine decode errors.

This is currently a statement of intent rather than a behavior change: `handlePrivatePayload` is `@discardableResult` and its only production caller (`BLEService`, the `.privateFile` branch of `deliverNoisePayload`) ignores the result. Today the difference is observable only to `BLEFileTransferHandlerTests`. It matters if a caller ever starts branching on it.
