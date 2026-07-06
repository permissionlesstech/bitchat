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
            AppRuntime.isDirectChatRestorable(peerID, isPeerFavorited: { _ in false })
        )
    }

    func test_favoritePeerIsRestorable() {
        // A persisted favorite is stored by stable Noise public key and survives
        // restart — the one durable, presence-independent mesh relationship.
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(peerID, isPeerFavorited: { _ in true })
        )
    }

    func test_geoDMPeerIsRestorable_withoutFavorite() {
        // Geohash/Nostr DM ids embed a stable Nostr identity in the id itself,
        // so they are restorable even though they are not favorites.
        let geoDMPeer = PeerID(str: "nostr_0123456789abcdef")
        XCTAssertTrue(geoDMPeer.isGeoDM)
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(geoDMPeer, isPeerFavorited: { _ in false })
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
                AppRuntime.isDirectChatRestorable($0, isPeerFavorited: { _ in false })
            }
        )

        XCTAssertEqual(restored, .conversationList)
    }

    // MARK: - Production wiring (real FavoritesPersistenceService)

    func test_production_fullHexFavoritePeerIsRestorable() {
        // migrateSelectedConversationIfNeeded persists the peer in FULL 64-hex
        // Noise-key form; the favorites store is keyed by the short derived id.
        // The production resolver must normalize (`toShort()`) so a favorited DM
        // still restores. Regression for fix-round-3 finding 1.
        let favorites = FavoritesPersistenceService(keychain: MockKeychain())
        let noiseKey = Data((0..<32).map(UInt8.init))
        favorites.addFavorite(peerNoisePublicKey: noiseKey, peerNickname: "Alice")

        let fullHexPeer = PeerID(str: noiseKey.hexEncodedString())
        XCTAssertFalse(fullHexPeer.isShort) // 64-hex, not the short form
        XCTAssertTrue(
            AppRuntime.isDirectChatRestorable(fullHexPeer, favorites: favorites)
        )
    }

    func test_production_unknownShortPeerIsNotRestorable() {
        // A syntactically valid short peer with no favorite relationship must
        // NOT restore (would otherwise open an empty phantom DM). Pins the real
        // wiring so it cannot drift back to a syntax-only check.
        let favorites = FavoritesPersistenceService(keychain: MockKeychain())
        XCTAssertTrue(peerID.isValid)
        XCTAssertFalse(
            AppRuntime.isDirectChatRestorable(peerID, favorites: favorites)
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
            AppRuntime.isDirectChatRestorable(fullHexPeer, favorites: favorites)
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
