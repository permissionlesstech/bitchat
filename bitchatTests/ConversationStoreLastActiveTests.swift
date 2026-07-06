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
                theyFavoritedUs: { _ in false },
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
                theyFavoritedUs: { _ in true },
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_oneWayFavoritePeerIsNotRestorable() {
        // We favorite them but they do NOT favorite us: the open-path gate
        // rejects this at launch (isConnected is false), so auto-restoring it
        // would inject a "requires favorite" system message into the public
        // timeline. The predicate must refuse it up front.
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                peerID,
                isPeerFavorited: { _ in true },
                theyFavoritedUs: { _ in false },
                isPeerBlocked: { _ in false }
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
                theyFavoritedUs: { _ in true },
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
                theyFavoritedUs: { _ in false },
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
                    theyFavoritedUs: { _ in false },
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
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_production_oneWayFavoriteIsNotRestorable() {
        // We favorite them but they never favorited us: not mutual, so the
        // open-path gate would reject it at launch. The production resolver must
        // refuse it rather than auto-open a gated DM.
        let favorites = FavoritesPersistenceService(keychain: MockKeychain())
        let noiseKey = Data((0..<32).map(UInt8.init))
        favorites.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "Alice")

        let fullHexPeer = PeerID(str: noiseKey.hexEncodedString())
        XCTAssertTrue(favorites.getFavoriteStatus(forPeerID: fullHexPeer.toShort())!.isFavorite)
        XCTAssertFalse(favorites.getFavoriteStatus(forPeerID: fullHexPeer.toShort())!.theyFavoritedUs)
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                fullHexPeer,
                favorites: favorites,
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
                isPeerBlocked: { _ in false }
            )
        )
    }

    func test_production_unfavoritedPeerWhoStillFavoritesUsIsNotRestorable() {
        // removeFavorite RETAINS a record (isFavorite: false, theyFavoritedUs:
        // true) when the peer still favorites us. The resolver must key on
        // isFavorite, not mere record existence — otherwise a DM to a peer we
        // deliberately unfavorited reopens on restart, contradicting the
        // "is a persisted favorite" contract. Regression for Codex P2 review.
        let favorites = FavoritesPersistenceService(keychain: MockKeychain())
        let noiseKey = Data((0..<32).map(UInt8.init))
        favorites.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "Alice")
        favorites.updatePeerFavoritedUs(peerNoisePublicKey: noiseKey, favorited: true)
        favorites.removeFavorite(peerNoisePublicKey: noiseKey)

        let fullHexPeer = PeerID(str: noiseKey.hexEncodedString())
        // The record survives (they still favorite us) but isFavorite is false.
        XCTAssertNotNil(favorites.getFavoriteStatus(forPeerID: fullHexPeer.toShort()))
        XCTAssertFalse(favorites.getFavoriteStatus(forPeerID: fullHexPeer.toShort())!.isFavorite)
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(
                fullHexPeer,
                favorites: favorites,
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
