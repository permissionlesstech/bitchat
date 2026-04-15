# Architecture V2

This branch starts a larger simplification effort focused on performance, reliability, and maintainability without rewriting the transport and protocol stack in one pass.

## What Landed

1. `AppRuntime` is now the composition root for startup, lifecycle, notification routing, and shared-content intake.
2. `BitchatApp` is reduced to app wiring and no longer owns operational startup logic.
3. `AppEventStream` introduces a typed async event surface for app-level events.
4. `PeerHandle` and `ConversationID` establish canonical identity/conversation keys above the existing transport-specific IDs.
5. `IdentityResolver` mirrors the current peer graph into canonical handles.
6. `ConversationStore` now owns app-layer conversation context for the active public channel and selected private conversation, while also mirroring the current public/private message timelines under canonical IDs.
7. `AppRuntime` now owns Tor, screenshot, and Nostr reconnect observer wiring instead of leaving that app-lifecycle graph inside `ChatViewModel`.
8. `PublicChatModel`, `PrivateInboxModel`, `PrivateConversationModel`, `ConversationUIModel`, `LocationChannelsModel`, and `PeerListModel` provide focused view-facing models for public chat, private inbox state, selected-DM state, composer/message interactions, location-channel state, and peer counts. `PrivateInboxModel` now reads its message, unread, and selection state directly from `ConversationStore` instead of merging through `PrivateChatManager`.
9. `AppChromeModel` now owns app-chrome presentation state for nickname editing, fingerprint routing, app-info/location sheet visibility, unread-private-chat affordances, and screenshot/privacy UI.
10. `ContentView`, `MessageListView`, `LocationChannelsSheet`, `LocationNotesView`, `CommandSuggestionsView`, `FingerprintView`, and `VerificationSheetView` no longer talk directly to `ChatViewModel` or location singletons for their primary app-layer state; they consume feature-scoped models injected from `AppRuntime`.
11. `PeerListModel` now consumes the runtime-owned `LocationChannelsModel` instead of reading the location manager directly, and QR scan parsing is funneled through `VerificationModel` rather than the SwiftUI views.
12. `ChatViewModel` is thinner on the app side: startup wiring now lives in `ChatViewModelBootstrapper`, send/lifecycle/transport seams live in focused coordinators, and peer-list notification/timer state now lives in `ChatPeerListCoordinator` instead of the main view model.

## Why This Shape

- `ChatViewModel` remains the active domain/UI bridge so the app can keep working while we migrate feature-by-feature.
- The new runtime/store layer gives us a safe place to move lifecycle, routing, and cross-cutting state before we split the UI into smaller feature models.
- `ConversationStore` now owns the selected conversation context and private-inbox read state, which lets feature models read one runtime-managed source of truth for focus/navigation and DM timelines even while legacy mutation paths still flow through `ChatViewModel`.
- The new chrome model lets us remove presentation-only state from `ChatViewModel` without forcing a big rewrite of the domain/message paths.
- The private-conversation model pulls selected-DM header identity, availability, encryption, and favorite state out of `ContentView`, which keeps the view from re-implementing peer lookup rules.
- The conversation UI model centralizes composer state, autocomplete, message formatting, and row-level actions so the main views no longer proxy most conversation interactions directly to `ChatViewModel`.
- The location channels model gives the remaining location-heavy views a focused adapter over the location/bookmark/network singletons, which reduces direct global reads in the view layer and makes smoke/architecture tests more reliable.
- Reusing that same location model inside the peer-list feature keeps geohash/mesh presence presentation on one runtime-owned source of truth instead of mixing view models with singleton reads.
- `BitchatApp` now injects only feature-scoped models into the view tree, which removes the old pattern of keeping `ChatViewModel` as a global environment object for the entire app shell.
- Routing QR scan parsing through the verification model keeps the verification UI as a passive renderer and gives us a clearer seam for future camera/manual-scan behavior changes.
- The new `ChatViewModel` coordinators are intentionally transitional: they shrink the main file and isolate composition, lifecycle, transport, and peer-list responsibilities without forcing a risky rewrite of the transport/BLE core in the same pass.

## Next Steps

1. Migrate view composition from one global `ChatViewModel` to focused feature models backed by `ConversationStore`.
2. Route more inbound transport events through typed app/domain events instead of delegate plus notification fan-out.
3. Move private/public conversation mutation behind the new store instead of still mirroring legacy message writes from `ChatViewModel`.
4. Replace remaining singleton-heavy seams with injected runtime services where practical.
5. Revisit actor isolation for identity and conversation state once the remaining message/peer models are safe to move off the main actor.
