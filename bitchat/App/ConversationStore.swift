//
// ConversationStore.swift
// bitchat
//
// Single source of truth for conversation message state (see
// docs/CONVERSATION-STORE-DESIGN.md). One `Conversation` object per
// `ConversationID`; all mutations flow through the store's intent API and
// every mutation emits a `ConversationChange` after state is consistent.
//
// The store also owns conversation selection: the active public channel and
// the selected private peer (the two UI selection axes) plus the derived
// `selectedConversationID`.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import BitLogger
import Combine
import Foundation

// MARK: - Conversation

/// A single conversation timeline (`.mesh`, `.geohash`, or `.direct`).
///
/// Publishing granularity is per conversation: views observe ONE
/// `Conversation` object, so an append to chat A never invalidates observers
/// of chat B.
///
/// Mutations are `fileprivate` by design — only `ConversationStore`'s intent
/// API may mutate a conversation, keeping the store the sole writer.
@MainActor
final class Conversation: ObservableObject, Identifiable {
    let id: ConversationID
    /// Maximum retained messages; oldest are trimmed on overflow.
    let cap: Int

    @Published private(set) var messages: [BitchatMessage] = []
    @Published private(set) var isUnread: Bool = false

    /// Incrementally-maintained message-ID → index map for O(1) dedup and
    /// delivery-status lookup. Kept in sync on every mutation:
    /// - tail append: single insert
    /// - out-of-order insert: suffix reindex from the insertion point
    /// - trim: full rebuild — `removeFirst(k)` is already O(n), so the
    ///   rebuild does not change the asymptotics, and trim only happens once
    ///   the cap (1337) is reached. Simple and correct beats the
    ///   offset-tracking alternative here.
    private var indexByMessageID: [String: Int] = [:]

    fileprivate init(id: ConversationID, cap: Int) {
        self.id = id
        self.cap = max(1, cap)
    }

    // MARK: Reads

    func containsMessage(withID messageID: String) -> Bool {
        indexByMessageID[messageID] != nil
    }

    func message(withID messageID: String) -> BitchatMessage? {
        guard let index = indexByMessageID[messageID] else { return nil }
        return messages[index]
    }

    /// All message IDs currently in this conversation (unordered).
    var messageIDs: Dictionary<String, Int>.Keys {
        indexByMessageID.keys
    }

    // MARK: Store-internal mutations

    /// Result of an ordered insert. `trimmedMessageIDs` reports messages
    /// evicted by the cap so the store can keep its message-ID →
    /// conversation map exact.
    fileprivate struct InsertResult {
        let inserted: Bool
        let trimmedMessageIDs: [String]

        static let duplicate = InsertResult(inserted: false, trimmedMessageIDs: [])
    }

    fileprivate enum UpsertOutcome {
        case appended(trimmedMessageIDs: [String])
        case updated
    }

    /// Inserts a message in timestamp order, deduplicating by message ID.
    /// Fast path appends when the timestamp is >= the current tail;
    /// otherwise a binary search finds the upper-bound insertion point so
    /// arrival order is preserved among equal timestamps.
    /// Reports `inserted: false` if a message with the same ID already exists.
    fileprivate func insert(_ message: BitchatMessage) -> InsertResult {
        guard indexByMessageID[message.id] == nil else { return .duplicate }

        if let last = messages.last, message.timestamp < last.timestamp {
            let index = insertionIndex(for: message.timestamp)
            messages.insert(message, at: index)
            reindex(from: index)
        } else {
            messages.append(message)
            indexByMessageID[message.id] = messages.count - 1
        }

        return InsertResult(inserted: true, trimmedMessageIDs: trimIfNeeded())
    }

    /// Replace-or-append by message ID. An existing message keeps its
    /// timeline position (in-place updates like media progress reuse the
    /// original timestamp); a new message goes through ordered insertion.
    fileprivate func upsert(_ message: BitchatMessage) -> UpsertOutcome {
        if let index = indexByMessageID[message.id] {
            messages[index] = message
            return .updated
        }
        let result = insert(message)
        return .appended(trimmedMessageIDs: result.trimmedMessageIDs)
    }

