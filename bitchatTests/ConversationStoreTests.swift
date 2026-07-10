//
// ConversationStoreTests.swift
// bitchatTests
//
// Tests for the new single-source-of-truth ConversationStore
// (docs/CONVERSATION-STORE-DESIGN.md): intent API, ordered insertion,
// dedup, caps, delivery-status rules, migration, unread state, change
// emission, and per-conversation publish isolation.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Combine
import Foundation
import Testing
@testable import bitchat

@MainActor
private func makeMessage(
    id: String,
    timestamp: TimeInterval,
    content: String? = nil,
    isPrivate: Bool = false,
    deliveryStatus: DeliveryStatus? = nil
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "alice",
        content: content ?? "message \(id)",
        timestamp: Date(timeIntervalSince1970: timestamp),
        isRelay: false,
        isPrivate: isPrivate,
        recipientNickname: isPrivate ? "bob" : nil,
        senderPeerID: PeerID(str: "peer-a"),
        deliveryStatus: deliveryStatus
    )
}

private func makeDirectConversationID(_ suffix: String) -> ConversationID {
    .direct(PeerHandle(
        id: "noise:\(suffix)",
        routingPeerID: PeerID(str: "peer-\(suffix)")
    ))
}

@Suite("ConversationStore")
struct ConversationStoreTests {

    // MARK: - Append, dedup, ordering

    @Test("append dedups by message ID and reports duplicates")
    @MainActor
    func appendDedupsByMessageID() {
        let store = ConversationStore()
        var received: [ConversationChange] = []
        let cancellable = store.changes.sink { received.append($0) }
        defer { cancellable.cancel() }

        #expect(store.append(makeMessage(id: "m1", timestamp: 1), to: .mesh))
        #expect(!store.append(makeMessage(id: "m1", timestamp: 2, content: "dup"), to: .mesh))

        let conversation = store.conversation(for: .mesh)
        #expect(conversation.messages.count == 1)
        #expect(conversation.messages.first?.content == "message m1")
        #expect(conversation.containsMessage(withID: "m1"))
        #expect(received.count == 1)
        guard case .appended(.mesh, let message) = received.first else {
            Issue.record("expected a single .appended change, got \(received)")
            return
        }
        #expect(message.id == "m1")
    }

    @Test("out-of-order appends are inserted in timestamp order")
    @MainActor
    func outOfOrderInsertKeepsTimestampOrder() {
        let store = ConversationStore()

        store.append(makeMessage(id: "m1", timestamp: 10), to: .mesh)
        store.append(makeMessage(id: "m3", timestamp: 30), to: .mesh)
        store.append(makeMessage(id: "m2", timestamp: 20), to: .mesh)
        store.append(makeMessage(id: "m0", timestamp: 5), to: .mesh)

        let conversation = store.conversation(for: .mesh)
        #expect(conversation.messages.map(\.id) == ["m0", "m1", "m2", "m3"])

        // The ID index must survive middle inserts: lookups by ID still
        // resolve to the right message.
        #expect(conversation.message(withID: "m2")?.timestamp == Date(timeIntervalSince1970: 20))
        #expect(conversation.message(withID: "m0")?.timestamp == Date(timeIntervalSince1970: 5))
    }

    @Test("equal timestamps preserve arrival order")
    @MainActor
    func equalTimestampsPreserveArrivalOrder() {
        let store = ConversationStore()

        store.append(makeMessage(id: "first", timestamp: 10), to: .mesh)
        store.append(makeMessage(id: "second", timestamp: 10), to: .mesh)
        // A late message with an equal timestamp lands after existing peers.
        store.append(makeMessage(id: "late-tail", timestamp: 20), to: .mesh)
        store.append(makeMessage(id: "third", timestamp: 10), to: .mesh)

        let conversation = store.conversation(for: .mesh)
        #expect(conversation.messages.map(\.id) == ["first", "second", "third", "late-tail"])
    }

    // MARK: - Caps

    @Test("cap trims oldest messages and keeps the ID index valid")
    @MainActor
    func capTrimsOldestAndKeepsIndexValid() {
        let store = ConversationStore()
        let conversation = store.conversation(for: .mesh)
        let cap = conversation.cap
        #expect(cap == TransportConfig.meshTimelineCap)

        let overflow = 3
        for i in 0..<(cap + overflow) {
            store.append(makeMessage(id: "m\(i)", timestamp: TimeInterval(i)), to: .mesh)
        }

        #expect(conversation.messages.count == cap)
        #expect(conversation.messages.first?.id == "m\(overflow)")
        #expect(conversation.messages.last?.id == "m\(cap + overflow - 1)")

        // Trimmed messages left the index entirely…
        for i in 0..<overflow {
            #expect(!conversation.containsMessage(withID: "m\(i)"))
        }
        // …and re-appending a trimmed ID is allowed (no stale index entry).
        #expect(store.append(makeMessage(id: "m0", timestamp: TimeInterval(cap + overflow)), to: .mesh))

        // Surviving entries still resolve correctly after the trim reindex.
        let probeID = "m\(cap / 2 + overflow)"
        #expect(conversation.message(withID: probeID)?.id == probeID)
        #expect(store.setDeliveryStatus(.sent, forMessageID: probeID, in: .mesh))
        #expect(conversation.message(withID: probeID)?.deliveryStatus == .sent)
    }

