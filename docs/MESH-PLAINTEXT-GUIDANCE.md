# Mesh plaintext security UX

Issue: [#1064](https://github.com/permissionlesstech/bitchat/issues/1064)

## Approach

This is intentionally **non-breaking**: `#mesh` remains the default channel. Instead:

1. A dismissible banner above the mesh composer explains that mesh traffic is a plaintext local broadcast. Its body is bridge-aware: with the bridge on it also names Nostr relays as a reachable audience.
2. Panic wipe restores the banner so a wiped device gets the guidance again.

There is deliberately only one surface. An earlier revision also added a
plaintext line to the empty mesh timeline, which meant both showed at once on
an empty #mesh — two warnings for one fact. The composer banner is the one
that survives, because it is present whether or not the timeline has messages.

Private conversations and location channels are unchanged. The goal is informed consent before someone broadcasts sensitive content, not forced channel migration.
