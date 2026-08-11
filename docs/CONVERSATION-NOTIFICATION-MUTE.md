# Per-conversation notification mute

Issue: [#1594](https://github.com/permissionlesstech/bitchat/issues/1594)

## Behavior

- Direct conversations and geohash channels can be muted independently.
- Mute affects **local notifications only** — messages still arrive, store, and show unread state.
- DM mute keys are the peer fingerprint; geohash keys are the lowercase geohash.
- There is deliberately no routing-peer-ID fallback for DMs: peer IDs rotate, so a mute keyed on one would silently stop applying. Until a handshake yields a fingerprint the toggle is disabled rather than writing a key that expires.
- The toggle, the notification lookup, and the people-sheet badge all resolve the fingerprint through `stableConversationIdentity(for:)`, so the key written and the key read cannot disagree.
- Panic wipe clears all mute preferences (`ConversationNotificationMuteStore.reset()`).

## UI

- DM sheet header: bell / bell.slash toggle next to favorites.
- Location channel header: same toggle beside bookmark and share.
- Mesh people sheet: a `bell.slash` badge on rows whose direct conversation is muted, so the state is visible without opening the thread.

## Implementation

`ConversationNotificationMuteStore` persists muted scope keys in `UserDefaults`. `NotificationService` consults the store before posting DM or geohash activity alerts.