    // MARK: - Upsert

    @Test("upsertByID replaces in place and appends when absent")
    @MainActor
    func upsertReplacesOrAppends() {
        let store = ConversationStore()
        var received: [ConversationChange] = []
        let cancellable = store.changes.sink { received.append($0) }
        defer { cancellable.cancel() }

        store.upsertByID(makeMessage(id: "m1", timestamp: 10), in: .mesh)
        store.append(makeMessage(id: "m2", timestamp: 20), to: .mesh)
        store.upsertByID(makeMessage(id: "m1", timestamp: 10, content: "edited"), in: .mesh)

        let conversation = store.conversation(for: .mesh)
        #expect(conversation.messages.map(\.id) == ["m1", "m2"])
        #expect(conversation.message(withID: "m1")?.content == "edited")

        #expect(received.count == 3)
        guard case .appended(.mesh, let first) = received[0], first.id == "m1",
              case .appended(.mesh, let second) = received[1], second.id == "m2",
              case .updated(.mesh, let updatedID) = received[2], updatedID == "m1" else {
            Issue.record("unexpected change sequence: \(received)")
            return
        }
    }

    // MARK: - Delivery status

    @Test("setDeliveryStatus never downgrades read and skips equal statuses")
    @MainActor
    func deliveryStatusNoDowngrade() {
        let store = ConversationStore()
        let id = makeDirectConversationID("aa")
        store.append(makeMessage(id: "m1", timestamp: 1, isPrivate: true, deliveryStatus: .sending), to: id)
        var statusChanges: [DeliveryStatus] = []
        let cancellable = store.changes.sink { change in
            if case .statusChanged(_, _, let status) = change {
                statusChanges.append(status)
            }
        }
        defer { cancellable.cancel() }

        let conversation = store.conversation(for: id)
        let readStatus = DeliveryStatus.read(by: "bob", at: Date(timeIntervalSince1970: 100))

        #expect(store.setDeliveryStatus(.sent, forMessageID: "m1", in: id))
        // Equal status is a no-op.
        #expect(!store.setDeliveryStatus(.sent, forMessageID: "m1", in: id))
        #expect(store.setDeliveryStatus(readStatus, forMessageID: "m1", in: id))
        // Read beats delivered and sent: both downgrades are refused.
        #expect(!store.setDeliveryStatus(.delivered(to: "bob", at: Date()), forMessageID: "m1", in: id))
        #expect(!store.setDeliveryStatus(.sent, forMessageID: "m1", in: id))
        #expect(conversation.message(withID: "m1")?.deliveryStatus == readStatus)

        // Unknown message or conversation: refused, nothing emitted.
        #expect(!store.setDeliveryStatus(.sent, forMessageID: "nope", in: id))
        #expect(!store.setDeliveryStatus(.sent, forMessageID: "m1", in: .mesh))

        #expect(statusChanges == [.sent, readStatus])
    }

    // MARK: - Unread state

    @Test("markUnread and markRead keep the set and conversation flag consistent")
    @MainActor
    func unreadStateConsistency() {
        let store = ConversationStore()
        let id = makeDirectConversationID("bb")
        var unreadChanges: [(ConversationID, Bool)] = []
        let cancellable = store.changes.sink { change in
            if case .unreadChanged(let conversationID, let isUnread) = change {
                unreadChanges.append((conversationID, isUnread))
            }
        }
        defer { cancellable.cancel() }

        // markRead on a never-unread conversation is a no-op.
        store.markRead(id)
        #expect(unreadChanges.isEmpty)

        store.markUnread(id)
        #expect(store.unreadConversations == [id])
        #expect(store.conversation(for: id).isUnread)
        // Idempotent: marking unread twice emits once.
        store.markUnread(id)

        store.markRead(id)
        #expect(store.unreadConversations.isEmpty)
        #expect(!store.conversation(for: id).isUnread)

        #expect(unreadChanges.count == 2)
        #expect(unreadChanges[0].0 == id && unreadChanges[0].1 == true)
        #expect(unreadChanges[1].0 == id && unreadChanges[1].1 == false)
    }

    // MARK: - Selection

    @Test("select creates the conversation and clears with nil")
    @MainActor
    func selectTracksConversation() {
        let store = ConversationStore()
        let id = makeDirectConversationID("cc")

        store.select(id)
        #expect(store.selectedConversationID == id)
        #expect(store.conversationsByID[id] != nil)
        #expect(store.conversationIDs == [id])

        store.select(nil)
        #expect(store.selectedConversationID == nil)
    }