    /// Applies a delivery status keyed by message ID, honoring the
    /// no-downgrade rule (the SOLE enforcement point — every delivery
    /// update flows through the store): equal statuses are skipped, and
    /// `.read` is never downgraded to `.delivered` or `.sent`.
    /// Returns `true` when the status was applied.
    fileprivate func applyDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String) -> Bool {
        guard let index = indexByMessageID[messageID] else { return false }
        let message = messages[index]
        guard !Self.shouldSkipStatusUpdate(current: message.deliveryStatus, new: status) else { return false }

        message.deliveryStatus = status
        // BitchatMessage is a reference type; write back through the
        // subscript so the @Published wrapper emits.
        messages[index] = message
        return true
    }

    /// Republishes a message without changing state. Used for mirrored
    /// copies that share a BitchatMessage instance: the first conversation's
    /// status apply mutated the shared object, so this conversation's
    /// observers still need an @Published emission to re-render.
    @discardableResult
    fileprivate func republishMessage(withID messageID: String) -> Bool {
        guard let index = indexByMessageID[messageID] else { return false }
        messages[index] = messages[index]
        return true
    }

    @discardableResult
    fileprivate func setUnread(_ unread: Bool) -> Bool {
        guard isUnread != unread else { return false }
        isUnread = unread
        return true
    }

    /// Removes a single message by ID. Returns the removed message, or
    /// `nil` when no message with that ID exists.
    fileprivate func remove(messageID: String) -> BitchatMessage? {
        guard let index = indexByMessageID[messageID] else { return nil }
        let removed = messages.remove(at: index)
        indexByMessageID.removeValue(forKey: messageID)
        reindex(from: index)
        return removed
    }

    /// Removes every message matching `predicate`. Returns the removed
    /// message IDs (empty when nothing matched).
    fileprivate func removeAll(where predicate: (BitchatMessage) -> Bool) -> [String] {
        var removedIDs: [String] = []
        messages.removeAll { message in
            guard predicate(message) else { return false }
            removedIDs.append(message.id)
            return true
        }
        guard !removedIDs.isEmpty else { return [] }
        for id in removedIDs {
            indexByMessageID.removeValue(forKey: id)
        }
        reindex(from: 0)
        return removedIDs
    }

    fileprivate func clearMessages() {
        messages.removeAll()
        indexByMessageID.removeAll()
    }

    // MARK: Diagnostics

    /// Appends human-readable invariant violations for this conversation
    /// (empty when healthy): the ID index must be the exact inverse of the
    /// messages array, the cap must hold, and timestamps must be
    /// non-decreasing (equal timestamps keep arrival order, so only strict
    /// inversions are violations). O(messages); allocates only on violation.
    fileprivate func collectInvariantViolations(into violations: inout [String], label: String) {
        if indexByMessageID.count != messages.count {
            violations.append("\(label): index has \(indexByMessageID.count) entries for \(messages.count) messages")
        }
        if messages.count > cap {
            violations.append("\(label): \(messages.count) messages exceeds cap \(cap)")
        }
        var previousTimestamp: Date?
        for position in messages.indices {
            let message = messages[position]
            // Count equality + every message resolving to its own position
            // proves the index is exactly the inverse map (no stale extras).
            if let index = indexByMessageID[message.id] {
                if index != position {
                    violations.append("\(label): message \(message.id.prefix(8))… at \(position) indexed at \(index)")
                }
            } else {
                violations.append("\(label): message \(message.id.prefix(8))… at \(position) missing from index")
            }
            if let previousTimestamp, message.timestamp < previousTimestamp {
                violations.append("\(label): timestamp order violated at \(position)")
            }
            previousTimestamp = message.timestamp
        }
    }

    // MARK: Internals

    static func shouldSkipStatusUpdate(current: DeliveryStatus?, new: DeliveryStatus) -> Bool {
        guard let current else { return false }
        if current == new { return true }

        // Never downgrade to a weaker delivery state. Ordering of certainty:
        // sending < sent < carried < delivered < read. A late `.sent` write
        // (e.g. the optimistic stamp after routing) must not clobber the
        // `.carried` the router already set when it handed a copy to a
        // courier/bridge, nor a `.delivered`/`.read` ack. A late asynchronous
        // failure is weaker than a confirmed recipient receipt too, so it may
        // not replace `.delivered`/`.read`. Same for the
        // `.sending` stamp a pre-handshake resend emits asynchronously: it
        // can land after the message already reached `.sent`, and "Sent" was
        // already truthful. (`.failed` → `.sending` stays allowed so a real
        // failure retry is visible.)
        switch (current, new) {
        case (.read, .delivered), (.read, .carried), (.read, .sent), (.read, .sending), (.read, .failed):
            return true
        case (.delivered, .carried), (.delivered, .sent), (.delivered, .sending), (.delivered, .failed):
            return true
        case (.carried, .sent), (.carried, .sending):
            return true
        case (.sent, .sending):
            return true
        default:
            return false
        }
    }

    /// Upper-bound binary search: first index whose timestamp is strictly
    /// greater than `timestamp`, so equal-timestamp messages keep arrival
    /// order.
    private func insertionIndex(for timestamp: Date) -> Int {
        var low = 0
        var high = messages.count
        while low < high {
            let mid = (low + high) / 2
            if messages[mid].timestamp <= timestamp {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func reindex(from start: Int) {
        for index in start..<messages.count {
            indexByMessageID[messages[index].id] = index
        }
    }

    /// Trims oldest messages over the cap; returns the trimmed message IDs.
    private func trimIfNeeded() -> [String] {
        guard messages.count > cap else { return [] }
        let overflow = messages.count - cap
        let trimmedIDs = messages.prefix(overflow).map(\.id)
        for id in trimmedIDs {
            indexByMessageID.removeValue(forKey: id)
        }
        messages.removeFirst(overflow)
        reindex(from: 0)
        return trimmedIDs
    }
}

// MARK: - ConversationChange

/// Typed mutation events for non-UI consumers (delivery tracking,
/// notifications, sync) that need "something changed in conversation X"
/// without subscribing to whole message arrays. Emitted on the store's
/// `changes` subject AFTER the corresponding state is consistent.
enum ConversationChange {
    case appended(ConversationID, BitchatMessage)
    case updated(ConversationID, messageID: String)
    case statusChanged(ConversationID, messageID: String, DeliveryStatus)
    case messageRemoved(ConversationID, messageID: String)
    case cleared(ConversationID)
    case removed(ConversationID)
    case migrated(from: ConversationID, to: ConversationID)
    case unreadChanged(ConversationID, isUnread: Bool)
}

// MARK: - ConversationStore

/// Sole writer and sole holder of conversation message state. All mutations
/// go through the intent API below; backing collections are `private(set)`.
/// Reads are synchronous — writers and readers share the main actor, so
/// after an intent returns every observer sees the result.
@MainActor
final class ConversationStore: ObservableObject {
    /// Conversation creation order; published so list-style consumers can
    /// observe conversations appearing/disappearing without rebuilding from
    /// the dictionary.
    @Published private(set) var conversationIDs: [ConversationID] = []
    @Published private(set) var selectedConversationID: ConversationID?
    @Published private(set) var unreadConversations: Set<ConversationID> = []

    // MARK: Selection state
    // The two UI selection axes: which public channel is active, and which
    // private chat (if any) is open on top of it. `selectedConversationID`
    // is derived: the open private chat wins, otherwise the active public
    // channel's conversation. Mutate via `setActiveChannel` /
    // `setSelectedPrivatePeer` only.

    @Published private(set) var activeChannel: ChannelID = .mesh
    @Published private(set) var selectedPrivatePeerID: PeerID?

    private(set) var conversationsByID: [ConversationID: Conversation] = [:]

    /// Store-level message-ID → conversation-membership map for ID-only
    /// lookups (delivery receipts arrive with a message ID, not a
    /// conversation). Maintained incrementally at every mutation point —
    /// all mutation is centralized in the intent API below, so the map is
    /// exact, never scanned or rebuilt.
    ///
    /// The value is a `Set` because a private message can legitimately live
    /// in TWO direct conversations: step 2's raw per-peer keying mirrors a
    /// message into both the stable-key and ephemeral-peer chats
    /// (`mirrorToEphemeralIfNeeded`). A delivery update must reach both
    /// copies.
    private var conversationIDsByMessageID: [String: Set<ConversationID>] = [:]

    /// Monotonic count of messages inserted into any conversation (appends,
    /// upsert-appends, migration inserts). Field-observability only: the
    /// periodic store audit folds the delta into its heartbeat line so logs
    /// carry throughput context. Never read on a hot path.
    private(set) var appendCount: Int = 0

    /// Sample counter for the mirrored-republish debug log in the ID-only
    /// `setDeliveryStatus` fan-out (first + every Nth occurrence).
    private var mirroredRepublishLogCount = 0

    let changes = PassthroughSubject<ConversationChange, Never>()

    // MARK: Intent API

    /// Returns the conversation for `id`, creating it (with the cap policy
    /// for its kind) on first access.
    @discardableResult
    func conversation(for id: ConversationID) -> Conversation {
        if let existing = conversationsByID[id] {
            return existing
        }
        let conversation = Conversation(id: id, cap: Self.cap(for: id))
        conversationsByID[id] = conversation
        conversationIDs.append(id)
        return conversation
    }

    /// Appends a message in timestamp order. Returns `false` (and emits
    /// nothing) if a message with the same ID is already present.
    @discardableResult
    func append(_ message: BitchatMessage, to id: ConversationID) -> Bool {
        let conversation = conversation(for: id)
        let result = conversation.insert(message)
        guard result.inserted else { return false }
        registerMessageID(message.id, in: id)
        unregisterMessageIDs(result.trimmedMessageIDs, from: id)
        changes.send(.appended(id, message))
        return true
    }

    /// Replace-or-append by message ID (media progress, edits).
    func upsertByID(_ message: BitchatMessage, in id: ConversationID) {
        let conversation = conversation(for: id)
        switch conversation.upsert(message) {
        case .appended(let trimmedMessageIDs):
            registerMessageID(message.id, in: id)
            unregisterMessageIDs(trimmedMessageIDs, from: id)
            changes.send(.appended(id, message))
        case .updated:
            changes.send(.updated(id, messageID: message.id))
        }
    }

    /// Applies a delivery status keyed by message ID. Returns `false` when
    /// the message is unknown or the update would downgrade the status
    /// (read beats delivered beats sent).
    @discardableResult
    func setDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String, in id: ConversationID) -> Bool {
        guard let conversation = conversationsByID[id],
              conversation.applyDeliveryStatus(status, forMessageID: messageID) else {
            return false
        }
        changes.send(.statusChanged(id, messageID: messageID, status))
        return true
    }

    /// Applies a delivery status to EVERY conversation containing
    /// `messageID` (ID-only — delivery receipts don't know conversations;
    /// mirrored private copies live in two direct chats). Returns `false`
    /// when the message is unknown or no copy changed (equal status or
    /// downgrade — read beats delivered beats sent).
    ///
    /// `BitchatMessage` is a reference type, so mirrored copies sharing one
    /// instance are mutated by the first conversation's apply. The skipped
    /// conversations still hold the changed message, so they get an explicit
    /// republish and `.statusChanged` event - otherwise a view observing the
    /// mirrored conversation would render stale status. Distinct copies whose
    /// update was genuinely rejected (downgrade) are left untouched, guarded
    /// by status equality.
    @discardableResult
    func setDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String) -> Bool {
        guard let ids = conversationIDsByMessageID[messageID] else { return false }
        var applied = false
        var skipped: [ConversationID] = []
        for id in ids {
            if setDeliveryStatus(status, forMessageID: messageID, in: id) {
                applied = true
            } else {
                skipped.append(id)
            }
        }
        guard applied else { return false }
        for id in skipped {
            guard let conversation = conversationsByID[id],
                  conversation.message(withID: messageID)?.deliveryStatus == status,
                  conversation.republishMessage(withID: messageID) else { continue }
            // Field proof the mirrored-copy republish path actually fires;
            // sampled (first + every Nth) so mirrored chats can't spam logs.
            mirroredRepublishLogCount += 1
            if mirroredRepublishLogCount == 1
                || mirroredRepublishLogCount.isMultiple(of: TransportConfig.conversationStoreMirroredRepublishLogInterval) {
                SecureLogger.debug(
                    "mirrored republish #\(mirroredRepublishLogCount) for \(messageID.prefix(8))… in \(id.auditDescription)",
                    category: .session
                )
            }
            changes.send(.statusChanged(id, messageID: messageID, status))
        }
        return true
    }

    /// Current delivery status of `messageID` in whichever conversation
    /// holds it (mirrored copies share status — see `setDeliveryStatus`).
    func deliveryStatus(forMessageID messageID: String) -> DeliveryStatus? {
        guard let ids = conversationIDsByMessageID[messageID] else { return nil }
        for id in ids {
            if let status = conversationsByID[id]?.message(withID: messageID)?.deliveryStatus {
                return status
            }
        }
        return nil
    }

    /// Every conversation currently containing `messageID` (empty when the
    /// message is unknown).
    func conversationIDs(forMessageID messageID: String) -> Set<ConversationID> {
        conversationIDsByMessageID[messageID] ?? []
    }

    func markRead(_ id: ConversationID) {
        guard unreadConversations.contains(id) else { return }
        unreadConversations.remove(id)
        conversationsByID[id]?.setUnread(false)
        changes.send(.unreadChanged(id, isUnread: false))
    }

    func markUnread(_ id: ConversationID) {
        guard !unreadConversations.contains(id) else { return }
        let conversation = conversation(for: id)
        unreadConversations.insert(id)
        conversation.setUnread(true)
        changes.send(.unreadChanged(id, isUnread: true))
    }

    /// Selects a conversation (creating it if needed) or clears the
    /// selection with `nil`.
    func select(_ id: ConversationID?) {
        if let id {
            conversation(for: id)
        }
        guard selectedConversationID != id else { return }
        selectedConversationID = id
    }

    /// Switches the active public channel. While no private chat is open
    /// the selection follows the channel.
    func setActiveChannel(_ channelID: ChannelID) {
        if activeChannel != channelID {
            activeChannel = channelID
        }
        refreshDerivedSelection()
    }

    /// Opens a private chat (`nil` closes it, returning the selection to the
    /// active public channel's conversation).
    func setSelectedPrivatePeer(_ peerID: PeerID?) {
        if selectedPrivatePeerID != peerID {
            selectedPrivatePeerID = peerID
        }
        refreshDerivedSelection()
    }

    private func refreshDerivedSelection() {
        if let peerID = selectedPrivatePeerID {
            select(.directPeer(peerID))
        } else {
            select(ConversationID(channelID: activeChannel))
        }
    }

    /// Moves all messages from `source` into `destination` (the
    /// ephemeral↔stable peer-ID handoff): dedups by message ID, preserves
    /// timestamp order, carries unread state over, and hands off the
    /// selection — mirroring `ChatPrivateConversationCoordinator`'s
    /// migration semantics. The source conversation is removed. Emits a
    /// single `.migrated(from:to:)` once the whole move is consistent.
    func migrateConversation(from source: ConversationID, to destination: ConversationID) {
        guard source != destination, let sourceConversation = conversationsByID[source] else { return }

        let destinationConversation = conversation(for: destination)
        for message in sourceConversation.messages {
            let result = destinationConversation.insert(message)
            guard result.inserted else { continue }
            registerMessageID(message.id, in: destination)
            unregisterMessageIDs(result.trimmedMessageIDs, from: destination)
        }
        for messageID in sourceConversation.messageIDs {
            unregisterMessageID(messageID, from: source)
        }

        let wasUnread = unreadConversations.contains(source)
        let wasSelected = selectedConversationID == source

        conversationsByID.removeValue(forKey: source)
        conversationIDs.removeAll { $0 == source }
        unreadConversations.remove(source)

        if wasUnread, !unreadConversations.contains(destination) {
            unreadConversations.insert(destination)
            destinationConversation.setUnread(true)
        }
        if wasSelected {
            selectedConversationID = destination
            // Keep the private-peer selection axis consistent with the
            // handed-off selection.
            if let peerID = selectedPrivatePeerID,
               source == .directPeer(peerID),
               case .direct(let destinationHandle) = destination {
                selectedPrivatePeerID = destinationHandle.routingPeerID
            }
        }

        changes.send(.migrated(from: source, to: destination))
    }

    /// Removes a single message by ID from a conversation. Returns the
    /// removed message, or `nil` (emitting nothing) when the conversation or
    /// message is unknown.
    @discardableResult
    func removeMessage(withID messageID: String, from id: ConversationID) -> BitchatMessage? {
        guard let conversation = conversationsByID[id],
              let removed = conversation.remove(messageID: messageID) else {
            return nil
        }
        unregisterMessageID(messageID, from: id)
        changes.send(.messageRemoved(id, messageID: messageID))
        return removed
    }

    /// Removes every message matching `predicate` from a conversation,
    /// emitting one `.messageRemoved` per removed message after the
    /// conversation is consistent. No-op for unknown conversations.
    func removeMessages(from id: ConversationID, where predicate: (BitchatMessage) -> Bool) {
        guard let conversation = conversationsByID[id] else { return }
        let removedIDs = conversation.removeAll(where: predicate)
        unregisterMessageIDs(removedIDs, from: id)
        for messageID in removedIDs {
            changes.send(.messageRemoved(id, messageID: messageID))
        }
    }

    /// Empties a conversation's timeline but keeps the conversation (and
    /// its unread/selection state) alive.
    func clear(_ id: ConversationID) {
        guard let conversation = conversationsByID[id] else { return }
        for messageID in conversation.messageIDs {
            unregisterMessageID(messageID, from: id)
        }
        conversation.clearMessages()
        changes.send(.cleared(id))
    }

    /// Removes a conversation entirely, including unread state; clears the
    /// selection if it pointed at the removed conversation.
    func removeConversation(_ id: ConversationID) {
        guard let conversation = conversationsByID.removeValue(forKey: id) else { return }
        for messageID in conversation.messageIDs {
            unregisterMessageID(messageID, from: id)
        }
        conversationIDs.removeAll { $0 == id }
        unreadConversations.remove(id)
        if selectedConversationID == id {
            selectedConversationID = nil
        }
        changes.send(.removed(id))
    }

    func clearAll() {
        let removedIDs = conversationIDs
        guard !removedIDs.isEmpty || selectedConversationID != nil else { return }

        conversationsByID.removeAll()
        conversationIDs.removeAll()
        unreadConversations.removeAll()
        conversationIDsByMessageID.removeAll()
        if selectedConversationID != nil {
            selectedConversationID = nil
        }

        for id in removedIDs {
            changes.send(.removed(id))
        }
    }

    // MARK: Diagnostics

    /// Total messages across all conversations. O(#conversations) — heartbeat
    /// logging only, never a hot path.
    var totalMessageCount: Int {
        conversationsByID.values.reduce(0) { $0 + $1.messages.count }
    }

    /// Number of distinct message IDs in the store-level membership map.
    var messageIDMapCount: Int {
        conversationIDsByMessageID.count
    }

    /// Verifies the store's correctness invariants and returns human-readable
    /// violations (empty = healthy). Intended for a periodic field audit:
    /// O(total messages) and allocation-free while healthy. Checks:
    /// - the `conversationIDs` ordering array matches `conversationsByID`
    /// - per conversation: ID index exact, cap held, timestamp order
    ///   (see `Conversation.collectInvariantViolations`)
    /// - the message-ID → conversation map matches reality exactly: every
    ///   mapped membership points at a live conversation actually holding
    ///   the message, and total memberships equal total messages (with the
    ///   forward check, equality proves no conversation message is missing
    ///   from the map)
    /// - `unreadConversations` only references existing conversations
    /// - `selectedConversationID`, when set, references an existing
    ///   conversation (`select(_:)` creates on selection and
    ///   `removeConversation`/`clearAll` clear it, so existence is the
    ///   invariant for both the channel-derived and direct-peer cases)
    func auditInvariants() -> [String] {
        var violations: [String] = []

        if conversationIDs.count != conversationsByID.count {
            violations.append("conversationIDs lists \(conversationIDs.count) conversations but dictionary holds \(conversationsByID.count)")
        }
        for id in conversationIDs where conversationsByID[id] == nil {
            violations.append("conversationIDs lists \(id.auditDescription) but no conversation exists")
        }

        var totalMessages = 0
        for (id, conversation) in conversationsByID {
            totalMessages += conversation.messages.count
            conversation.collectInvariantViolations(into: &violations, label: id.auditDescription)
        }

        var totalMappedMemberships = 0
        for (messageID, ids) in conversationIDsByMessageID {
            totalMappedMemberships += ids.count
            if ids.isEmpty {
                violations.append("message map: \(messageID.prefix(8))… has an empty membership set")
            }
            for id in ids {
                guard let conversation = conversationsByID[id] else {
                    violations.append("message map: \(messageID.prefix(8))… claims unknown conversation \(id.auditDescription)")
                    continue
                }
                if !conversation.containsMessage(withID: messageID) {
                    violations.append("message map: \(messageID.prefix(8))… not present in claimed conversation \(id.auditDescription)")
                }
            }
        }
        if totalMappedMemberships != totalMessages {
            violations.append("message map holds \(totalMappedMemberships) memberships but conversations hold \(totalMessages) messages")
        }

        for id in unreadConversations where conversationsByID[id] == nil {
            violations.append("unreadConversations contains unknown conversation \(id.auditDescription)")
        }

        if let selected = selectedConversationID, conversationsByID[selected] == nil {
            violations.append("selectedConversationID \(selected.auditDescription) has no conversation")
        }

        return violations
    }

    // MARK: Internals

    private func registerMessageID(_ messageID: String, in id: ConversationID) {
        conversationIDsByMessageID[messageID, default: []].insert(id)
        // Single choke point for every successful insertion (append, upsert
        // append, migration insert) — the audit heartbeat's throughput delta.
        appendCount += 1
    }

    private func unregisterMessageID(_ messageID: String, from id: ConversationID) {
        guard var ids = conversationIDsByMessageID[messageID] else { return }
        ids.remove(id)
        if ids.isEmpty {
            conversationIDsByMessageID.removeValue(forKey: messageID)
        } else {
            conversationIDsByMessageID[messageID] = ids
        }
    }

    private func unregisterMessageIDs(_ messageIDs: [String], from id: ConversationID) {
        for messageID in messageIDs {
            unregisterMessageID(messageID, from: id)
        }
    }

    private static func cap(for id: ConversationID) -> Int {
        switch id {
        case .mesh:
            return TransportConfig.meshTimelineCap
        case .geohash:
            return TransportConfig.geoTimelineCap
        case .direct:
            return TransportConfig.privateChatCap
        }
    }
}

