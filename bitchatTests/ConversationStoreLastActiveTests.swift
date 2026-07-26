//
// ConversationStoreLastActiveTests.swift
// bitchatTests
//
// Tests for #1064 last-active persistence: ConversationStore records the
// foreground conversation on every switch and, at the next launch, decides
// what to present — a valid DM restores, a stale DM or a first-ever launch
// falls back to the conversation list, and a public channel defers to the
// existing GeoChannelCoordinator restore.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import XCTest
@testable import bitchat

@MainActor
final class ConversationStoreLastActiveTests: XCTestCase {
    /// A structurally valid short (16-hex) peer id.
    private let peerID = PeerID(str: "0123456789abcdef")

    func test_persistsLastActiveOnEverySwitch() {
        let storage = makeStorage()

        // Open a DM: the next launch should restore it.
        let session1 = ConversationStore(storage: storage)
        session1.setSelectedPrivatePeer(peerID)
        XCTAssertEqual(
            ConversationStore(storage: storage).restoreLastActiveConversation(isPeerResolvable: { _ in true }),
            .restoredDirectChat(peerID)
        )

        // Close the DM back to the mesh channel: the write must happen again,
        // so the next launch now defers to the channel restore, not the DM.
        session1.setSelectedPrivatePeer(nil)
        XCTAssertEqual(
            ConversationStore(storage: storage).restoreLastActiveConversation(isPeerResolvable: { _ in true }),
            .deferToChannelRestore
        )
    }

    func test_restoresValidDirectChat() {
        let storage = makeStorage()
        ConversationStore(storage: storage).setSelectedPrivatePeer(peerID)

        let restored = ConversationStore(storage: storage)
            .restoreLastActiveConversation(isPeerResolvable: { $0.isValid })

        XCTAssertEqual(restored, .restoredDirectChat(peerID))
    }

    func test_staleDirectChatFallsBackToConversationList() {
        let storage = makeStorage()
        ConversationStore(storage: storage).setSelectedPrivatePeer(peerID)

        // The persisted peer no longer resolves at launch.
        let restored = ConversationStore(storage: storage)
            .restoreLastActiveConversation(isPeerResolvable: { _ in false })

        XCTAssertEqual(restored, .conversationList)
    }

    func test_failedDirectRestoreDoesNotEraseDirectRecord() {
        // #1064: a redundant channel re-apply must not clobber a persisted DM.
        let storage = makeStorage()

        // Session 1: the user is in a DM — persists a `.direct` record.
        ConversationStore(storage: storage).setSelectedPrivatePeer(peerID)

        // Session 2 (launch): a fresh store starts with no private peer
        // selected. The DM restore has just failed, and GeoChannelCoordinator
        // re-asserts the SAME (default mesh) active channel. Because the channel
        // does not actually change, the persist is now guarded out — so the
        // `.direct` record on disk must survive rather than be overwritten with
        // `.mesh`.
        let launch = ConversationStore(storage: storage)
        launch.setActiveChannel(launch.activeChannel)

        // Session 3: the DM record is intact and still restores.
        XCTAssertEqual(
            ConversationStore(storage: storage)
                .restoreLastActiveConversation(isPeerResolvable: { _ in true }),
            .restoredDirectChat(peerID)
        )
    }

    func test_clearPersistedLastActiveErasesRestoreRecord() {
        // #1064 panic wipe: clearing the persisted last-active pointer means a
        // wiped DM/channel cannot be restored on the next launch.
        let storage = makeStorage()

        // A DM is persisted and would otherwise restore.
        let session = ConversationStore(storage: storage)
        session.setSelectedPrivatePeer(peerID)
        XCTAssertEqual(
            ConversationStore(storage: storage)
                .restoreLastActiveConversation(isPeerResolvable: { _ in true }),
            .restoredDirectChat(peerID)
        )

        // The panic path erases the pointer through the store's own storage.
        session.clearPersistedLastActive()

        // The next launch has nothing to restore and falls back to the list.
        XCTAssertEqual(
            ConversationStore(storage: storage)
                .restoreLastActiveConversation(isPeerResolvable: { _ in true }),
            .conversationList
        )
    }