    // MARK: - Migration

    @Test("migrateConversation moves messages, dedups, and preserves order")
    @MainActor
    func migrationMovesAndDedups() {
        let store = ConversationStore()
        let ephemeral = makeDirectConversationID("old")
        let stable = makeDirectConversationID("new")

        store.append(makeMessage(id: "m1", timestamp: 10), to: ephemeral)
        store.append(makeMessage(id: "m3", timestamp: 30), to: ephemeral)
        store.append(makeMessage(id: "m2", timestamp: 20), to: stable)
        store.append(makeMessage(id: "m3", timestamp: 30, content: "already there"), to: stable)

        var received: [ConversationChange] = []
        let cancellable = store.changes.sink { received.append($0) }
        defer { cancellable.cancel() }

        store.migrateConversation(from: ephemeral, to: stable)

        let destination = store.conversation(for: stable)
        #expect(destination.messages.map(\.id) == ["m1", "m2", "m3"])
        // Existing copy wins the dedup.
        #expect(destination.message(withID: "m3")?.content == "already there")
        #expect(store.conversationsByID[ephemeral] == nil)
        #expect(!store.conversationIDs.contains(ephemeral))

        #expect(received.count == 1)
        guard case .migrated(let from, let to) = received.first, from == ephemeral, to == stable else {
            Issue.record("expected a single .migrated change, got \(received)")
            return
        }
    }

    @Test("migrateConversation hands off unread state and selection")
    @MainActor
    func migrationMovesUnreadAndSelection() {
        let store = ConversationStore()
        let ephemeral = makeDirectConversationID("old")
        let stable = makeDirectConversationID("new")

        store.append(makeMessage(id: "m1", timestamp: 10), to: ephemeral)
        store.markUnread(ephemeral)
        store.select(ephemeral)

        store.migrateConversation(from: ephemeral, to: stable)

        #expect(store.unreadConversations == [stable])
        #expect(store.conversation(for: stable).isUnread)
        #expect(store.selectedConversationID == stable)

        // Migrating from a missing source or onto itself is a no-op.
        store.migrateConversation(from: ephemeral, to: stable)
        store.migrateConversation(from: stable, to: stable)
        #expect(store.conversation(for: stable).messages.map(\.id) == ["m1"])
    }

    // MARK: - Clear / remove

    @Test("clear empties the timeline but keeps the conversation")
    @MainActor
    func clearKeepsConversation() {
        let store = ConversationStore()
        let id = makeDirectConversationID("dd")
        store.append(makeMessage(id: "m1", timestamp: 1), to: id)
        store.markUnread(id)
        var received: [ConversationChange] = []
        let cancellable = store.changes.sink { received.append($0) }
        defer { cancellable.cancel() }

        store.clear(id)

        let conversation = store.conversation(for: id)
        #expect(conversation.messages.isEmpty)
        #expect(!conversation.containsMessage(withID: "m1"))
        #expect(store.conversationIDs.contains(id))
        #expect(store.unreadConversations.contains(id))
        // The ID index was cleared too: the same message can return.
        #expect(store.append(makeMessage(id: "m1", timestamp: 2), to: id))

        guard case .cleared(id) = received.first else {
            Issue.record("expected .cleared first, got \(received)")
            return
        }
    }

    @Test("removeConversation drops messages, unread state, and selection")
    @MainActor
    func removeConversationDropsEverything() {
        let store = ConversationStore()
        let id = makeDirectConversationID("ee")
        store.append(makeMessage(id: "m1", timestamp: 1), to: id)
        store.markUnread(id)
        store.select(id)
        var received: [ConversationChange] = []
        let cancellable = store.changes.sink { received.append($0) }
        defer { cancellable.cancel() }

        store.removeConversation(id)

        #expect(store.conversationsByID[id] == nil)
        #expect(store.conversationIDs.isEmpty)
        #expect(store.unreadConversations.isEmpty)
        #expect(store.selectedConversationID == nil)
        #expect(received.count == 1)
        guard case .removed(id) = received.first else {
            Issue.record("expected .removed, got \(received)")
            return
        }

        // Removing again is a no-op.
        store.removeConversation(id)
        #expect(received.count == 1)
    }

    @Test("clearAll removes every conversation and emits removals")
    @MainActor
    func clearAllRemovesEverything() {
        let store = ConversationStore()
        let direct = makeDirectConversationID("ff")
        store.append(makeMessage(id: "m1", timestamp: 1), to: .mesh)
        store.append(makeMessage(id: "m2", timestamp: 2), to: direct)
        store.markUnread(direct)
        store.select(direct)
        var removed: [ConversationID] = []
        let cancellable = store.changes.sink { change in
            if case .removed(let id) = change { removed.append(id) }
        }
        defer { cancellable.cancel() }

        store.clearAll()

        #expect(store.conversationsByID.isEmpty)
        #expect(store.conversationIDs.isEmpty)
        #expect(store.unreadConversations.isEmpty)
        #expect(store.selectedConversationID == nil)
        #expect(removed == [.mesh, direct])
    }

