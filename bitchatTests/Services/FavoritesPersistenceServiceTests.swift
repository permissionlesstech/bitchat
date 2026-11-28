import XCTest
import BitFoundation
@testable import bitchat

@MainActor
final class FavoritesPersistenceServiceTests: XCTestCase {
    private let storageKey = "chat.bitchat.favorites"
    private let serviceKey = "chat.bitchat.favorites"

    func test_addFavorite_persistsAndPostsNotification() throws {
        let keychain = MockKeychain()
        let service = FavoritesPersistenceService(keychain: keychain)
        let peerKey = Data((0..<32).map(UInt8.init))
        let aliceNpub = try NostrIdentity.generate().npub
        let expectation = expectation(forNotification: .favoriteStatusChanged, object: nil)

        let added = service.addFavorite(peerNoisePublicKey: peerKey, peerNostrPublicKey: aliceNpub, peerNickname: "Alice")

        wait(for: [expectation], timeout: TestConstants.settleTimeout)
        XCTAssertTrue(added)
        XCTAssertTrue(service.isFavorite(peerKey))
        XCTAssertEqual(service.getFavoriteStatus(for: peerKey)?.peerNickname, "Alice")
        XCTAssertEqual(service.getFavoriteStatus(for: peerKey)?.peerNostrPublicKey, aliceNpub)
        XCTAssertNotNil(keychain.load(key: storageKey, service: serviceKey))
    }

    func test_addFavorite_rejectsInvalidNoiseKeyAndInvalidNpubAndPreservesNickname() throws {
        let service = FavoritesPersistenceService(keychain: MockKeychain())

        XCTAssertFalse(service.addFavorite(peerNoisePublicKey: Data(), peerNickname: "Empty"))
        XCTAssertFalse(service.addFavorite(peerNoisePublicKey: Data(repeating: 0x11, count: 16), peerNickname: "Short"))
        XCTAssertTrue(service.favorites.isEmpty)

        let peerKey = Data((10..<42).map(UInt8.init))
        XCTAssertTrue(service.addFavorite(peerNoisePublicKey: peerKey, peerNostrPublicKey: "npub1notvalidbech32", peerNickname: "Alice"))
        XCTAssertNil(service.getFavoriteStatus(for: peerKey)?.peerNostrPublicKey)

        // Unknown/empty nickname must not clobber a real stored nickname.
        XCTAssertTrue(service.addFavorite(peerNoisePublicKey: peerKey, peerNickname: "Unknown"))
        XCTAssertEqual(service.getFavoriteStatus(for: peerKey)?.peerNickname, "Alice")
        XCTAssertTrue(service.addFavorite(peerNoisePublicKey: peerKey, peerNickname: ""))
        XCTAssertEqual(service.getFavoriteStatus(for: peerKey)?.peerNickname, "Alice")
    }

    func test_removeFavorite_preservesRelationshipWhenPeerStillFavoritesUs() {
        let service = FavoritesPersistenceService(keychain: MockKeychain())
        let peerKey = Data((32..<64).map(UInt8.init))

        service.updatePeerFavoritedUs(peerNoisePublicKey: peerKey, favorited: true, peerNickname: "Bob")
        service.addFavorite(peerNoisePublicKey: peerKey, peerNickname: "Bob")
        service.removeFavorite(peerNoisePublicKey: peerKey)

        let relationship = service.getFavoriteStatus(for: peerKey)
        XCTAssertNotNil(relationship)
        XCTAssertEqual(relationship?.peerNickname, "Bob")
        XCTAssertFalse(relationship?.isFavorite ?? true)
        XCTAssertTrue(relationship?.theyFavoritedUs ?? false)
    }

    func test_updatePeerFavoritedUs_removesRelationshipWhenNeitherSideFavorites() {
        let service = FavoritesPersistenceService(keychain: MockKeychain())
        let peerKey = Data((64..<96).map(UInt8.init))

        service.updatePeerFavoritedUs(peerNoisePublicKey: peerKey, favorited: true, peerNickname: "Carol")
        XCTAssertNotNil(service.getFavoriteStatus(for: peerKey))

        service.updatePeerFavoritedUs(peerNoisePublicKey: peerKey, favorited: false, peerNickname: "Carol")

        XCTAssertNil(service.getFavoriteStatus(for: peerKey))
        XCTAssertFalse(service.isMutualFavorite(peerKey))
    }

    func test_updatePeerFavoritedUs_keepsStoredNicknameOverUnknownPlaceholder() {
        let service = FavoritesPersistenceService(keychain: MockKeychain())
        let peerKey = Data((128..<160).map(UInt8.init))

        service.addFavorite(peerNoisePublicKey: peerKey, peerNickname: "Erin")

        // A notification arriving before the peer is known passes "Unknown".
        service.updatePeerFavoritedUs(peerNoisePublicKey: peerKey, favorited: true, peerNickname: "Unknown")
        XCTAssertEqual(service.getFavoriteStatus(for: peerKey)?.peerNickname, "Erin")

        // A real nickname still updates the stored one.
        service.updatePeerFavoritedUs(peerNoisePublicKey: peerKey, favorited: true, peerNickname: "Erin2")
        XCTAssertEqual(service.getFavoriteStatus(for: peerKey)?.peerNickname, "Erin2")
    }