    func test_panicWipeOrderLeavesNoRestoreRecord() {
        // #1064 panic wipe, FULL ORDER: `clearPersistedLastActive()` alone is
        // insufficient because `panicClearAllData()` also runs
        // `selectedPrivateChatPeer = nil` and `activeChannel = .mesh` AFTER it —
        // both route through the store's setters, whose guarded `persistLastActive()`
        // re-writes a `.mesh` record on a real state change, resurrecting the
        // pointer. The begin/finish suppression window fixes that. This test
        // mirrors panicClearAllData's exact order against a single store:
        //   beginPanicWipe → setSelectedPrivatePeer(nil) → setActiveChannel(.mesh) → finishPanicWipe
        // Without the fix (i.e. without begin/finish), those selection/channel
        // resets re-persist a `.mesh` record — here `setSelectedPrivatePeer(nil)`
        // is the real state change that writes it (the store's default channel
        // is already `.mesh`, so `setActiveChannel(.mesh)` is the second trigger
        // whenever panic runs from a non-mesh channel). Either way the pointer
        // survives as `.mesh` and the next launch would `.deferToChannelRestore`
        // instead of `.conversationList`.
        let storage = makeStorage()

        // The user is in a DM: a `.direct` record is persisted and would restore.
        let session = ConversationStore(storage: storage)
        session.setSelectedPrivatePeer(peerID)
        XCTAssertEqual(
            ConversationStore(storage: storage)
                .restoreLastActiveConversation(isPeerResolvable: { _ in true }),
            .restoredDirectChat(peerID)
        )

        // Reproduce panicClearAllData's order on the SAME store.
        session.beginPanicWipe()
        session.setSelectedPrivatePeer(nil)   // re-persist trigger #1 (suppressed)
        session.setActiveChannel(.mesh)       // re-persist trigger #2 (suppressed)
        session.finishPanicWipe()             // removes the pointer once

        // A fresh store on the SAME storage finds NO record and falls back to
        // the conversation list — the pointer is truly absent, not `.mesh`.
        XCTAssertEqual(
            ConversationStore(storage: storage)
                .restoreLastActiveConversation(isPeerResolvable: { _ in true }),
            .conversationList
        )
    }

    func test_firstLaunchPresentsConversationList() {
        let storage = makeStorage()

        let restored = ConversationStore(storage: storage)
            .restoreLastActiveConversation(isPeerResolvable: { _ in true })

        XCTAssertEqual(restored, .conversationList)
    }

    // MARK: - Launch effect (silent-mesh fallback)

    func test_launchPresentsList_whenRestoredDirectChatDidNotOpen() {
        // A persisted DM whose peer is now blocked/stale/gated: startPrivateChat
        // no-ops, so no chat opens — must fall back to the conversation list,
        // never silently land on the public mesh timeline.
        XCTAssertTrue(
            AppRuntime.shouldPresentConversationList(
                for: .restoredDirectChat(peerID),
                didOpenDirectChat: false
            )
        )
    }

    func test_launchDoesNotPresentList_whenRestoredDirectChatOpened() {
        XCTAssertFalse(
            AppRuntime.shouldPresentConversationList(
                for: .restoredDirectChat(peerID),
                didOpenDirectChat: true
            )
        )
    }

    func test_launchDefersToChannelRestore_withoutPresentingList() {
        // A public-channel restore is owned by GeoChannelCoordinator; the
        // launch decision must not present the list on top of it.
        XCTAssertFalse(
            AppRuntime.shouldPresentConversationList(
                for: .deferToChannelRestore,
                didOpenDirectChat: false
            )
        )
    }

    // MARK: - Restorability predicate (durable state, not syntax)

