# Conversation Store: Single Source of Truth

**Status: migration complete (steps 1–5).** `ConversationStore` is the sole
holder of message state; the feature models (`PublicChatModel`,
`PrivateInboxModel`, `PrivateConversationModel`, `PeerListModel`,
`ConversationUIModel`) observe it directly — `PublicChatModel` observes the
active `Conversation` object, so background appends never invalidate it.
`LegacyConversationStore`, `LegacyConversationStoreBridge`, and
`PublicTimelineStore` are deleted. Baselines recorded in
`bitchatTests/Performance/PerformanceBaselineTests.swift`
(`pipeline.privateIngest`, `pipeline.publicIngest`, `store.append`,
`delivery.incrementalUpdate`, `delivery.storeUpdate`).

Deviations from the plan below, chosen at cutover:

- **No `IdentityResolver` canonicalization layer.** Direct conversations stay
  keyed by raw routing `PeerID` (`ConversationID.directPeer`). The
  coordinators' ephemeral↔stable mirroring/consolidation guarantees the
  selected peer's key always holds the full timeline, and no view enumerates
  direct conversations as a list — the legacy resolver-keyed dedup only ever
  fed `isEmpty`-style badge checks (identity-aware unread resolution lives in
  `ChatUnreadStateResolver`, which works on raw keys). `IdentityResolver` was
  deleted with the legacy store; `PeerHandle` slimmed to `id` +
  `routingPeerID`.
- **Selection state lives in the store.** The legacy store also carried the
  two UI selection axes (`activeChannel`, `selectedPrivatePeerID`); they
  moved into `ConversationStore` (`setActiveChannel` /
  `setSelectedPrivatePeer`, deriving `selectedConversationID`), and
  `migrateConversation` hands the private-peer selection off with the
  conversation.
- **`ChatViewModel.messages` / `privateChats` / `unreadPrivateMessages`
  survive as derived read-only views** (not stored properties): coordinators,
  commands, and tests read them; the dict shape is only rebuilt where a
  coordinator genuinely needs the whole dictionary (migration scans, unread
  resolution). Simple per-peer reads dispatch through the store-direct
  `privateMessages(for:)` context witness instead.

---

## 1. Problem

Message state is replicated across four stores, kept eventually consistent by three
async bridges. One inbound private message today:

1. `ChatPrivateConversationCoordinator.handlePrivateMessage` writes through
   `ChatViewModel.privateChats` — a passthrough computed property
   (`ChatViewModel.swift:167-173`) into `PrivateChatManager`'s
   `@Published var privateChats` (`PrivateChatManager.swift:16`).
2. **Bridge 1:** the bootstrapper subscribes `privateChatManager.$privateChats` and
   `$unreadMessages` with `.receive(on: DispatchQueue.main)` sinks
   (`ChatViewModelBootstrapper.swift:92-108`).
3. **Bridge 2:** each sink calls `schedulePrivateConversationStoreSynchronization`,
   a `Task.yield`-debounced task (`ChatViewModel.swift:1084-1092`) that eventually runs
   `synchronizePrivateConversationStore` (`ChatViewModel.swift:1095-1101`).
4. That calls `ConversationStore.synchronizePrivateChats` — a **full-dict replace**: every
   conversation is re-normalized (dedup + `O(n log n)` sort) and diff-compared on every
   sync (`AppArchitecture.swift:304-346`, `normalized` at `AppArchitecture.swift:359-372`).
5. **Bridge 3:** `PrivateInboxModel` subscribes `conversationStore.$messagesByConversation`
   (again `.receive(on: DispatchQueue.main)`) and rebuilds its entire
   `messagesByPeerID` dictionary via `refreshMessages`
   (`PrivateConversationModels.swift:43-48`, `54-68`).
6. SwiftUI finally observes the feature model.

Costs and hazards:

- **O(total messages) × 3 layers per single message.** One append re-sorts, re-compares,
  and re-publishes every conversation through store and feature-model layers. The ingest
  path itself is also quadratic: `isDuplicateMessage` linearly scans *all* private chats
  per inbound message (`ChatPrivateConversationCoordinator.swift:622-630`) and
  `sanitizeChat` re-sorts the whole chat per append (`PrivateChatManager.swift:213-234`).
- **Delivery status mutates two copies.** `ChatDeliveryCoordinator` patches both
  `context.messages` and a value-copied `context.privateChats`
  (`ChatDeliveryCoordinator.swift:105-139`), navigating with a positional
  `messageLocationIndex` (`ChatDeliveryCoordinator.swift:40`) that any non-append
  mutation invalidates, forcing a full rebuild over every message location
  (`ChatDeliveryCoordinator.swift:298-320`).
- **Transient disagreement.** Between the `@Published` write and the debounced sync,
  `privateChatManager.privateChats` and `ConversationStore.messagesByConversation`
  disagree; anything reading the store mid-flight sees stale data.