    // MARK: - Change emission

    @Test("changes are emitted after state is consistent")
    @MainActor
    func changesEmittedAfterStateIsConsistent() {
        let store = ConversationStore()
        var observedCountsAtEmission: [Int] = []
        var observedUnreadAtEmission: [Bool] = []
        let cancellable = store.changes.sink { change in
            switch change {
            case .appended(let id, let message):
                // The appended message must already be visible at emission.
                observedCountsAtEmission.append(store.conversation(for: id).messages.count)
                #expect(store.conversation(for: id).containsMessage(withID: message.id))
            case .unreadChanged(let id, let isUnread):
                #expect(store.unreadConversations.contains(id) == isUnread)
                observedUnreadAtEmission.append(isUnread)
            default:
                break
            }
        }
        defer { cancellable.cancel() }

        store.append(makeMessage(id: "m1", timestamp: 1), to: .mesh)
        store.append(makeMessage(id: "m2", timestamp: 2), to: .mesh)
        store.markUnread(.mesh)
        store.markRead(.mesh)

        #expect(observedCountsAtEmission == [1, 2])
        #expect(observedUnreadAtEmission == [true, false])
    }

    @Test("cap policy follows the conversation kind")
    @MainActor
    func capPolicyByKind() {
        let store = ConversationStore()
        #expect(store.conversation(for: .mesh).cap == TransportConfig.meshTimelineCap)
        #expect(store.conversation(for: .geohash("u4pruyd")).cap == TransportConfig.geoTimelineCap)
        #expect(store.conversation(for: makeDirectConversationID("gg")).cap == TransportConfig.privateChatCap)
    }

    // MARK: - Publish isolation

    @Test("appending to one conversation does not publish another")
    @MainActor
    func perConversationPublishIsolation() {
        let store = ConversationStore()
        let a = makeDirectConversationID("aa")
        let b = makeDirectConversationID("bb")
        let conversationA = store.conversation(for: a)
        let conversationB = store.conversation(for: b)

        var aWillChangeCount = 0
        var bWillChangeCount = 0
        var cancellables = Set<AnyCancellable>()
        conversationA.objectWillChange
            .sink { aWillChangeCount += 1 }
            .store(in: &cancellables)
        conversationB.objectWillChange
            .sink { bWillChangeCount += 1 }
            .store(in: &cancellables)

        store.append(makeMessage(id: "m1", timestamp: 1), to: a)
        store.append(makeMessage(id: "m2", timestamp: 2), to: a)
        store.setDeliveryStatus(.sent, forMessageID: "m1", in: a)
        store.markUnread(a)

        #expect(aWillChangeCount >= 4)
        #expect(bWillChangeCount == 0)

        store.append(makeMessage(id: "m3", timestamp: 3), to: b)
        #expect(bWillChangeCount > 0)
    }

    // MARK: - Public timelines (mesh/geohash, ex-PublicTimelineStore behavior)

    @Test("geohash conversations are separated by geohash and from mesh")
    @MainActor
    func geohashConversationSeparation() {
        let store = ConversationStore()
        store.append(makeMessage(id: "mesh-1", timestamp: 1), to: .mesh)
        store.append(makeMessage(id: "geo-a-1", timestamp: 2), to: .geohash("u4pruyd"))
        store.append(makeMessage(id: "geo-b-1", timestamp: 3), to: .geohash("9q8yy"))

        #expect(store.conversation(for: .mesh).messages.map(\.id) == ["mesh-1"])
        #expect(store.conversation(for: .geohash("u4pruyd")).messages.map(\.id) == ["geo-a-1"])
        #expect(store.conversation(for: .geohash("9q8yy")).messages.map(\.id) == ["geo-b-1"])
    }

    @Test("geohash append dedups by ID and reports duplicates")
    @MainActor
    func geohashAppendIfAbsentContract() {
        let store = ConversationStore()
        let message = makeMessage(id: "geo-1", timestamp: 1)

        #expect(store.append(message, to: .geohash("u4pruyd")))
        #expect(!store.append(message, to: .geohash("u4pruyd")))
        // The same ID is still fresh in a different geohash.
        #expect(store.append(message, to: .geohash("9q8yy")))
    }

