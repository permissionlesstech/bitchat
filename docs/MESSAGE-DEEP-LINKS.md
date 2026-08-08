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

## Future work

- Handle `mid` on open to scroll/highlight the referenced message.
- Adopt associated domains when a web fallback exists.
