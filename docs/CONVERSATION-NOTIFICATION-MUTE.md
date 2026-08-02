# Per-conversation notification mute

Issue: [#1594](https://github.com/permissionlesstech/bitchat/issues/1594)

## Behavior

- Direct conversations and geohash channels can be muted independently.
- Mute affects **local notifications only** — messages still arrive, store, and show unread state.
- DM mute keys prefer the peer fingerprint; geohash keys use the lowercase geohash.
- Panic wipe clears all mute preferences (`ConversationNotificationMuteStore.reset()`).

## UI

- DM sheet header: bell / bell.slash toggle next to favorites.
- Location channel header: same toggle beside bookmark and share.

## Implementation

`ConversationNotificationMuteStore` persists muted scope keys in `UserDefaults`. `NotificationService` consults the store before posting DM or geohash activity alerts.