    @Test("removePublicMessage searches mesh and geohash conversations only")
    @MainActor
    func removePublicMessageSearchesPublicConversations() {
        let store = ConversationStore()
        let direct = makeDirectConversationID("aa")
        store.append(makeMessage(id: "mesh-1", timestamp: 1), to: .mesh)
        store.append(makeMessage(id: "geo-1", timestamp: 2), to: .geohash("u4pruyd"))
        store.append(makeMessage(id: "dm-1", timestamp: 3, isPrivate: true), to: direct)

        #expect(store.removePublicMessage(withID: "geo-1")?.id == "geo-1")
        #expect(store.conversation(for: .geohash("u4pruyd")).messages.isEmpty)

        #expect(store.removePublicMessage(withID: "mesh-1")?.id == "mesh-1")
        #expect(store.conversation(for: .mesh).messages.isEmpty)

        // Direct conversations are never touched.
        #expect(store.removePublicMessage(withID: "dm-1") == nil)
        #expect(store.conversation(for: direct).messages.map(\.id) == ["dm-1"])
    }

    @Test("removeMessages(from:where:) purges matches and emits per removal")
    @MainActor
    func removeMessagesByPredicate() {
        let store = ConversationStore()
        let id = ConversationID.geohash("u4pruyd")
        store.append(makeMessage(id: "keep-1", timestamp: 1), to: id)
        store.append(makeMessage(id: "drop-1", timestamp: 2, content: "purge me"), to: id)
        store.append(makeMessage(id: "drop-2", timestamp: 3, content: "purge me"), to: id)
        store.append(makeMessage(id: "keep-2", timestamp: 4), to: id)

        var removedIDs: [String] = []
        var cancellables = Set<AnyCancellable>()
        store.changes
            .sink { change in
                if case .messageRemoved(_, let messageID) = change {
                    removedIDs.append(messageID)
                }
            }
            .store(in: &cancellables)

        store.removeMessages(from: id, where: { $0.content == "purge me" })

        #expect(store.conversation(for: id).messages.map(\.id) == ["keep-1", "keep-2"])
        #expect(removedIDs == ["drop-1", "drop-2"])
        // The ID index survives the purge: dedup and removal still work.
        #expect(!store.append(makeMessage(id: "keep-2", timestamp: 4), to: id))
        #expect(store.removeMessage(withID: "keep-1", from: id) != nil)
        #expect(store.conversation(for: id).messages.map(\.id) == ["keep-2"])
    }

    @Test("trimmed public message IDs can return after falling off the cap")
    @MainActor
    func trimmedMessageIDsCanReturn() {
        let store = ConversationStore()
        let id = ConversationID.geohash("u4pruyd")
        let conversation = store.conversation(for: id)
        let first = makeMessage(id: "one", timestamp: 1)

        store.append(first, to: id)
        for index in 0..<conversation.cap {
            store.append(makeMessage(id: "filler-\(index)", timestamp: 2 + TimeInterval(index)), to: id)
        }
        // "one" was trimmed by the cap, so its ID is free again.
        #expect(!conversation.containsMessage(withID: "one"))
        #expect(store.append(makeMessage(id: "one", timestamp: 2000), to: id))
    }

    // MARK: - Store-level message-ID → conversation map (ID-only delivery)

    @Test("ID map tracks append, upsert, and removal")
    @MainActor
    func messageIDMapTracksAppendAndRemoval() {
        let store = ConversationStore()
        let direct = makeDirectConversationID("aa")

        #expect(store.conversationIDs(forMessageID: "m1").isEmpty)

        store.append(makeMessage(id: "m1", timestamp: 1), to: .mesh)
        #expect(store.conversationIDs(forMessageID: "m1") == [.mesh])

        // Upsert-as-append registers; upsert-in-place does not duplicate.
        store.upsertByID(makeMessage(id: "d1", timestamp: 1, isPrivate: true), in: direct)
        store.upsertByID(makeMessage(id: "d1", timestamp: 1, isPrivate: true, deliveryStatus: .sent), in: direct)
        #expect(store.conversationIDs(forMessageID: "d1") == [direct])

        store.removeMessage(withID: "m1", from: .mesh)
        #expect(store.conversationIDs(forMessageID: "m1").isEmpty)

        store.removeMessages(from: direct, where: { $0.id == "d1" })
        #expect(store.conversationIDs(forMessageID: "d1").isEmpty)
    }

    @Test("ID map handles multi-conversation membership (mirrored private copies)")
    @MainActor
    func messageIDMapHandlesMirroredCopies() {
        let store = ConversationStore()
        let stable = makeDirectConversationID("stable")
        let ephemeral = makeDirectConversationID("ephemeral")

        // Step 2's keying mirrors one private message into the stable-key
        // AND ephemeral-peer conversations (distinct copies here to prove
        // per-conversation bookkeeping).
        store.upsertByID(makeMessage(id: "dm-1", timestamp: 1, isPrivate: true, deliveryStatus: .sent), in: stable)
        store.upsertByID(makeMessage(id: "dm-1", timestamp: 1, isPrivate: true, deliveryStatus: .sent), in: ephemeral)
        #expect(store.conversationIDs(forMessageID: "dm-1") == [stable, ephemeral])

        // An ID-only delivery update reaches BOTH copies.
        #expect(store.setDeliveryStatus(.delivered(to: "bob", at: Date()), forMessageID: "dm-1"))
        for id in [stable, ephemeral] {
            guard case .delivered = store.conversation(for: id).message(withID: "dm-1")?.deliveryStatus else {
                Issue.record("expected .delivered in \(id)")
                return
            }
        }

        // Removing one copy keeps the other resolvable.
        store.removeMessage(withID: "dm-1", from: ephemeral)
        #expect(store.conversationIDs(forMessageID: "dm-1") == [stable])
    }

