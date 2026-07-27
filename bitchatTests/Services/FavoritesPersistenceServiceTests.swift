import XCTest
import BitFoundation
@testable import bitchat

@MainActor
final class FavoritesPersistenceServiceTests: XCTestCase {
    private let storageKey = "chat.bitchat.favorites"
    private let serviceKey = "chat.bitchat.favorites"
    private let rebindJournalKey =
        "chat.bitchat.favorites.ndr-rebind-journal"
    private let ndrRequiredKey =
        "chat.bitchat.favorites.ndr-required-noise-keys"

    func test_addFavorite_persistsAndPostsNotification() throws {
        let keychain = MockKeychain()
        let service = FavoritesPersistenceService(keychain: keychain)
        let peerKey = Data((0..<32).map(UInt8.init))
        let expectation = expectation(forNotification: .favoriteStatusChanged, object: nil)

        service.addFavorite(peerNoisePublicKey: peerKey, peerNostrPublicKey: "npub1alice", peerNickname: "Alice")

        wait(for: [expectation], timeout: TestConstants.settleTimeout)
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

    func test_preNdrIdentityRebindDoesNotPinOrRetire() {
        let keychain = MockKeychain()
        let service = FavoritesPersistenceService(keychain: keychain)
        let peerKey = Data(repeating: 0x41, count: 32)
        let owner = UUID()
        var commitCalled = false
        service.addFavorite(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: "old",
            peerNickname: "Pre-NDR"
        )
        service.installNostrIdentityRebindAuthorization(
            owner: owner,
            required: true,
            authorize: { _, _, _ in true },
            commit: { _, _, _ in
                commitCalled = true
                return true
            }
        )

        service.updatePeerFavoritedUs(
            peerNoisePublicKey: peerKey,
            favorited: true,
            peerNostrPublicKey: "new"
        )

        XCTAssertEqual(
            service.getFavoriteStatus(for: peerKey)?
                .peerNostrPublicKey,
            "new"
        )
        XCTAssertFalse(commitCalled)
        XCTAssertFalse(service.isNdrRequired(for: peerKey))
        XCTAssertFalse(
            service.isNdrFallbackBlocked(
                for: PeerID(publicKey: peerKey)
            )
        )
    }

    func test_postSessionRebindJournalsBeforeRetireAndPreservesPin()
        throws
    {
        let keychain = MockKeychain()
        let service = FavoritesPersistenceService(keychain: keychain)
        let peerKey = Data(repeating: 0x42, count: 32)
        service.addFavorite(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: "old",
            peerNickname: "Pinned"
        )
        XCTAssertTrue(service.markNdrRequired(for: peerKey))
        var commitCalled = false
        service.installNostrIdentityRebindAuthorization(
            owner: UUID(),
            required: true,
            authorize: { _, _, _ in true },
            commit: { _, old, new in
                commitCalled = true
                XCTAssertEqual(old, "old")
                XCTAssertEqual(new, "new")
                XCTAssertNotNil(
                    keychain.load(
                        key: self.rebindJournalKey,
                        service: self.serviceKey
                    )
                )
                let stored = try? JSONDecoder().decode(
                    [FavoritesPersistenceService.FavoriteRelationship].self,
                    from: keychain.load(
                        key: self.storageKey,
                        service: self.serviceKey
                    ) ?? Data()
                )
                XCTAssertEqual(
                    stored?.first?.peerNostrPublicKey,
                    "old"
                )
                return true
            }
        )

        service.updatePeerFavoritedUs(
            peerNoisePublicKey: peerKey,
            favorited: true,
            peerNostrPublicKey: "new"
        )

        XCTAssertTrue(commitCalled)
        XCTAssertEqual(
            service.getFavoriteStatus(for: peerKey)?
                .peerNostrPublicKey,
            "new"
        )
        XCTAssertTrue(service.isNdrRequired(for: peerKey))
        XCTAssertNil(
            keychain.load(
                key: rebindJournalKey,
                service: serviceKey
            )
        )
    }

    func test_failedFavoriteCommitKeepsJournalAndRecoversOnRestart() {
        let keychain = MockKeychain()
        let peerKey = Data(repeating: 0x43, count: 32)
        let first = FavoritesPersistenceService(keychain: keychain)
        first.addFavorite(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: "old",
            peerNickname: "Recoverable"
        )
        XCTAssertTrue(first.markNdrRequired(for: peerKey))
        first.installNostrIdentityRebindAuthorization(
            owner: UUID(),
            required: true,
            authorize: { _, _, _ in true },
            commit: { _, _, _ in true }
        )
        keychain.simulatedGenericSaveFailureKeys.insert(storageKey)

        first.updatePeerFavoritedUs(
            peerNoisePublicKey: peerKey,
            favorited: true,
            peerNostrPublicKey: "new"
        )

        XCTAssertEqual(
            first.getFavoriteStatus(for: peerKey)?
                .peerNostrPublicKey,
            "old"
        )
        XCTAssertNotNil(
            keychain.load(
                key: rebindJournalKey,
                service: serviceKey
            )
        )
        XCTAssertTrue(
            first.isNdrFallbackBlocked(
                for: PeerID(publicKey: peerKey)
            )
        )

        let restarted = FavoritesPersistenceService(keychain: keychain)
        XCTAssertFalse(
            restarted.canUseNdrBinding(
                for: PeerID(publicKey: peerKey)
            )
        )
        XCTAssertTrue(
            restarted.isNdrFallbackBlocked(
                for: PeerID(publicKey: peerKey)
            )
        )

        keychain.simulatedGenericSaveFailureKeys.remove(storageKey)
        restarted.installNostrIdentityRebindAuthorization(
            owner: UUID(),
            required: true,
            authorize: { _, _, _ in true },
            commit: { _, _, _ in true }
        )

        XCTAssertEqual(
            restarted.getFavoriteStatus(for: peerKey)?
                .peerNostrPublicKey,
            "new"
        )
        XCTAssertTrue(restarted.isNdrRequired(for: peerKey))
        XCTAssertNil(
            keychain.load(
                key: rebindJournalKey,
                service: serviceKey
            )
        )
    }

    func test_recoveryTreatsEquivalentHexAndNpubJournalIdentityAsSame()
        throws
    {
        let keychain = MockKeychain()
        let peerKey = Data(repeating: 0x4a, count: 32)
        let oldIdentity = try NostrIdentity.generate()
        let targetIdentity = try NostrIdentity.generate()
        let first = FavoritesPersistenceService(keychain: keychain)
        first.addFavorite(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: oldIdentity.npub,
            peerNickname: "Equivalent recovery"
        )
        XCTAssertTrue(first.markNdrRequired(for: peerKey))
        first.installNostrIdentityRebindAuthorization(
            owner: UUID(),
            required: true,
            authorize: { _, _, _ in true },
            commit: { _, _, _ in true }
        )
        keychain.simulatedGenericSaveFailureKeys.insert(storageKey)
        first.updatePeerFavoritedUs(
            peerNoisePublicKey: peerKey,
            favorited: true,
            peerNostrPublicKey: targetIdentity.npub
        )
        keychain.simulatedGenericSaveFailureKeys.remove(storageKey)

        let storedData = try XCTUnwrap(
            keychain.load(key: storageKey, service: serviceKey)
        )
        let storedRelationships = try JSONDecoder().decode(
            [FavoritesPersistenceService.FavoriteRelationship].self,
            from: storedData
        )
        let stored = try XCTUnwrap(storedRelationships.first)
        let equivalentOld = FavoritesPersistenceService
            .FavoriteRelationship(
                peerNoisePublicKey: stored.peerNoisePublicKey,
                peerNostrPublicKey:
                    oldIdentity.publicKeyHex.uppercased(),
                peerNickname: stored.peerNickname,
                isFavorite: stored.isFavorite,
                theyFavoritedUs: stored.theyFavoritedUs,
                favoritedAt: stored.favoritedAt,
                lastUpdated: stored.lastUpdated
            )
        keychain.save(
            key: storageKey,
            data: try JSONEncoder().encode([equivalentOld]),
            service: serviceKey,
            accessible: nil
        )

        let restarted = FavoritesPersistenceService(keychain: keychain)
        restarted.installNostrIdentityRebindAuthorization(
            owner: UUID(),
            required: true,
            authorize: { _, _, _ in true },
            commit: { _, _, _ in true }
        )

        XCTAssertEqual(
            restarted.getFavoriteStatus(for: peerKey)?
                .peerNostrPublicKey,
            targetIdentity.npub
        )
        XCTAssertNil(
            keychain.load(
                key: rebindJournalKey,
                service: serviceKey
            )
        )
    }

    func test_equivalentHexAndNpubIdentityUpdateIsANondestructiveNoop()
        throws
    {
        let keychain = MockKeychain()
        let service = FavoritesPersistenceService(keychain: keychain)
        let peerKey = Data(repeating: 0x44, count: 32)
        let identity = try NostrIdentity.generate()
        let storedHex = identity.publicKeyHex.uppercased()
        service.addFavorite(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: storedHex,
            peerNickname: "Equivalent"
        )
        XCTAssertTrue(service.markNdrRequired(for: peerKey))
        var authorizeCalled = false
        var commitCalled = false
        service.installNostrIdentityRebindAuthorization(
            owner: UUID(),
            required: true,
            authorize: { _, _, _ in
                authorizeCalled = true
                return true
            },
            commit: { _, _, _ in
                commitCalled = true
                return true
            }
        )

        service.updatePeerFavoritedUs(
            peerNoisePublicKey: peerKey,
            favorited: true,
            peerNostrPublicKey: identity.npub
        )

        XCTAssertEqual(
            service.getFavoriteStatus(for: peerKey)?
                .peerNostrPublicKey,
            storedHex
        )
        XCTAssertFalse(authorizeCalled)
        XCTAssertFalse(commitCalled)
        XCTAssertNil(
            keychain.load(
                key: rebindJournalKey,
                service: serviceKey
            )
        )
    }

    func test_pendingJournalReservesTargetAcrossFavoritesAndRestart()
        throws
    {
        let keychain = MockKeychain()
        let firstNoiseKey = Data(repeating: 0x45, count: 32)
        let secondNoiseKey = Data(repeating: 0x46, count: 32)
        let firstOld = try NostrIdentity.generate()
        let secondOld = try NostrIdentity.generate()
        let target = try NostrIdentity.generate()
        let first = FavoritesPersistenceService(keychain: keychain)
        first.addFavorite(
            peerNoisePublicKey: firstNoiseKey,
            peerNostrPublicKey: firstOld.npub,
            peerNickname: "First"
        )
        first.addFavorite(
            peerNoisePublicKey: secondNoiseKey,
            peerNostrPublicKey: secondOld.npub,
            peerNickname: "Second"
        )
        XCTAssertTrue(first.markNdrRequired(for: firstNoiseKey))
        first.installNostrIdentityRebindAuthorization(
            owner: UUID(),
            required: true,
            authorize: { _, _, _ in true },
            commit: { _, _, _ in true }
        )
        keychain.simulatedGenericSaveFailureKeys.insert(storageKey)
        first.updatePeerFavoritedUs(
            peerNoisePublicKey: firstNoiseKey,
            favorited: true,
            peerNostrPublicKey: target.npub
        )
        XCTAssertNotNil(
            keychain.load(
                key: rebindJournalKey,
                service: serviceKey
            )
        )

        keychain.simulatedGenericSaveFailureKeys.remove(storageKey)
        first.updatePeerFavoritedUs(
            peerNoisePublicKey: secondNoiseKey,
            favorited: true,
            peerNostrPublicKey: target.npub
        )
        XCTAssertEqual(
            first.getFavoriteStatus(for: secondNoiseKey)?
                .peerNostrPublicKey,
            secondOld.npub
        )

        let restarted = FavoritesPersistenceService(keychain: keychain)
        restarted.installNostrIdentityRebindAuthorization(
            owner: UUID(),
            required: true,
            authorize: { _, _, _ in true },
            commit: { _, _, _ in true }
        )
        XCTAssertEqual(
            restarted.getFavoriteStatus(for: firstNoiseKey)?
                .peerNostrPublicKey,
            target.npub
        )
        XCTAssertEqual(
            restarted.getFavoriteStatus(for: secondNoiseKey)?
                .peerNostrPublicKey,
            secondOld.npub
        )
        XCTAssertNil(
            keychain.load(
                key: rebindJournalKey,
                service: serviceKey
            )
        )
    }

    func test_journalClearFailureAllowsCommittedTargetButBlocksFallback()
        throws
    {
        let keychain = MockKeychain()
        let service = FavoritesPersistenceService(keychain: keychain)
        let peerKey = Data(repeating: 0x47, count: 32)
        let oldIdentity = try NostrIdentity.generate()
        let targetIdentity = try NostrIdentity.generate()
        service.addFavorite(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: oldIdentity.npub,
            peerNickname: "Clear failure"
        )
        XCTAssertTrue(service.markNdrRequired(for: peerKey))
        service.installNostrIdentityRebindAuthorization(
            owner: UUID(),
            required: true,
            authorize: { _, _, _ in true },
            commit: { _, _, _ in true }
        )
        keychain.simulatedGenericDeleteFailureKeys.insert(
            rebindJournalKey
        )

        service.updatePeerFavoritedUs(
            peerNoisePublicKey: peerKey,
            favorited: true,
            peerNostrPublicKey: targetIdentity.npub
        )

        XCTAssertEqual(
            service.getFavoriteStatus(for: peerKey)?
                .peerNostrPublicKey,
            targetIdentity.npub
        )
        XCTAssertNotNil(
            keychain.load(
                key: rebindJournalKey,
                service: serviceKey
            )
        )
        XCTAssertTrue(
            service.canUseNdrBinding(
                peerNoisePublicKey: peerKey,
                peerNostrPublicKey: targetIdentity.npub
            )
        )
        XCTAssertTrue(
            service.canUseNdrBinding(
                for: PeerID(publicKey: peerKey)
            )
        )
        XCTAssertTrue(service.canActivateDoubleRatchetRelay)
        XCTAssertTrue(
            service.isNdrFallbackBlocked(
                for: PeerID(publicKey: peerKey)
            )
        )
    }

    func test_pinWriteFailureFailsClosedForBindingsAndLegacyInbound()
        throws
    {
        let keychain = MockKeychain()
        let service = FavoritesPersistenceService(keychain: keychain)
        let peerKey = Data(repeating: 0x48, count: 32)
        let identity = try NostrIdentity.generate()
        service.addFavorite(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: identity.npub,
            peerNickname: "Pin failure"
        )
        keychain.simulatedGenericSaveFailureKeys.insert(ndrRequiredKey)

        XCTAssertFalse(service.markNdrRequired(for: peerKey))
        XCTAssertNil(
            keychain.load(
                key: ndrRequiredKey,
                service: serviceKey
            )
        )
        XCTAssertTrue(service.isNdrRequired(for: peerKey))
        XCTAssertFalse(
            service.canUseNdrBinding(
                for: PeerID(publicKey: peerKey)
            )
        )
        XCTAssertFalse(service.canActivateDoubleRatchetRelay)
        XCTAssertFalse(
            service.canAcceptLegacyNostrDM(
                from: identity.publicKeyHex
            )
        )
    }

    func test_legacyInboundPolicyRejectsPinnedAndJournalIdentities()
        throws
    {
        let keychain = MockKeychain()
        let service = FavoritesPersistenceService(keychain: keychain)
        let peerKey = Data(repeating: 0x49, count: 32)
        let oldIdentity = try NostrIdentity.generate()
        let targetIdentity = try NostrIdentity.generate()
        let unrelatedIdentity = try NostrIdentity.generate()
        service.addFavorite(
            peerNoisePublicKey: peerKey,
            peerNostrPublicKey: oldIdentity.npub,
            peerNickname: "Inbound"
        )
        XCTAssertTrue(service.markNdrRequired(for: peerKey))
        XCTAssertFalse(
            service.canAcceptLegacyNostrDM(
                from: oldIdentity.publicKeyHex
            )
        )
        XCTAssertTrue(
            service.canAcceptLegacyNostrDM(
                from: unrelatedIdentity.publicKeyHex
            )
        )
        service.installNostrIdentityRebindAuthorization(
            owner: UUID(),
            required: true,
            authorize: { _, _, _ in true },
            commit: { _, _, _ in true }
        )
        keychain.simulatedGenericSaveFailureKeys.insert(storageKey)
        service.updatePeerFavoritedUs(
            peerNoisePublicKey: peerKey,
            favorited: true,
            peerNostrPublicKey: targetIdentity.npub
        )

        XCTAssertFalse(
            service.canAcceptLegacyNostrDM(
                from: oldIdentity.publicKeyHex
            )
        )
        XCTAssertFalse(
            service.canAcceptLegacyNostrDM(
                from: targetIdentity.publicKeyHex
            )
        )
    }
}
