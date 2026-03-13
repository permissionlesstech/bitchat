import XCTest
@testable import bitchat

@MainActor
final class FavoritesPersistenceServiceTests: XCTestCase {
    private let storageKey = "chat.bitchat.favorites"
    private let serviceKey = "chat.bitchat.favorites"

    func test_addFavorite_persistsAndPostsNotification() throws {
        let keychain = MockKeychain()
        let service = FavoritesPersistenceService(keychain: keychain)
        let peerKey = Data((0..<32).map(UInt8.init))
        let expectation = expectation(forNotification: .favoriteStatusChanged, object: nil)

        service.addFavorite(peerNoisePublicKey: peerKey, peerNostrPublicKey: "npub1alice", peerNickname: "Alice")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(service.isFavorite(peerKey))
        XCTAssertEqual(service.getFavoriteStatus(for: peerKey)?.peerNickname, "Alice")
        XCTAssertNotNil(keychain.load(key: storageKey, service: serviceKey))
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

    func test_getFavoriteStatus_forPeerID_returnsMutualFavorite() {
        let service = FavoritesPersistenceService(keychain: MockKeychain())
        let peerKey = Data((96..<128).map(UInt8.init))

        service.addFavorite(peerNoisePublicKey: peerKey, peerNostrPublicKey: "npub1dan", peerNickname: "Dan")
        service.updatePeerFavoritedUs(peerNoisePublicKey: peerKey, favorited: true, peerNickname: "Dan")

        let relationship = service.getFavoriteStatus(forPeerID: PeerID(publicKey: peerKey))
        XCTAssertEqual(relationship?.peerNickname, "Dan")
        XCTAssertTrue(service.isMutualFavorite(peerKey))
    }

    func test_init_deduplicatesPersistedRelationshipsByPublicKey() throws {
        let keychain = MockKeychain()
        let peerKey = Data((128..<160).map(UInt8.init))
        let older = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: nil,
            peerNickname: "Older",
            isFavorite: true,
            theyFavoritedUs: false,
            favoritedAt: Date(timeIntervalSince1970: 100),
            lastUpdated: Date(timeIntervalSince1970: 100)
        )
        let newer = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: "npub1newer",
            peerNickname: "Newer",
            isFavorite: true,
            theyFavoritedUs: true,
            favoritedAt: Date(timeIntervalSince1970: 100),
            lastUpdated: Date(timeIntervalSince1970: 200)
        )
        let encoded = try JSONEncoder().encode([older, newer])
        keychain.save(key: storageKey, data: encoded, service: serviceKey, accessible: nil)

        let service = FavoritesPersistenceService(keychain: keychain)

        XCTAssertEqual(service.favorites.count, 1)
        XCTAssertEqual(service.getFavoriteStatus(for: peerKey)?.peerNickname, "Newer")
        XCTAssertEqual(service.getFavoriteStatus(for: peerKey)?.peerNostrPublicKey, "npub1newer")

        let cleaned = try XCTUnwrap(keychain.load(key: storageKey, service: serviceKey))
        let decoded = try JSONDecoder().decode([FavoritesPersistenceService.FavoriteRelationship].self, from: cleaned)
        XCTAssertEqual(decoded.count, 1)
    }
}