    @Test("ID-only setDeliveryStatus enforces no-downgrade and unknown IDs")
    @MainActor
    func idOnlyDeliveryStatusRules() {
        let store = ConversationStore()
        let direct = makeDirectConversationID("aa")
        store.append(
            makeMessage(id: "dm-1", timestamp: 1, isPrivate: true, deliveryStatus: .read(by: "bob", at: Date())),
            to: direct
        )

        // Unknown message.
        #expect(!store.setDeliveryStatus(.sent, forMessageID: "missing"))
        #expect(store.deliveryStatus(forMessageID: "missing") == nil)

        // Downgrade from .read is refused; status is readable by ID alone.
        #expect(!store.setDeliveryStatus(.delivered(to: "bob", at: Date()), forMessageID: "dm-1"))
        guard case .read = store.deliveryStatus(forMessageID: "dm-1") else {
            Issue.record("expected .read to survive the downgrade attempt")
            return
        }
    }

    @Test("ID map follows migration between conversations")
    @MainActor
    func messageIDMapFollowsMigration() {
        let store = ConversationStore()
        let source = makeDirectConversationID("ephemeral")
        let destination = makeDirectConversationID("stable")
        store.append(makeMessage(id: "dm-1", timestamp: 1, isPrivate: true), to: source)
        store.append(makeMessage(id: "dm-2", timestamp: 2, isPrivate: true), to: source)
        // Already present in the destination: migration dedups, and the map
        // must not retain a stale source membership.
        store.append(makeMessage(id: "dm-2", timestamp: 2, isPrivate: true), to: destination)

        store.migrateConversation(from: source, to: destination)

        #expect(store.conversationIDs(forMessageID: "dm-1") == [destination])
        #expect(store.conversationIDs(forMessageID: "dm-2") == [destination])
        // Delivery updates keep flowing after the handoff.
        #expect(store.setDeliveryStatus(.sent, forMessageID: "dm-1"))
    }

    @Test("ID map drops trimmed messages")
    @MainActor
    func messageIDMapDropsTrimmedMessages() {
        let store = ConversationStore()
        let id = ConversationID.geohash("u4pruyd")
        let conversation = store.conversation(for: id)
        store.append(makeMessage(id: "first", timestamp: 1), to: id)
        for index in 0..<conversation.cap {
            store.append(makeMessage(id: "filler-\(index)", timestamp: 2 + TimeInterval(index)), to: id)
        }

        // "first" fell off the cap: the map must forget it.
        #expect(store.conversationIDs(forMessageID: "first").isEmpty)
        #expect(!store.setDeliveryStatus(.sent, forMessageID: "first"))
        // Survivors stay resolvable.
        #expect(store.conversationIDs(forMessageID: "filler-0") == [id])
    }

    @Test("ID map is emptied by clear, removeConversation, and clearAll")
    @MainActor
    func messageIDMapClearedWithConversations() {
        let store = ConversationStore()
        let direct = makeDirectConversationID("aa")
        store.append(makeMessage(id: "m1", timestamp: 1), to: .mesh)
        store.append(makeMessage(id: "d1", timestamp: 1, isPrivate: true), to: direct)

        store.clear(.mesh)
        #expect(store.conversationIDs(forMessageID: "m1").isEmpty)
        #expect(store.conversationIDs(forMessageID: "d1") == [direct])

        store.removeConversation(direct)
        #expect(store.conversationIDs(forMessageID: "d1").isEmpty)

        store.append(makeMessage(id: "m2", timestamp: 2), to: .mesh)
        store.clearAll()
        #expect(store.conversationIDs(forMessageID: "m2").isEmpty)
    }

    @Test("shared message instance across conversations stays consistent")
    @MainActor
    func sharedInstanceMirroredCopiesStayConsistent() {
        let store = ConversationStore()
        let stable = makeDirectConversationID("stable")
        let ephemeral = makeDirectConversationID("ephemeral")
        // The production mirroring path upserts the SAME BitchatMessage
        // instance (reference type) into both conversations.
        let message = makeMessage(id: "dm-1", timestamp: 1, isPrivate: true, deliveryStatus: .sent)
        store.upsertByID(message, in: stable)
        store.upsertByID(message, in: ephemeral)

        #expect(store.setDeliveryStatus(.delivered(to: "bob", at: Date()), forMessageID: "dm-1"))

        for id in [stable, ephemeral] {
            guard case .delivered = store.conversation(for: id).message(withID: "dm-1")?.deliveryStatus else {
                Issue.record("expected .delivered in \(id)")
                return
            }
        }
    }

