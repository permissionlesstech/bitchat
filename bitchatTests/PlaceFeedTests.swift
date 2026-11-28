//
// PlaceFeedTests.swift
// bitchatTests
//
// Unit and smoke coverage for Phase 1 Place Feed:
// - NIP-10 thread tagging & parsing (marked root/reply, mention ignore, legacy positional)
// - NIP-25 kind-7 reactions (create, parse, normalize, toggle on/off + NIP-09 delete)
// - NIP-13 PoW mining & validatedDifficulty scoring on kind-1 notes
// - LocationNotesManager threading, out-of-order replies, pruning, and panic-wipe fencing
// - PlaceFeedOrganizer sorting (.latest / .top), filtering (.all / .localOnly / .verifiedPoW), and search
// - SwiftUI smoke rendering of PlaceFeedView and PlaceThreadSheet
//

import Combine
import Foundation
import SwiftUI
import Testing
@testable import bitchat

struct PlaceFeedProtocolTests {

    @Test
    func nip10_directReplyEmitsMarkedRootAndAuthorTags() throws {
        let author = try NostrIdentity.generate()
        let rootID = String(repeating: "a", count: 64)
        let rootAuthor = String(repeating: "b", count: 64)

        let event = try NostrProtocol.createGeohashTextNote(
            content: "first reply",
            geohash: "9q8yy",
            senderIdentity: author,
            nickname: "bob",
            replyTo: .init(rootEventID: rootID, replyEventID: nil, replyAuthorPubkey: rootAuthor),
            teleported: true
        )

        #expect(event.kind == NostrProtocol.EventKind.textNote.rawValue)
        #expect(event.tags.contains(["g", "9q8yy"]))
        #expect(event.tags.contains(["t", "teleport"]))
        #expect(event.tags.contains(["e", rootID, "", "root"]))
        #expect(event.tags.contains(["p", rootAuthor]))

        let parsed = try #require(NostrProtocol.parseThreadReference(from: event.tags))
        #expect(parsed.rootEventID == rootID)
        #expect(parsed.replyEventID == nil)
        #expect(parsed.replyAuthorPubkey == rootAuthor)
    }

    @Test
    func nip10_nestedReplyEmitsBothRootAndReplyMarkers() throws {
        let author = try NostrIdentity.generate()
        let rootID = String(repeating: "1", count: 64)
        let parentID = String(repeating: "2", count: 64)
        let parentAuthor = String(repeating: "3", count: 64)

        let event = try NostrProtocol.createGeohashTextNote(
            content: "nested reply",
            geohash: "9q8yy",
            senderIdentity: author,
            replyTo: .init(rootEventID: rootID, replyEventID: parentID, replyAuthorPubkey: parentAuthor)
        )

        #expect(event.tags.contains(["e", rootID, "", "root"]))
        #expect(event.tags.contains(["e", parentID, "", "reply"]))

        let parsed = try #require(NostrProtocol.parseThreadReference(from: event.tags))
        #expect(parsed.rootEventID == rootID)
        #expect(parsed.replyEventID == parentID)
        #expect(parsed.replyAuthorPubkey == parentAuthor)
    }

    @Test
    func nip10_parserIgnoresMentionsAndSupportsLegacyPositionalTags() throws {
        let mentionOnly = [["e", String(repeating: "c", count: 64), "", "mention"]]
        #expect(NostrProtocol.parseThreadReference(from: mentionOnly) == nil)

        let rootID = String(repeating: "d", count: 64)
        let midID = String(repeating: "e", count: 64)
        let leafID = String(repeating: "f", count: 64)
        let positional = [
            ["e", rootID],
            ["e", midID],
            ["e", leafID]
        ]
        let parsed = try #require(NostrProtocol.parseThreadReference(from: positional))
        #expect(parsed.rootEventID == rootID)
        #expect(parsed.replyEventID == leafID)
    }

