# Message deep links

Related: [#587](https://github.com/permissionlesstech/bitchat/issues/587)

## Format

`MessageDeepLink` builds `bitchat://` URLs with a message ID query parameter:

| Scope | Example |
|-------|---------|
| mesh | `bitchat://mesh/?mid=<id>` |
| geohash | `bitchat://geohash/u4pru?mid=<id>` |
| direct | `bitchat://dm/<peer-id>?mid=<id>` |

The context menu **copy message link** action copies a plain-text line containing the URL. Universal links are out of scope; custom-scheme links work on iOS today and give people a stable reference for a specific line.

## Opening a link

`MessageListView.handleOpenURL` switches to the link's conversation, then reveals the message named by `mid`:

1. The message ID is held in `pendingDeepLinkMessageID` rather than acted on immediately, so the destination conversation has rendered before we look for the row.
2. If the target sits behind the render window, the window is grown to include it (`MessageDeepLink.windowCount(toReveal:inTotal:current:)`). An unrendered row is not in the view hierarchy and `scrollTo` would silently do nothing — this is what makes the parameter more than decoration.
3. The row is addressed as `"<contextKey>|<messageID>"`, matching how `MessageDisplayItem.id` is composed, and scrolled to centre.

An unknown `mid` is dropped: the referenced message may simply never have reached this device.

## Validating the `dm` path

A `bitchat://dm/<id>` link can be opened by any app or webpage, so the path is shape-checked before it reaches conversation state — otherwise an arbitrary string opens a conversation against an identity that never existed.

`MessageDeepLink.directConversationTarget(fromPath:)` accepts only the conversation shapes this file emits links for: a bare 16-hex mesh peer, a `nostr_` geo DM, or a `group_` conversation. Routing-only prefixes (`noise:`, `name:`, `mesh:`, `bridge:`) and geohash *chat* IDs are rejected, as is anything non-hex or over-length. This mirrors the charset/length gate the geohash handler already applies.

## Location precision

Copying a **geohash** message link puts the channel's geohash on the pasteboard, disclosing interest in a place rather than merely that someone uses bitchat. Copying is therefore gated behind the same confirmation that [#1513](https://github.com/permissionlesstech/bitchat/pull/1513) put in front of invite sharing, reusing `ChannelShare.shouldWarn(forGeohash:)` so the two thresholds cannot drift apart.

Mesh and DM links carry no location and are copied without a prompt.

## Known limitation: DM links embed a routing peer ID

`bitchat://dm/<peer-id>` addresses the conversation by its current routing peer ID. Those rotate, so a copied DM link goes stale once the peer rotates, and the link discloses the live routing ID at the time of copying.

Fingerprint-based addressing would be durable and would not leak the routing ID, but the fingerprint is not always known at copy time (it needs a completed handshake) and resolving one back to a conversation needs a lookup that does not exist yet. Left as follow-up rather than shipped half-done.

## Future work

- Address DM links by fingerprint instead of routing peer ID.
- Highlight the revealed message briefly, not just scroll to it.
- Adopt associated domains when a web fallback exists.
