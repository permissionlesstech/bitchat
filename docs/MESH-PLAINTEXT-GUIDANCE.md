# Mesh plaintext security UX

Issue: [#1064](https://github.com/permissionlesstech/bitchat/issues/1064)

## Approach

This is intentionally **non-breaking**: `#mesh` remains the default channel. Instead:

1. A dismissible banner above the mesh composer explains that mesh traffic is a plaintext local broadcast.
2. The empty mesh timeline adds a one-line plaintext reminder.
3. Panic wipe restores the banner so a wiped device gets the guidance again.

Private conversations and location channels are unchanged. The goal is informed consent before someone broadcasts sensitive content, not forced channel migration.