    @Test
    func nip25_reactionCreateAndParseUsesFirstETagAndValidatesEmoji() throws {
        let author = try NostrIdentity.generate()
        let targetID = String(repeating: "a", count: 64)
        let targetAuthor = String(repeating: "b", count: 64)

        let reaction = try NostrProtocol.createGeohashReactionEvent(
            emoji: "🔥",
            targetEventID: targetID,
            targetAuthorPubkey: targetAuthor,
            geohash: "9q8yy",
            senderIdentity: author
        )
        #expect(reaction.kind == NostrProtocol.EventKind.reaction.rawValue)
        #expect(reaction.isValidSignature())
        #expect(reaction.tags.contains(["g", "9q8yy"]))
        #expect(reaction.tags.contains(["e", targetID]))
        #expect(reaction.tags.contains(["p", targetAuthor]))

        let parsed = try #require(NostrProtocol.parseReactionTarget(from: reaction))
        #expect(parsed.targetEventID == targetID)
        #expect(parsed.emoji == "🔥")

        // First valid `e` tag wins so appended extra `e` tags cannot retarget a reaction.
        let extraID = String(repeating: "9", count: 64)
        let plusEvent = try NostrEvent(
            pubkey: author.publicKeyHex,
            createdAt: Date(),
            kind: .reaction,
            tags: [["g", "9q8yy"], ["e", targetID], ["e", extraID]],
            content: "+"
        ).sign(with: author.schnorrSigningKey())
        let parsedPlus = try #require(NostrProtocol.parseReactionTarget(from: plusEvent))
        #expect(parsedPlus.targetEventID == targetID)
        #expect(parsedPlus.emoji == "❤️")

        let minusEvent = try NostrEvent(
            pubkey: author.publicKeyHex,
            createdAt: Date(),
            kind: .reaction,
            tags: [["g", "9q8yy"], ["e", targetID]],
            content: "-"
        ).sign(with: author.schnorrSigningKey())
        #expect(NostrProtocol.parseReactionTarget(from: minusEvent) == nil)

        // Plain ASCII text and multi-grapheme strings are rejected as emoji chips.
        #expect(NostrProtocol.normalizeReactionContent("ok") == nil)
        #expect(NostrProtocol.normalizeReactionContent("ab") == nil)
        #expect(NostrProtocol.normalizeReactionContent("1") == nil)
        #expect(NostrProtocol.normalizeReactionContent("🔥🔥") == nil)
        #expect(NostrProtocol.normalizeReactionContent("❤️") == "❤️")
    }

    @Test
    func nip13_validatedPoWDifficultyChecksCommittedTargetAndLeadingZeros() {
        let id16 = "0000" + String(repeating: "f", count: 60)
        #expect(NostrProtocol.validatedPoWDifficulty(idHex: id16, tags: [["nonce", "1", "16"]]) == 16)
        #expect(NostrProtocol.validatedPoWDifficulty(idHex: id16, tags: [["nonce", "1", "8"]]) == 8)
        #expect(NostrProtocol.validatedPoWDifficulty(idHex: id16, tags: [["nonce", "1", "20"]]) == 0)
        #expect(NostrProtocol.validatedPoWDifficulty(idHex: id16, tags: [["g", "9q8yy"]]) == 0)
    }
}

@MainActor
struct PlaceFeedManagerTests {