    @Test("mirrored conversations both republish and emit on a shared-instance status change")
    @MainActor
    func sharedInstanceMirroredCopiesBothRepublishOnStatusChange() {
        let store = ConversationStore()
        let stable = makeDirectConversationID("stable")
        let ephemeral = makeDirectConversationID("ephemeral")
        let message = makeMessage(id: "dm-2", timestamp: 1, isPrivate: true, deliveryStatus: .sent)
        store.upsertByID(message, in: stable)
        store.upsertByID(message, in: ephemeral)

        var cancellables = Set<AnyCancellable>()
        var publishedIDs: [ConversationID] = []
        for id in [stable, ephemeral] {
            store.conversation(for: id).objectWillChange
                .sink { publishedIDs.append(id) }
                .store(in: &cancellables)
        }
        var statusChangedIDs: [ConversationID] = []
        store.changes
            .sink { change in
                if case .statusChanged(let id, "dm-2", _) = change { statusChangedIDs.append(id) }
            }
            .store(in: &cancellables)

        let read = DeliveryStatus.read(by: "bob", at: Date())
        #expect(store.setDeliveryStatus(read, forMessageID: "dm-2"))

        // The shared instance is mutated once, but a view observing EITHER
        // conversation must re-render, and both emit a change event.
        #expect(Set(publishedIDs) == Set([stable, ephemeral]))
        #expect(Set(statusChangedIDs) == Set([stable, ephemeral]))

        // A duplicate ack applies nowhere and must publish nothing.
        publishedIDs.removeAll()
        statusChangedIDs.removeAll()
        #expect(!store.setDeliveryStatus(read, forMessageID: "dm-2"))
        #expect(publishedIDs.isEmpty)
        #expect(statusChangedIDs.isEmpty)
    }

    // MARK: - Invariant audit (field observability)

    /// A store exercised through every intent family: public + geohash +
    /// mirrored direct conversations, out-of-order and equal-timestamp
    /// appends, upserts, delivery updates, removal, migration, unread, and
    /// selection. Used as the healthy baseline for audit tests.
    @MainActor
    private static func makeExercisedStore() -> ConversationStore {
        let store = ConversationStore()
        let stable = makeDirectConversationID("stable")
        let ephemeral = makeDirectConversationID("ephemeral")

        store.append(makeMessage(id: "m1", timestamp: 10), to: .mesh)
        store.append(makeMessage(id: "m3", timestamp: 30), to: .mesh)
        store.append(makeMessage(id: "m2", timestamp: 20), to: .mesh) // out of order
        store.append(makeMessage(id: "m2b", timestamp: 20), to: .mesh) // equal timestamp
        store.append(makeMessage(id: "g1", timestamp: 5), to: .geohash("u4pruyd"))
        store.upsertByID(makeMessage(id: "g1", timestamp: 5, content: "edited"), in: .geohash("u4pruyd"))

        // Mirrored private copy (shared instance) across two direct chats.
        let mirrored = makeMessage(id: "dm-1", timestamp: 1, isPrivate: true, deliveryStatus: .sent)
        store.upsertByID(mirrored, in: stable)
        store.upsertByID(mirrored, in: ephemeral)
        store.setDeliveryStatus(.delivered(to: "bob", at: Date(timeIntervalSince1970: 2)), forMessageID: "dm-1")

        store.append(makeMessage(id: "dm-2", timestamp: 3, isPrivate: true), to: ephemeral)
        store.migrateConversation(from: ephemeral, to: stable)
        store.append(makeMessage(id: "dm-gone", timestamp: 4, isPrivate: true), to: stable)
        store.removeMessage(withID: "dm-gone", from: stable)

        store.markUnread(stable)
        store.setActiveChannel(.mesh)
        return store
    }

    @Test("audit reports no violations for a healthy, well-exercised store")
    @MainActor
    func auditHealthyStoreIsClean() {
        let store = Self.makeExercisedStore()
        #expect(store.auditInvariants().isEmpty)

        // Selection through both axes stays healthy.
        store.setSelectedPrivatePeer(PeerID(str: "peer-stable"))
        #expect(store.auditInvariants().isEmpty)
        store.setSelectedPrivatePeer(nil)
        #expect(store.auditInvariants().isEmpty)
    }

    @Test("audit flags index entries pointing at the wrong position")
    @MainActor
    func auditFlagsCorruptIndexEntries() {
        let store = Self.makeExercisedStore()
        store.conversation(for: .mesh)._testCorruptIndexEntries()

        let violations = store.auditInvariants()
        #expect(!violations.isEmpty)
        #expect(violations.contains { $0.contains("mesh") && $0.contains("indexed at") })
    }