    func test_unknownButSyntacticallyValidPeerIsNotRestorable() {
        // Regression guard: a well-formed 16-hex peer id we have NO durable
        // relationship with must NOT be treated as restorable. Otherwise it
        // falls straight through startPrivateChat into an empty phantom DM.
        // (The syntax-only `{ $0.isValid }` resolver missed exactly this.)
        XCTAssertTrue(peerID.isValid)
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                peerID,
                isPeerFavorited: { _ in false },
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_mutualFavoritePeerIsRestorable() {
        // A persisted MUTUAL favorite is stored by stable Noise public key and
        // survives restart — the one durable, presence-independent mesh
        // relationship. Mirrors the open-path gate, which only lets an offline
        // favorite through when the favorite is mutual.
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(
                peerID,
                isPeerFavorited: { _ in true },
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_oneWayFavoritePeerIsRestorable() {
        // INVERTED by #1415, deliberately kept as the record of that change.
        // This used to be false: the open path required a mutual favorite, so
        // restoring a one-way favorite would have injected a "requires
        // favorite" system message into the public timeline. #1415 removed that
        // gate — store-and-forward needs only the recipient's noise key — so a
        // one-way favorite is now perfectly sendable, and refusing to restore
        // it would make launch stricter than chat entry.
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(
                peerID,
                isPeerFavorited: { _ in true },
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_peerWhoOnlyFavoritedUsIsNotRestorable() {
        // Remote state alone is not evidence we can address them. They favorited
        // us, we never favorited them, and we hold no stored identity — the
        // unaddressable phantom this predicate exists to refuse. Their opinion
        // of us says nothing about whether we have a key for them.
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                peerID,
                isPeerFavorited: { _ in false },
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_geoChatIdIsNeverRestorableAsADirectChat() {
        // A geohash channel id is not a direct chat at all, and the screen runs
        // before the favorite term so nothing can match past it.
        let geoChatID = PeerID(str: "nostr:01234567")
        XCTAssertTrue(geoChatID.isGeoChat)
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                geoChatID,
                isPeerFavorited: { _ in true },
                hasStoredCryptographicIdentity: { _ in true },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_establishedNonFavoritePeerIsRestorable() {
        // No favorite either way, but we hold a stored cryptographic identity —
        // durable, on disk, and enough for the router to deliver via courier or
        // the retained outbox. Restoring it is not a phantom.
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(
                peerID,
                isPeerFavorited: { _ in false },
                hasStoredCryptographicIdentity: { _ in true },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_blockedEstablishedPeerIsNotRestorable() {
        // Blocked is a veto, not one term among several: a stored identity must
        // not buy its way past the block the way it passes the favorite terms.
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                peerID,
                isPeerFavorited: { _ in false },
                hasStoredCryptographicIdentity: { _ in true },
                isPeerBlocked: { _ in true }
            )
        )
    }

    func test_geoDMWithStoredIdentityIsNotRestorable() {
        // The identity term must NOT extend to geohash DMs. A `nostr_` id's
        // full Nostr key is rebuilt only from inbound ephemeral events, and
        // startPrivateChat skips the handshake for geoDMs, so a phantom would
        // open with no error at all. Today the lookup would miss anyway (the
        // id's prefix is re-attached and no hex fingerprint starts with it),
        // which is luck — this pins the refusal so a change to that lookup
        // cannot quietly turn geoDM phantoms back on.
        let geoDMPeer = PeerID(str: "nostr_0123456789abcdef")
        XCTAssertTrue(geoDMPeer.isGeoDM)
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                geoDMPeer,
                isPeerFavorited: { _ in false },
                hasStoredCryptographicIdentity: { _ in true },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_geoDMWithFavoriteIsRestorable() {
        // A favorite record IS a geoDM's durable anchor (it carries
        // peerNostrPublicKey), so the favorite terms still admit one.
        let geoDMPeer = PeerID(str: "nostr_0123456789abcdef")
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(
                geoDMPeer,
                isPeerFavorited: { _ in true },
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_privateGroupIsRestorable() {
        // A group id is `group_` plus 32 hex, so both peer lookups guard on
        // `isShort` and return empty for it. Left to those terms a group would
        // never restore, silently, every time — even though `startPrivateChat`
        // gates group re-entry on nothing at all.
        let group = PeerID(str: "group_" + String(repeating: "ab", count: 16))
        XCTAssertTrue(group.isGroup, "test fixture is not a group id")
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(
                group,
                isPeerFavorited: { _ in false },
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_privateGroupNeverConsultsThePeerTerms() {
        // Admitting groups by accident — because some peer term happened to
        // match — would be a different bug wearing the same green check. The
        // group must be admitted on its own branch, before either lookup runs.
        let group = PeerID(str: "group_" + String(repeating: "cd", count: 16))
        var favoriteLookups = 0
        var identityLookups = 0
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(
                group,
                isPeerFavorited: { _ in favoriteLookups += 1; return false },
                hasStoredCryptographicIdentity: { _ in identityLookups += 1; return false },
                isPeerBlocked: { _ in false }
            )
        )
        XCTAssertEqual(favoriteLookups, 0, "group restore consulted the favorites term")
        XCTAssertEqual(identityLookups, 0, "group restore consulted the identity term")
    }

    func test_idClassesAreMutuallyExclusive() {
        // The group branch sits between the geoChat guard and the geoDM one,
        // so its placement would be load-bearing if an id could belong to two
        // classes at once. `PeerID` assigns exactly one prefix, so it cannot —
        // pin that, because the day it stops being true the ordering silently
        // decides which rule wins.
        let group = PeerID(str: "group_" + String(repeating: "ab", count: 16))
        let geoDM = PeerID(str: "nostr_0123456789abcdef")
        let geoChat = PeerID(str: "nostr:someGeohashChannel")

        XCTAssertTrue(group.isGroup)
        XCTAssertFalse(group.isGeoDM)
        XCTAssertFalse(group.isGeoChat)

        XCTAssertFalse(geoDM.isGroup)
        XCTAssertFalse(geoChat.isGroup)
    }

    func test_malformedGroupIDIsStillAdmitted_documentingTheBound() {
        // `isGroup` tests the prefix only — `PeerID(str:)` never validates the
        // bare — so this branch admits any persisted id claiming to be a
        // group. That is deliberate and bounded: the value is written by our
        // own selection path into local state, never parsed from the network,
        // and the failure it can produce is an empty group rather than the
        // phantom DM this predicate exists to prevent. Pinned so that if the
        // id ever becomes untrusted, this test is the thing that has to change.
        let malformed = PeerID(str: "group_not-hex")
        XCTAssertTrue(malformed.isGroup)
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(
                malformed,
                isPeerFavorited: { _ in false },
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_blockedGroupIsNotRestorable() {
        // Block stays an unconditional veto, ahead of the group branch.
        let group = PeerID(str: "group_" + String(repeating: "ef", count: 16))
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                group,
                isPeerFavorited: { _ in false },
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in true }
            )
        )
    }

    func test_blockedMutualFavoriteIsNotRestorable() {
        // A blocked peer is never restorable, even if the favorite is mutual —
        // mirrors the gate's first (block) reject.
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                peerID,
                isPeerFavorited: { _ in true },
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in true }
            )
        )
    }

    func test_geoDMPeerWithoutMutualFavoriteIsNotRestorable() {
        // #1064 phantom-DM fix: a geohash/Nostr DM id is NO LONGER special-cased
        // as restorable. Its full Nostr key is rebuilt only from inbound
        // ephemeral events, so at launch a restored `nostr_` id cannot resolve
        // and would open an unsendable phantom. Only a mutual favorite restores.
        let geoDMPeer = PeerID(str: "nostr_0123456789abcdef")
        XCTAssertTrue(geoDMPeer.isGeoDM)
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                geoDMPeer,
                isPeerFavorited: { _ in false },
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_restoreWithProductionShapedResolver_unknownPeerYieldsConversationList() {
        // End-to-end through ConversationStore using the PRODUCTION predicate
        // shape (not a bare `{ _ in false }`): a persisted DM whose peer is
        // unknown/unfavorited must present the conversation list, never restore
        // a phantom DM. This is the test that would have caught the hole.
        let storage = makeStorage()
        ConversationStore(storage: storage).setSelectedPrivatePeer(peerID)

        let restored = ConversationStore(storage: storage).restoreLastActiveConversation(
            isPeerResolvable: {
                AppRuntime.isDirectChatRestorable(
                    $0,
                    isPeerFavorited: { _ in false },
                    hasStoredCryptographicIdentity: { _ in false },
                    isPeerBlocked: { _ in false }
                )
            }
        )

        XCTAssertEqual(restored, .conversationList)
    }

    // MARK: - Production wiring (real FavoritesPersistenceService)

    func test_production_fullHexMutualFavoritePeerIsRestorable() {
        // migrateSelectedConversationIfNeeded persists the peer in FULL 64-hex
        // Noise-key form; the favorites store is keyed by the short derived id.
        // The production resolver must normalize (`toShort()`) so a favorited DM
        // still restores. Regression for fix-round-3 finding 1. The favorite must
        // be MUTUAL to mirror the open-path gate.
        let favorites = FavoritesPersistenceService(keychain: MockKeychain())
        let noiseKey = Data((0..<32).map(UInt8.init))
        favorites.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "Alice")
        favorites.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: true)

        let fullHexPeer = PeerID(str: noiseKey.hexEncodedString())
        XCTAssertFalse(fullHexPeer.isShort) // 64-hex, not the short form
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(
                fullHexPeer,
                favorites: favorites,
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_production_oneWayFavoriteIsRestorable() {
        // INVERTED by #1415, through the real favorites wiring. This used to
        // refuse a non-mutual favorite because the open-path gate would have
        // rejected it at launch; that gate is gone, so refusing here would make
        // launch stricter than chat entry for a DM the router can deliver.
        let favorites = FavoritesPersistenceService(keychain: MockKeychain())
        let noiseKey = Data((0..<32).map(UInt8.init))
        favorites.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "Alice")

        let fullHexPeer = PeerID(str: noiseKey.hexEncodedString())
        XCTAssertTrue(favorites.getFavoriteStatus(forPeerID: fullHexPeer.toShort())!.isFavorite)
        XCTAssertFalse(favorites.getFavoriteStatus(forPeerID: fullHexPeer.toShort())!.theyFavoritedUs)
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(
                fullHexPeer,
                favorites: favorites,
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_production_blockedMutualFavoriteIsNotRestorable() {
        // A mutual favorite we have since blocked must NOT restore — mirrors the
        // gate's block reject. Block state is injected (it lives in the identity
        // manager, not the favorites store).
        let favorites = FavoritesPersistenceService(keychain: MockKeychain())
        let noiseKey = Data((0..<32).map(UInt8.init))
        favorites.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "Alice")
        favorites.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: true)

        let fullHexPeer = PeerID(str: noiseKey.hexEncodedString())
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                fullHexPeer,
                favorites: favorites,
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in true }
            )
        )
    }

    func test_production_unknownShortPeerIsNotRestorable() {
        // A syntactically valid short peer with no favorite relationship must
        // NOT restore (would otherwise open an empty phantom DM). Pins the real
        // wiring so it cannot drift back to a syntax-only check.
        let favorites = FavoritesPersistenceService(keychain: MockKeychain())
        XCTAssertTrue(peerID.isValid)
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                peerID,
                favorites: favorites,
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_production_unfavoritedPeerWhoStillFavoritesUsIsNotRestorable() {
        // removeFavorite RETAINS a record (isFavorite: false, theyFavoritedUs:
        // true) when the peer still favorites us. The resolver must key on
        // isFavorite, not mere record existence — otherwise a DM to a peer we
        // deliberately unfavorited reopens on restart. Regression for an
        // earlier Codex review, and it SURVIVES the #1415 relaxation: the
        // relaxed predicate admits our own favorite or a stored identity, and
        // `theyFavoritedUs` is deliberately not a term, so the unfavorite still
        // stands on its own.
        //
        // With a stored identity this peer would restore — see
        // test_establishedNonFavoritePeerIsRestorable. That is the intended
        // line: the durable evidence is then local capability rather than the
        // other side's opinion of us.
        let favorites = FavoritesPersistenceService(keychain: MockKeychain())
        let noiseKey = Data((0..<32).map(UInt8.init))
        favorites.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "Alice")
        favorites.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: true)
        favorites.removeFavorite(peerNoisePublicKey: noiseKey)

        let fullHexPeer = PeerID(str: noiseKey.hexEncodedString())
        // The record survives (they still favorite us) but isFavorite is false.
        XCTAssertNotNil(favorites.getFavoriteStatus(forPeerID: fullHexPeer.toShort()))
        XCTAssertFalse(favorites.getFavoriteStatus(forPeerID: fullHexPeer.toShort())!.isFavorite)
        XCTAssertTrue(favorites.getFavoriteStatus(forPeerID: fullHexPeer.toShort())!.theyFavoritedUs)
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                fullHexPeer,
                favorites: favorites,
                hasStoredCryptographicIdentity: { _ in false },
                isPeerBlocked: { _ in false }
            )
        )
    }

    // MARK: - Helpers

    private func makeStorage() -> UserDefaults {
        let suiteName = "ConversationStoreLastActiveTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            storage.removePersistentDomain(forName: suiteName)
        }
        return storage
    }
}