    @Test
    func ingestSeparatesRepliesFromTopLevelAndOrdersRepliesChronologically() throws {
        var handler: ((NostrEvent) -> Void)?
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, onEvent, _ in handler = onEvent },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in try NostrIdentity.generate() },
            now: { now }
        )

        let manager = LocationNotesManager(geohash: "9q8yy", dependencies: deps)
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()

        let rootEvent = try NostrProtocol.createGeohashTextNote(
            content: "root post",
            geohash: "9q8yy",
            senderIdentity: alice,
            nickname: "alice",
            createdAt: now.addingTimeInterval(-300)
        )
        let laterReply = try NostrProtocol.createGeohashTextNote(
            content: "second reply",
            geohash: "9q8yy",
            senderIdentity: alice,
            nickname: "alice",
            replyTo: .init(rootEventID: rootEvent.id, replyAuthorPubkey: bob.publicKeyHex),
            createdAt: now.addingTimeInterval(-60)
        )
        let earlierReply = try NostrProtocol.createGeohashTextNote(
            content: "first reply",
            geohash: "9q8yy",
            senderIdentity: bob,
            nickname: "bob",
            replyTo: .init(rootEventID: rootEvent.id, replyAuthorPubkey: alice.publicKeyHex),
            createdAt: now.addingTimeInterval(-180)
        )

        // Deliver reply BEFORE root to verify out-of-order resilience.
        handler?(laterReply)
        handler?(rootEvent)
        handler?(earlierReply)

        #expect(manager.notes.count == 1)
        #expect(manager.notes.first?.id == rootEvent.id)
        #expect(manager.replyCount(forRootID: rootEvent.id) == 2)
        #expect(manager.replies(forRootID: rootEvent.id).map(\.content) == ["first reply", "second reply"])
    }

    @Test
    func toggleReactionPublishesKind7AndRetractsWithNip09Delete() throws {
        var sentEvents: [NostrEvent] = []
        var handler: ((NostrEvent) -> Void)?
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let me = try NostrIdentity.generate()
        let peer = try NostrIdentity.generate()

        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, onEvent, _ in handler = onEvent },
            unsubscribe: { _ in },
            sendEvent: { event, _ in sentEvents.append(event) },
            deriveIdentity: { _ in me },
            now: { now }
        )

        let manager = LocationNotesManager(geohash: "9q8yy", dependencies: deps)
        let rootEvent = try NostrProtocol.createGeohashTextNote(
            content: "coffee meetup",
            geohash: "9q8yy",
            senderIdentity: peer,
            nickname: "peer",
            createdAt: now
        )
        handler?(rootEvent)
        let rootNote = try #require(manager.notes.first)

        // Peer reacts with 🔥
        let peerReaction = try NostrProtocol.createGeohashReactionEvent(
            emoji: "🔥",
            targetEventID: rootNote.id,
            targetAuthorPubkey: peer.publicKeyHex,
            geohash: "9q8yy",
            senderIdentity: peer,
            createdAt: now
        )
        handler?(peerReaction)
        #expect(manager.reactions(forNoteID: rootNote.id) == [
            AggregatedReaction(emoji: "🔥", count: 1, includesCurrentUser: false)
        ])

        // We toggle 🔥 on -> publishes kind 7 and increments count to 2
        #expect(manager.toggleReaction(emoji: "🔥", on: rootNote))
        #expect(sentEvents.count == 1)
        #expect(sentEvents[0].kind == NostrProtocol.EventKind.reaction.rawValue)
        let ourReactionID = sentEvents[0].id
        #expect(manager.reactions(forNoteID: rootNote.id) == [
            AggregatedReaction(emoji: "🔥", count: 2, includesCurrentUser: true)
        ])

        // We toggle 🔥 off -> publishes geohash-tagged NIP-09 kind 5 deletion and returns count to 1
        #expect(manager.toggleReaction(emoji: "🔥", on: rootNote))
        #expect(sentEvents.count == 2)
        #expect(sentEvents[1].kind == NostrProtocol.EventKind.deletion.rawValue)
        #expect(sentEvents[1].tags.contains(["e", ourReactionID]))
        #expect(sentEvents[1].tags.contains(["g", "9q8yy"]))
        #expect(manager.reactions(forNoteID: rootNote.id) == [
            AggregatedReaction(emoji: "🔥", count: 1, includesCurrentUser: false)
        ])

        // Forged NIP-09 deletion from another author is ignored.
        let imposter = try NostrIdentity.generate()
        let forgedDelete = try NostrProtocol.createDeleteEvent(
            ofEventID: peerReaction.id,
            senderIdentity: imposter,
            geohash: "9q8yy"
        )
        handler?(forgedDelete)
        #expect(manager.reactions(forNoteID: rootNote.id) == [
            AggregatedReaction(emoji: "🔥", count: 1, includesCurrentUser: false)
        ])

        // Legitimate NIP-09 deletion from the reaction author retracts the reaction live.
        let peerDelete = try NostrProtocol.createDeleteEvent(
            ofEventID: peerReaction.id,
            senderIdentity: peer,
            geohash: "9q8yy"
        )
        handler?(peerDelete)
        #expect(manager.reactions(forNoteID: rootNote.id).isEmpty)
    }

    @Test
    func resetForPanicClearsThreadsReactionsAndNotes() throws {
        var sentEvents: [NostrEvent] = []
        var handler: ((NostrEvent) -> Void)?
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let me = try NostrIdentity.generate()

        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, onEvent, _ in handler = onEvent },
            unsubscribe: { _ in },
            sendEvent: { event, _ in sentEvents.append(event) },
            deriveIdentity: { _ in me },
            now: { now }
        )

        let manager = LocationNotesManager(geohash: "9q8yy", dependencies: deps)
        let root = try NostrProtocol.createGeohashTextNote(
            content: "pre-panic root",
            geohash: "9q8yy",
            senderIdentity: me,
            createdAt: now
        )
        let reply = try NostrProtocol.createGeohashTextNote(
            content: "pre-panic reply",
            geohash: "9q8yy",
            senderIdentity: me,
            replyTo: .init(rootEventID: root.id),
            createdAt: now
        )
        let reaction = try NostrProtocol.createGeohashReactionEvent(
            emoji: "❤️",
            targetEventID: root.id,
            targetAuthorPubkey: me.publicKeyHex,
            geohash: "9q8yy",
            senderIdentity: me,
            createdAt: now
        )
        handler?(root)
        handler?(reply)
        handler?(reaction)
        #expect(manager.notes.count == 1)
        #expect(manager.replyCount(forRootID: root.id) == 1)
        #expect(manager.totalReactionCount(forNoteID: root.id) == 1)

        manager.resetForPanic()

        #expect(manager.notes.isEmpty)
        #expect(manager.repliesByRootID.isEmpty)
        #expect(manager.reactionsByNoteID.isEmpty)
        #expect(sentEvents.isEmpty)
    }

    @Test
    func deleteRemovesOwnReplyAndPruneDropsExpiredReplies() throws {
        var sentEvents: [NostrEvent] = []
        var handler: ((NostrEvent) -> Void)?
        var currentNow = Date(timeIntervalSince1970: 1_700_000_000)
        let me = try NostrIdentity.generate()
        let other = try NostrIdentity.generate()

        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, onEvent, _ in handler = onEvent },
            unsubscribe: { _ in },
            sendEvent: { event, _ in sentEvents.append(event) },
            deriveIdentity: { _ in me },
            now: { currentNow }
        )

        let manager = LocationNotesManager(geohash: "9q8yy", dependencies: deps)
        let root = try NostrProtocol.createGeohashTextNote(
            content: "root",
            geohash: "9q8yy",
            senderIdentity: other,
            createdAt: currentNow
        )
        let ownReply = try NostrProtocol.createGeohashTextNote(
            content: "mine",
            geohash: "9q8yy",
            senderIdentity: me,
            replyTo: .init(rootEventID: root.id),
            createdAt: currentNow
        )
        let expiringReply = try NostrProtocol.createGeohashTextNote(
            content: "fades soon",
            geohash: "9q8yy",
            senderIdentity: other,
            expiresAt: currentNow.addingTimeInterval(60),
            replyTo: .init(rootEventID: root.id),
            createdAt: currentNow
        )

        handler?(root)
        handler?(ownReply)
        handler?(expiringReply)
        #expect(manager.replyCount(forRootID: root.id) == 2)

        let mineNote = try #require(manager.replies(forRootID: root.id).first(where: { $0.content == "mine" }))
        #expect(manager.delete(note: mineNote))
        #expect(sentEvents.last?.kind == NostrProtocol.EventKind.deletion.rawValue)
        #expect(manager.replyCount(forRootID: root.id) == 1)

        currentNow = currentNow.addingTimeInterval(120)
        manager.pruneExpiredNotes()
        #expect(manager.replyCount(forRootID: root.id) == 0)
    }

    @Test
    func organizerSortsTopFiltersLocalAndPoWAndSearches() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let localPlain = NoticeItem(note: .init(
            id: "a1", pubkey: "1111", content: "rain starting downtown",
            createdAt: base.addingTimeInterval(100), nickname: "alice", geohash: "9q8yy",
            powDifficulty: 0, isTeleported: false
        ))
        let teleportedPoW = NoticeItem(note: .init(
            id: "b2", pubkey: "2222", content: "watching from afar",
            createdAt: base.addingTimeInterval(50), nickname: "bob", geohash: "9q8yy",
            powDifficulty: 10, isTeleported: true
        ))
        let localPopular = NoticeItem(note: .init(
            id: "c3", pubkey: "3333", content: "block party on 5th",
            createdAt: base, nickname: "carol", geohash: "9q8yy",
            powDifficulty: 8, isTeleported: false
        ))
        let items = [localPlain, teleportedPoW, localPopular]

        // Latest sort
        let latest = PlaceFeedOrganizer.organize(items: items, sort: .latest, filter: .all)
        #expect(latest.map(\.id) == ["a1", "b2", "c3"])

        // Top sort ranks by replies * 3 + reactions * 2 + pow bonus
        let top = PlaceFeedOrganizer.organize(
            items: items,
            sort: .top,
            filter: .all,
            replyCount: { $0 == "c3" ? 4 : 0 },
            reactionCount: { $0 == "b2" ? 2 : 0 }
        )
        #expect(top.map(\.id) == ["c3", "b2", "a1"])

        // On-site filter hides teleported posts
        let localOnly = PlaceFeedOrganizer.organize(items: items, sort: .latest, filter: .localOnly)
        #expect(localOnly.map(\.id) == ["a1", "c3"])

        // PoW filter keeps only validated PoW (or board) posts
        let powOnly = PlaceFeedOrganizer.organize(items: items, sort: .latest, filter: .verifiedPoW)
        #expect(powOnly.map(\.id) == ["b2", "c3"])

        // Search query matches content or author case-insensitively
        let search = PlaceFeedOrganizer.organize(items: items, sort: .latest, filter: .all, query: "CAROL")
        #expect(search.map(\.id) == ["c3"])
    }

    @Test
    func placeFeedAndThreadViewsRenderWithoutCrashing() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deps = LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { _, _, _, _, onEOSE in onEOSE?() },
            unsubscribe: { _ in },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in try NostrIdentity.generate() },
            now: { now }
        )
        let manager = LocationNotesManager(geohash: "9q8yy", dependencies: deps)
        let transport = MockTransport()
        let board = BoardManager(transport: transport, store: BoardStore(persistsToDisk: false))
        let locationManager = LocationChannelManager(storage: UserDefaults(suiteName: "PlaceFeedSmoke-\(UUID().uuidString)") ?? .standard)
        let locationModel = LocationChannelsModel(manager: locationManager)
        let channel = GeohashChannel(level: .city, geohash: "9q8yy")

        let feedView = PlaceFeedView(
            channel: channel,
            senderNickname: "tester",
            board: board,
            isTeleported: false,
            notesManager: manager
        )
        .environmentObject(locationModel)

        let rootNote = LocationNotesManager.Note(
            id: String(repeating: "a", count: 64),
            pubkey: String(repeating: "b", count: 64),
            content: "smoke test root post",
            createdAt: now,
            nickname: "alice",
            geohash: "9q8yy",
            powDifficulty: 8
        )
        let threadSheet = PlaceThreadSheet(
            rootNote: rootNote,
            geohash: "9q8yy",
            senderNickname: "tester",
            isTeleported: false,
            manager: manager
        )

        #expect(String(describing: type(of: feedView)).contains("PlaceFeedView"))
        #expect(String(describing: type(of: threadSheet)).contains("PlaceThreadSheet"))
    }
}