The public path has the same shape: `@Published var messages`
(`ChatViewModel.swift:122`) is the render copy, `PublicTimelineStore`
(`ChatViewModel.swift:342-345`) is the backing copy, and `handlePublicMessage` appends to
the timeline, then full-replaces the conversation store **per message**
(`ChatPublicConversationCoordinator.swift:504-545` calling
`synchronizePublicConversationStore` at `:358-364`, which funnels into
`ConversationStore.replaceMessages`'s whole-array compare at `AppArchitecture.swift:249-253`),
while a timer-batched `PublicMessagePipeline` mutates `messages` ~80 ms later
(`PublicMessagePipeline.swift`, `TransportConfig.basePublicFlushInterval`).
`PublicChatModel` then mirrors the store again (`PublicChatModel.swift`).

## 2. Design

`ConversationStore` (already `@MainActor` and owned by `AppRuntime`,
`AppRuntime.swift:46`) becomes the **sole writer and sole holder** of message state.

- **`Conversation` is a reference-type `ObservableObject`**, one instance per
  `ConversationID` (`.mesh` / `.geohash` / `.direct`), with `@Published private(set)`
  `messages` and unread state. Each conversation maintains its message-ID index
  **incrementally** (insert on append, never rebuilt from scratch) and owns its cap
  policy: `TransportConfig.meshTimelineCap` / `geoTimelineCap` / `privateChatCap`
  (`TransportConfig.swift:17-19`) fold into the store; `PublicTimelineStore`'s trim logic
  and `PrivateChatManager`'s cap disappear.
- **Publishing granularity is per conversation.** Views observe ONE `Conversation`
  object. An append to chat A never invalidates observers of chat B — unlike today,
  where any write republishes the entire `messagesByConversation` dictionary
  (`AppArchitecture.swift:205`) and every bound feature model rebuilds.
- **Store-level `changes: PassthroughSubject<ConversationChange, Never>`** for non-UI
  consumers (delivery tracking, notifications, gossip/sync) that need "a message was
  appended / status changed in conversation X" without subscribing to message arrays.
- **Mutations go through an intent API only**, mirroring the codebase's existing
  single-writer intent ops (`ChatViewModel.swift:421-424`, the `private(set)` +
  dedicated-mutator pattern):
  - `append(_:to:)` — incremental, dedup via the ID index
  - `upsertByID(_:in:)` — replace-or-append (media progress, edits)
  - `setDeliveryStatus(_:for:in:)` — keyed by message ID, no positional index
  - `markRead(_:)` / `markUnread(_:)`
  - `migrateConversation(from:to:)` — the ephemeral↔stable peer-ID handoff that today
    is hand-rolled dictionary surgery in three places
  - `clear(_:)`
  Backing collections are `private(set)`; coordinators receive the intent surface, not
  the dictionaries.
- **Reads are synchronous.** Because writers and readers share the main actor and there
  is one copy, "await the sync" disappears: after `append` returns, every observer of
  that `Conversation` sees the message.

## 3. Deleted at end state (done)

- `PublicTimelineStore` (`bitchat/ViewModels/PublicTimelineStore.swift`) — folded into
  `Conversation` cap/dedup policy.
- `PrivateChatManager`'s message dict and trim/sanitize logic — the manager shrinks to
  read-receipt policy (`markAsRead`, `syncReadReceiptsForSentMessages`).
- `ChatDeliveryCoordinator.messageLocationIndex` and its growth/rebuild machinery
  (`ChatDeliveryCoordinator.swift:40-45`, `221-320`) — replaced by
  `setDeliveryStatus(for:in:)` against the per-conversation ID index.
- Both bootstrapper sync bridges (`ChatViewModelBootstrapper.swift:92-108`).
- `schedulePrivateConversationStoreSynchronization` /
  `synchronizePrivateConversationStore` and the public equivalents
  (`ChatViewModel.swift:1084-1101`, `ChatPublicConversationCoordinator.swift:351-386`).
- Feature-model mirror collections: `PrivateInboxModel.messagesByPeerID`,
  `PublicChatModel.messages` (they observe `Conversation` objects directly).
- `ChatViewModel.messages` / `ChatViewModel.privateChats` as stored/owning properties.

## 4. Migration plan (complete)

Each step lands green against the full suite plus the `PerformanceBaselineTests`
numbers (no pipeline throughput regression at any step).

1. **Additive store.** Introduce `Conversation` objects and the intent API inside
   `ConversationStore` alongside the existing replace-based API. Nothing reads them yet.
2. **Private cutover with compat shims.** Inbound/outbound private paths write through
   the intent API. `ChatViewModel.privateChats` becomes a derived **read-only** view of
   the store; `PrivateChatManager`'s dict and the private sync bridges are bypassed but
   the property surface stays so coordinators/tests compile unchanged.
3. **Public cutover.** `handlePublicMessage` and the `PublicMessagePipeline` flush write
   to the store; `PublicTimelineStore` folds in; `ChatViewModel.messages` becomes a
   derived view of the active conversation.
4. **Delivery via store.** `ChatDeliveryCoordinator` switches to
   `setDeliveryStatus(for:in:)`; `messageLocationIndex` is deleted.
5. **View cutover.** Views and feature models observe `Conversation` objects directly;
   delete all shims, mirrors, and the replace-based store API.

## 5. Non-goals

- **No message persistence.** bitchat is ephemeral by design; the store stays in-memory.
- **`sentReadReceipts` UserDefaults persistence stays put** (`ChatViewModel.swift:394-406`);
  it is receipt-protocol state, not conversation state.
- **`MessageRouter`'s outbox remains the SSOT for unsent messages**; the store records
  delivery status but never owns retry/resend queues.
