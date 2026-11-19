# Mesh plaintext security UX

Issue: [#1064](https://github.com/permissionlesstech/bitchat/issues/1064)

## Approach

This is intentionally **non-breaking**: `#mesh` remains the default channel. Instead:

1. A dismissible banner above the mesh composer explains that mesh traffic is a plaintext local broadcast. Its body is bridge-aware: with the bridge on it also names Nostr relays as a reachable audience.
2. Panic wipe restores the banner so a wiped device gets the guidance again.

The composer shows one warning on #mesh, including before the first message.
The empty timeline still offers the channel-switch hint, radar, and nearby activity.

Private conversations and location channels are unchanged. The goal is informed consent before someone broadcasts sensitive content, not forced channel migration.
