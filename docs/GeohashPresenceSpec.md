# Geohash Presence Specification

## Overview

The Geohash Presence feature provides a mechanism to track online participants in geohash-based location channels. It uses a dedicated ephemeral Nostr event kind to broadcast "heartbeats," ensuring accurate and privacy-preserving online counts.

## Nostr Protocol

### Event Kind
A new ephemeral event kind is defined for presence heartbeats:
- **Kind:** `20001` (`GEOHASH_PRESENCE`)
- **Type:** Ephemeral (not stored by relays long-term)

### Event Structure
The presence event mimics the structure of a geohash chat message (Kind 20000) but without content or nickname metadata, to minimize overhead and focus purely on "liveness".

```json
{
  "kind": 20001,
  "created_at": <timestamp>,
  "tags": [
    ["g", "<geohash>"]
  ],
  "content": "",
  "pubkey": "<geohash_derived_pubkey>",
  "id": "<event_id>",
  "sig": "<signature>"
}
```

*   **`content`**: Must be empty string.
*   **`tags`**: Must include `["g", "<geohash>"]`. Should NOT include `["n", "<nickname>"]`.
*   **`pubkey`**: The ephemeral identity derived specifically for this geohash (same as used for chat messages).

## Client Behavior

### 1. Broadcasting Presence

Clients MUST broadcast a Kind 20001 presence event globally when the app is open, regardless of which screen the user is viewing.

*   **Global Heartbeat:**
    *   **Trigger:** Application start / initialization, or whenever location (available geohashes) changes.
    *   **Frequency:** Randomized loop interval between **40s and 80s** (average 60s).
    *   **Scope:** Sent to *all* geohash channels corresponding to the device's *current physical location*.
    *   **Privacy Restriction:** Presence MUST ONLY be broadcast to low-precision geohash levels to protect user privacy. Specifically:
        *   **Allowed:** `REGION` (precision 2), `PROVINCE` (precision 4), `CITY` (precision 5).
        *   **Denied:** `NEIGHBORHOOD` (precision 6), `BLOCK` (precision 7), `BUILDING` (precision 8+).
    *   **Decorrelation:** Individual broadcasts within a heartbeat loop must be separated by random delays (e.g., 2-5 seconds) to prevent temporal correlation of public keys across different geohash levels. The main loop delay is adjusted to maintain the target average cadence.

### 2. Subscribing to Presence

Clients must update their Nostr filters to listen for both chat and presence events on geohash channels.

*   **Filter:**
    *   `kinds`: `[20000, 20001]`
    *   `#g`: `["<geohash>"]`

### 3. Participant Counting

The "online participants" count shown in the UI aggregates unique public keys from both presence heartbeats and active chat messages.

*   **Logic:**
    *   Maintain a map of `pubkey -> last_seen_timestamp` for each geohash.
    *   Update `last_seen_timestamp` upon receiving a valid **Kind 20001 (Presence)** OR **Kind 20000 (Chat)** event.
    *   A participant is considered "online" if their `last_seen_timestamp` is within the last **5 minutes**.

### 4. UI Presentation

The presentation of the participant count depends on the geohash precision level and data availability.

*   **Standard Display:** For channels where presence is broadcast (Region, Province, City) OR any channel where at least one participant has been detected, show the exact count: `[N people]`.
*   **High-Precision Uncertainty:** For high-precision channels (Neighborhood, Block, Building) where:
    *   Presence broadcasting is disabled (privacy restriction).
    *   **AND** the detected participant count is `0`.
    *   **Display:** `[? people]`
    *   **Reasoning:** Since clients don't announce themselves in these channels, a count of "0" is misleading (people could be lurking).

### 5. Implementation Details (Android Reference)

*   **`NostrKind.GEOHASH_PRESENCE`**: Added constant `20001`.
*   **`NostrProtocol.createGeohashPresenceEvent`**: Helper to generate the event.
*   **`GeohashViewModel`**:
    *   `startGlobalPresenceHeartbeat()`: Coroutine that `collectLatest` on `LocationChannelManager.availableChannels`.
    *   Implements randomized loop logic (40-80s) and per-broadcast random delays (2-5s).
    *   Filters channels by `precision <= 5` before broadcasting.
*   **`GeohashMessageHandler`**:
    *   Refactored `onEvent` to update participant counts for both Kind 20000 and 20001.
*   **`LocationChannelsSheet`**:
    *   Implements the `[? people]` display logic for high-precision, zero-count channels.

## Benefits

*   **Accuracy:** Counts reflect both active listeners (via heartbeats) and active speakers (via messages).
*   **Privacy:** High-precision location presence is NOT broadcast. Temporal correlation between different levels is obfuscated via random delays.
*   **Consistency:** "Online" status is maintained globally while the app is open.
*   **Transparency:** The UI correctly reflects uncertainty (`?`) when privacy rules prevent accurate passive counting.