// MARK: - Direct-conversation keying + derived views

extension ConversationID {
    /// Direct-conversation ID keyed by the *raw* routing peer ID.
    ///
    /// Direct conversations are deliberately keyed per `PeerID`, not per
    /// resolved identity: the private-chat coordinators mirror messages into
    /// both the ephemeral and stable peer's conversations
    /// (`mirrorToEphemeralIfNeeded`) and consolidate/migrate between them
    /// explicitly, so a raw lookup by whichever peer ID is selected always
    /// finds the right timeline without an identity-resolution layer.
    static func directPeer(_ peerID: PeerID) -> ConversationID {
        .direct(PeerHandle(id: "peer:\(peerID.id)", routingPeerID: peerID))
    }
}

extension ConversationStore {
    /// All direct conversations' messages keyed by routing peer ID — the
    /// shape `ChatViewModel.privateChats` exposes to the coordinators.
    /// Values are the conversations' backing arrays (COW), so building this
    /// is O(#conversations), not O(#messages).
    func directMessagesByRoutingPeerID() -> [PeerID: [BitchatMessage]] {
        var messagesByPeerID: [PeerID: [BitchatMessage]] = [:]
        messagesByPeerID.reserveCapacity(conversationsByID.count)
        for (id, conversation) in conversationsByID {
            guard case .direct(let handle) = id else { continue }
            messagesByPeerID[handle.routingPeerID] = conversation.messages
        }
        return messagesByPeerID
    }