    @Test("audit flags a message missing from the per-conversation index")
    @MainActor
    func auditFlagsMissingIndexEntry() {
        let store = Self.makeExercisedStore()
        store.conversation(for: .mesh)._testRemoveIndexEntry(forMessageID: "m1")

        let violations = store.auditInvariants()
        #expect(violations.contains { $0.contains("missing from index") })
        #expect(violations.contains { $0.contains("index has") }) // count mismatch
    }

    @Test("audit flags timestamp-order violations")
    @MainActor
    func auditFlagsOrderingViolation() {
        let store = Self.makeExercisedStore()
        store.conversation(for: .mesh)._testCorruptOrderingPreservingIndex()

        let violations = store.auditInvariants()
        #expect(violations.contains { $0.contains("timestamp order violated") })
        // The hook keeps the index consistent: no index violations leak in.
        #expect(!violations.contains { $0.contains("indexed at") || $0.contains("missing from index") })
    }

    @Test("audit flags map memberships the conversation does not hold")
    @MainActor
    func auditFlagsPhantomMapMembership() {
        let store = Self.makeExercisedStore()
        store._testRegisterPhantomMessageID("ghost", in: .mesh)

        let violations = store.auditInvariants()
        #expect(violations.contains { $0.contains("not present in claimed conversation") })
        #expect(violations.contains { $0.contains("memberships but conversations hold") })
    }

    @Test("audit flags map memberships claiming unknown conversations")
    @MainActor
    func auditFlagsUnknownConversationMembership() {
        let store = Self.makeExercisedStore()
        store._testRegisterPhantomMessageID("ghost", in: makeDirectConversationID("nope"))

        let violations = store.auditInvariants()
        #expect(violations.contains { $0.contains("claims unknown conversation") })
    }

    @Test("audit flags conversation messages missing from the map")
    @MainActor
    func auditFlagsMissingMapMembership() {
        let store = Self.makeExercisedStore()
        store._testUnregisterMessageID("m1", from: .mesh)

        let violations = store.auditInvariants()
        #expect(violations.contains { $0.contains("memberships but conversations hold") })
    }

    @Test("audit flags a conversation exceeding its cap")
    @MainActor
    func auditFlagsCapViolation() {
        let store = ConversationStore()
        let conversation = store.conversation(for: .mesh)
        for index in 0..<conversation.cap {
            store.append(makeMessage(id: "m\(index)", timestamp: TimeInterval(index)), to: .mesh)
        }
        #expect(store.auditInvariants().isEmpty)

        store._testAppendBypassingCap(
            makeMessage(id: "over-cap", timestamp: TimeInterval(conversation.cap)),
            to: .mesh
        )

        let violations = store.auditInvariants()
        #expect(violations.contains { $0.contains("exceeds cap") })
        // The hook keeps the map exact: only the cap invariant fires.
        #expect(violations.count == 1)
    }

    @Test("audit flags unread entries for nonexistent conversations")
    @MainActor
    func auditFlagsStaleUnreadEntry() {
        let store = Self.makeExercisedStore()
        store._testInsertUnreadConversationID(makeDirectConversationID("gone"))

        let violations = store.auditInvariants()
        #expect(violations.contains { $0.contains("unreadConversations contains unknown conversation") })
    }

    @Test("audit flags a selection pointing at a nonexistent conversation")
    @MainActor
    func auditFlagsDanglingSelection() {
        let store = Self.makeExercisedStore()
        store._testSetSelectedConversationID(makeDirectConversationID("gone"))

        let violations = store.auditInvariants()
        #expect(violations.contains { $0.contains("selectedConversationID") && $0.contains("has no conversation") })
    }

    @Test("appendCount counts every insertion, not duplicates or updates")
    @MainActor
    func appendCountTracksInsertions() {
        let store = ConversationStore()
        let source = makeDirectConversationID("ephemeral")
        let destination = makeDirectConversationID("stable")

        store.append(makeMessage(id: "m1", timestamp: 1), to: .mesh)
        store.append(makeMessage(id: "m1", timestamp: 1), to: .mesh) // duplicate: not counted
        store.upsertByID(makeMessage(id: "m2", timestamp: 2), in: .mesh) // upsert-append: counted
        store.upsertByID(makeMessage(id: "m2", timestamp: 2, content: "edit"), in: .mesh) // in-place: not counted
        #expect(store.appendCount == 2)

        store.append(makeMessage(id: "dm-1", timestamp: 1, isPrivate: true), to: source)
        store.migrateConversation(from: source, to: destination) // migration insert: counted
        #expect(store.appendCount == 4)

        // Removal does not decrement: the counter is a throughput odometer.
        store.removeMessage(withID: "dm-1", from: destination)
        #expect(store.appendCount == 4)
    }
}