    func test_getFavoriteStatus_forPeerID_returnsMutualFavorite() throws {
        let service = FavoritesPersistenceService(keychain: MockKeychain())
        let peerKey = Data((96..<128).map(UInt8.init))
        let danNpub = try NostrIdentity.generate().npub

        service.addFavorite(peerNoisePublicKey: peerKey, peerNostrPublicKey: danNpub, peerNickname: "Dan")
        service.updatePeerFavoritedUs(peerNoisePublicKey: peerKey, favorited: true, peerNickname: "Dan")

        let relationship = service.getFavoriteStatus(forPeerID: PeerID(publicKey: peerKey))
        XCTAssertEqual(relationship?.peerNickname, "Dan")
        XCTAssertTrue(service.isMutualFavorite(peerKey))
    }

    func test_init_deduplicatesPersistedRelationshipsByPublicKey() throws {
        let keychain = MockKeychain()
        let peerKey = Data((128..<160).map(UInt8.init))
        let olderNpub = try NostrIdentity.generate().npub
        let older = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: olderNpub,
            peerNickname: "Older",
            isFavorite: true,
            theyFavoritedUs: false,
            favoritedAt: Date(timeIntervalSince1970: 100),
            lastUpdated: Date(timeIntervalSince1970: 100)
        )
        // Newer record has updated flags (mutual) but nil npub — dedup must
        // keep the newer record's flags while backfilling the older npub.
        let newer = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: nil,
            peerNickname: "Newer",
            isFavorite: true,
            theyFavoritedUs: true,
            favoritedAt: Date(timeIntervalSince1970: 120),
            lastUpdated: Date(timeIntervalSince1970: 200)
        )
        let encoded = try JSONEncoder().encode([older, newer])
        keychain.save(key: storageKey, data: encoded, service: serviceKey, accessible: nil)

        let service = FavoritesPersistenceService(keychain: keychain)

        XCTAssertEqual(service.favorites.count, 1)
        let merged = try XCTUnwrap(service.getFavoriteStatus(for: peerKey))
        XCTAssertEqual(merged.peerNickname, "Newer")
        XCTAssertEqual(merged.peerNostrPublicKey, olderNpub)
        XCTAssertTrue(merged.isMutual)
        XCTAssertEqual(merged.favoritedAt, Date(timeIntervalSince1970: 100))

        let cleaned = try XCTUnwrap(keychain.load(key: storageKey, service: serviceKey))
        let decoded = try JSONDecoder().decode([FavoritesPersistenceService.FavoriteRelationship].self, from: cleaned)
        XCTAssertEqual(decoded.count, 1)
    }

    func test_noisePublicKey_indexesBothNpubAndHexKeys() throws {
        let service = FavoritesPersistenceService(keychain: MockKeychain())
        let peerKey = Data((160..<192).map(UInt8.init))
        let identity = try NostrIdentity.generate()

        service.addFavorite(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: identity.npub,
            peerNickname: "Frank"
        )

        XCTAssertEqual(service.noisePublicKey(forNostrPubkey: identity.npub), peerKey)
        XCTAssertEqual(service.noisePublicKey(forNostrPubkey: identity.publicKeyHex), peerKey)
        XCTAssertEqual(service.noisePublicKey(forNostrPubkey: identity.publicKeyHex.uppercased()), peerKey)

        service.removeFavorite(peerNoisePublicKey: peerKey)
        XCTAssertNil(service.noisePublicKey(forNostrPubkey: identity.npub))
        XCTAssertNil(service.noisePublicKey(forNostrPubkey: identity.publicKeyHex))
    }

    func test_lockedBoot_doesNotOverwriteExistingFavoritesOnLaterMutation() throws {
        let keychain = MockKeychain()
        let existingKey = Data((200..<232).map(UInt8.init))
        let existingNpub = try NostrIdentity.generate().npub
        let existing = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: existingKey,
            peerNostrPublicKey: existingNpub,
            peerNickname: "Existing",
            isFavorite: true,
            theyFavoritedUs: true,
            favoritedAt: Date(),
            lastUpdated: Date()
        )
        let encoded = try JSONEncoder().encode([existing])
        keychain.save(key: storageKey, data: encoded, service: serviceKey, accessible: nil)

        // Launch while locked: load fails with .deviceLocked.
        keychain.simulatedGenericReadError = .deviceLocked
        let service = FavoritesPersistenceService(keychain: keychain)
        XCTAssertTrue(service.favorites.isEmpty)

        // A mutation during locked boot must NOT overwrite the existing keychain entry.
        let newKey = Data((220..<252).map(UInt8.init))
        service.addFavorite(peerNoisePublicKey: newKey, peerNickname: "NewDuringLock")

        keychain.simulatedGenericReadError = nil
        let reloadedBeforeRecovery = FavoritesPersistenceService(keychain: keychain)
        XCTAssertEqual(reloadedBeforeRecovery.favorites.count, 1)
        XCTAssertEqual(reloadedBeforeRecovery.getFavoriteStatus(for: existingKey)?.peerNickname, "Existing")

        // Once protected data unlocks, retryDeferredLoad recovers durable
        // favorites AND merges + persists the in-session mutation.
        service.retryDeferredLoad()
        XCTAssertEqual(service.favorites.count, 2)
        XCTAssertEqual(service.getFavoriteStatus(for: existingKey)?.peerNickname, "Existing")
        XCTAssertEqual(service.getFavoriteStatus(for: newKey)?.peerNickname, "NewDuringLock")

        let reloadedAfterRecovery = FavoritesPersistenceService(keychain: keychain)
        XCTAssertEqual(reloadedAfterRecovery.favorites.count, 2)
    }

    /// Replaying deferred mutations during locked boot must preserve durable
    /// fields that were NOT modified during the locked window (e.g., receiving
    /// `[FAVORITED]` from an already-favorited peer must upgrade to mutual,
    /// not overwrite `isFavorite` with `false`; and receiving `[UNFAVORITED]`
    /// must clear `theyFavoritedUs`).
    func test_lockedBoot_replaysPeerFavoriteNotificationsWithoutClobberingDurableFlags() throws {
        let keychain = MockKeychain()
        let peerAKey = Data((10..<42).map(UInt8.init))
        let peerBKey = Data((50..<82).map(UInt8.init))
        let peerANpub = try NostrIdentity.generate().npub
        let peerBNpub = try NostrIdentity.generate().npub
        let durableRecords = [
            FavoritesPersistenceService.FavoriteRelationship(
                peerNoisePublicKey: peerAKey,
                peerNostrPublicKey: nil,
                peerNickname: "Alice",
                isFavorite: true,
                theyFavoritedUs: false,
                favoritedAt: Date(timeIntervalSince1970: 100),
                lastUpdated: Date(timeIntervalSince1970: 100)
            ),
            FavoritesPersistenceService.FavoriteRelationship(
                peerNoisePublicKey: peerBKey,
                peerNostrPublicKey: peerBNpub,
                peerNickname: "Bob",
                isFavorite: true,
                theyFavoritedUs: true,
                favoritedAt: Date(timeIntervalSince1970: 100),
                lastUpdated: Date(timeIntervalSince1970: 100)
            )
        ]
        keychain.save(
            key: storageKey,
            data: try JSONEncoder().encode(durableRecords),
            service: serviceKey,
            accessible: nil
        )

        keychain.simulatedGenericReadError = .deviceLocked
        let service = FavoritesPersistenceService(keychain: keychain)
        XCTAssertTrue(service.favorites.isEmpty)

        // While locked, Alice sends [FAVORITED] and Bob sends [UNFAVORITED].
        service.updatePeerFavoritedUs(
            peerNoisePublicKey: peerAKey,
            favorited: true,
            peerNickname: "Unknown",
            peerNostrPublicKey: peerANpub
        )
        service.updatePeerFavoritedUs(
            peerNoisePublicKey: peerBKey,
            favorited: false,
            peerNickname: "Bob"
        )

        keychain.simulatedGenericReadError = nil
        service.retryDeferredLoad()

        let recoveredA = try XCTUnwrap(service.getFavoriteStatus(for: peerAKey))
        XCTAssertTrue(recoveredA.isFavorite)
        XCTAssertTrue(recoveredA.theyFavoritedUs)
        XCTAssertTrue(recoveredA.isMutual)
        XCTAssertEqual(recoveredA.peerNickname, "Alice")
        XCTAssertEqual(recoveredA.peerNostrPublicKey, peerANpub)

        let recoveredB = try XCTUnwrap(service.getFavoriteStatus(for: peerBKey))
        XCTAssertTrue(recoveredB.isFavorite)
        XCTAssertFalse(recoveredB.theyFavoritedUs)
        XCTAssertFalse(recoveredB.isMutual)
        XCTAssertEqual(recoveredB.peerNostrPublicKey, peerBNpub)
    }

    func test_establishMutualFavorite_atomicallySetsBothSides() throws {
        let service = FavoritesPersistenceService(keychain: MockKeychain())
        let peerKey = Data((1..<33).map(UInt8.init))
        let npub = try NostrIdentity.generate().npub

        XCTAssertTrue(service.establishMutualFavorite(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: npub,
            peerNickname: "Grace"
        ))
        XCTAssertTrue(service.isMutualFavorite(peerKey))
        XCTAssertEqual(service.getFavoriteStatus(for: peerKey)?.peerNostrPublicKey, npub)
    }
}