    /// Unread direct conversations as routing peer IDs — the shape
    /// `ChatViewModel.unreadPrivateMessages` exposes to the coordinators.
    func unreadDirectRoutingPeerIDs() -> Set<PeerID> {
        var peerIDs = Set<PeerID>()
        for id in unreadConversations {
            guard case .direct(let handle) = id else { continue }
            peerIDs.insert(handle.routingPeerID)
        }
        return peerIDs
    }

    /// `true` when any direct conversation contains a message with `messageID`
    /// (O(1) via the store-level message-ID → conversation map).
    func directConversationsContainMessage(withID messageID: String) -> Bool {
        conversationIDs(forMessageID: messageID).contains { id in
            if case .direct = id { return true }
            return false
        }
    }

    /// Message IDs across all direct conversations (read-receipt pruning
    /// keeps only receipts whose messages still exist).
    func directMessageIDs() -> Set<String> {
        var messageIDs = Set<String>()
        for (id, conversation) in conversationsByID {
            guard case .direct = id else { continue }
            messageIDs.formUnion(conversation.messageIDs)
        }
        return messageIDs
    }

}

// MARK: - Diagnostics support

extension ConversationID {
    /// Short, log-safe description for audit/diagnostic lines. Direct
    /// conversations truncate the handle so full peer keys never hit logs.
    fileprivate var auditDescription: String {
        switch self {
        case .mesh:
            return "mesh"
        case .geohash(let geohash):
            return "geo:\(geohash)"
        case .direct(let handle):
            return "direct:\(handle.id.prefix(13))…"
        }
    }
}

#if DEBUG
// Test-only corruption hooks for `auditInvariants()` tests. The store is the
// sole writer by design — `Conversation`'s mutators are fileprivate and the
// store's backing collections are private — so the inconsistent states the
// audit exists to catch CANNOT be manufactured through the intent API. These
// DEBUG-only hooks deliberately bypass that lockdown to inject exactly those
// impossible states. Never call them outside tests.
extension Conversation {
    /// Points an existing message's index entry at the wrong position
    /// (positions 0 and 1 swap their index entries). Requires >= 2 messages.
    func _testCorruptIndexEntries() {
        guard messages.count >= 2 else { return }
        indexByMessageID[messages[0].id] = 1
        indexByMessageID[messages[1].id] = 0
    }

    /// Drops a message's index entry entirely (count mismatch + missing).
    func _testRemoveIndexEntry(forMessageID messageID: String) {
        indexByMessageID.removeValue(forKey: messageID)
    }

    /// Swaps the first and last messages while keeping the index consistent,
    /// so ONLY the timestamp-order invariant is violated (requires the two
    /// messages to have distinct timestamps).
    func _testCorruptOrderingPreservingIndex() {
        guard messages.count >= 2 else { return }
        messages.swapAt(0, messages.count - 1)
        indexByMessageID[messages[0].id] = 0
        indexByMessageID[messages[messages.count - 1].id] = messages.count - 1
    }
}

extension ConversationStore {
    /// Adds a map membership that the conversation does not actually hold.
    func _testRegisterPhantomMessageID(_ messageID: String, in id: ConversationID) {
        conversationIDsByMessageID[messageID, default: []].insert(id)
    }

    /// Drops a real map membership (conversation message missing from map).
    func _testUnregisterMessageID(_ messageID: String, from id: ConversationID) {
        conversationIDsByMessageID[messageID]?.remove(id)
        if conversationIDsByMessageID[messageID]?.isEmpty == true {
            conversationIDsByMessageID.removeValue(forKey: messageID)
        }
    }

    /// Appends past the conversation cap, bypassing trim (map kept exact so
    /// only the cap invariant is violated).
    func _testAppendBypassingCap(_ message: BitchatMessage, to id: ConversationID) {
        let conversation = conversation(for: id)
        conversation._testAppendBypassingTrim(message)
        conversationIDsByMessageID[message.id, default: []].insert(id)
    }

    /// Marks a nonexistent conversation unread without creating it.
    func _testInsertUnreadConversationID(_ id: ConversationID) {
        unreadConversations.insert(id)
    }

    /// Sets the selection directly, without `select(_:)`'s create-on-select.
    func _testSetSelectedConversationID(_ id: ConversationID?) {
        selectedConversationID = id
    }
}

extension Conversation {
    fileprivate func _testAppendBypassingTrim(_ message: BitchatMessage) {
        messages.append(message)
        indexByMessageID[message.id] = messages.count - 1
    }
}
#endif

// MARK: - Public timeline derived views

extension ConversationStore {
    /// Removes a message by ID from whichever public (mesh/geohash)
    /// conversation contains it. Returns the removed message, if any.
    @discardableResult
    func removePublicMessage(withID messageID: String) -> BitchatMessage? {
        for id in conversationIDs(forMessageID: messageID) {
            switch id {
            case .mesh, .geohash:
                return removeMessage(withID: messageID, from: id)
            case .direct:
                continue
            }
        }
        return nil
    }
}
