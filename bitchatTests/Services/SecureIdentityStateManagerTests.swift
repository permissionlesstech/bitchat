import Foundation
import XCTest
import BitFoundation
@testable import bitchat

final class SecureIdentityStateManagerTests: XCTestCase {
    func test_upsertCryptographicIdentity_withoutClaimedNicknameDoesNotCreateSocialIdentity() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "aa", count: 32)
        let peerID = PeerID(str: String(fingerprint.prefix(16)))

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            claimedNickname: nil
        )

        let inserted = await waitUntil {
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).count == 1
        }
        XCTAssertTrue(inserted)
        XCTAssertNil(manager.getSocialIdentity(for: fingerprint))
    }

    func test_upsertCryptographicIdentity_updatesExistingKeyAndPreservesSigningKey() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "ab", count: 32)
        let peerID = PeerID(str: String(fingerprint.prefix(16)))
        let originalNoiseKey = Data(repeating: 0x11, count: 32)
        let updatedNoiseKey = Data(repeating: 0x33, count: 32)
        let signingKey = Data(repeating: 0x22, count: 32)

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: originalNoiseKey,
            signingPublicKey: signingKey,
            claimedNickname: nil
        )
        _ = await waitUntil {
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.publicKey == originalNoiseKey
        }

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: updatedNoiseKey,
            signingPublicKey: nil,
            claimedNickname: nil
        )

        let updated = await waitUntil {
            guard let identity = manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first else { return false }
            return identity.publicKey == updatedNoiseKey && identity.signingPublicKey == signingKey
        }
        XCTAssertTrue(updated)
    }

    func test_upsertCryptographicIdentity_tracksByPeerIDPrefixAndClaimedNickname() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let noisePublicKey = Data(repeating: 0x11, count: 32)
        let signingPublicKey = Data(repeating: 0x22, count: 32)
        let fingerprint = noisePublicKey.sha256Fingerprint()

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            claimedNickname: "Alice"
        )

        let socialIdentityLoaded = await waitUntil {
            manager.getSocialIdentity(for: fingerprint)?.claimedNickname == "Alice"
        }
        XCTAssertTrue(socialIdentityLoaded)
        let matches = manager.getCryptoIdentitiesByPeerIDPrefix(PeerID(publicKey: noisePublicKey))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.fingerprint, fingerprint)
        XCTAssertEqual(matches.first?.publicKey, noisePublicKey)
        XCTAssertEqual(matches.first?.signingPublicKey, signingPublicKey)
    }

    func test_upsertCryptographicIdentity_refusesToReplacePinnedSigningKey() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let noisePublicKey = Data(repeating: 0x11, count: 32)
        let fingerprint = noisePublicKey.sha256Fingerprint()
        let peerID = PeerID(publicKey: noisePublicKey)
        let victimSigningKey = Data(repeating: 0x22, count: 32)
        let attackerSigningKey = Data(repeating: 0x66, count: 32)

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: victimSigningKey,
            claimedNickname: "victim"
        )
        let pinned = await waitUntil {
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey == victimSigningKey
        }
        XCTAssertTrue(pinned)

        // Attacker upsert with a different signing key must be refused in
        // full — signing key AND claimed nickname stay the victim's.
        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: attackerSigningKey,
            claimedNickname: "attacker"
        )

        // Synchronous reads fence the manager's pending barrier writes.
        XCTAssertEqual(
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey,
            victimSigningKey
        )
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.claimedNickname, "victim")

        // The legitimate peer (same signing key) can still update.
        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: victimSigningKey,
            claimedNickname: "victim-renamed"
        )
        let renamed = await waitUntil {
            manager.getSocialIdentity(for: fingerprint)?.claimedNickname == "victim-renamed"
        }
        XCTAssertTrue(renamed)
        XCTAssertEqual(
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey,
            victimSigningKey
        )
    }

    func test_cryptographicIdentity_persistsAcrossReinitAndKeepsSigningKeyPin() async {
        let keychain = MockKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let noisePublicKey = Data(repeating: 0x13, count: 32)
        let fingerprint = noisePublicKey.sha256Fingerprint()
        let peerID = PeerID(publicKey: noisePublicKey)
        let victimSigningKey = Data(repeating: 0x24, count: 32)
        let attackerSigningKey = Data(repeating: 0x77, count: 32)

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: victimSigningKey,
            claimedNickname: "victim"
        )
        let pinned = await waitUntil {
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey == victimSigningKey
        }
        XCTAssertTrue(pinned)
        manager.forceSave()

        // Simulated app restart: the pin must survive and still refuse a
        // different signing key.
        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertEqual(
            reloaded.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey,
            victimSigningKey
        )

        reloaded.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: attackerSigningKey,
            claimedNickname: "attacker"
        )
        XCTAssertEqual(
            reloaded.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey,
            victimSigningKey
        )
        XCTAssertEqual(reloaded.getSocialIdentity(for: fingerprint)?.claimedNickname, "victim")
    }

    func test_concurrentUpsertsAndForceSaveDoNotRaceOrHang() {
        // Regression guard for a data race between a barrier writer mutating
        // `cache` and `forceSave` encoding it off-queue: JSONEncoder walking a
        // dictionary being concurrently mutated can spin forever (observed as
        // a CI suite hang, killed at the watchdog timeout). forceSave must
        // snapshot `cache` on `queue` before encoding.
        //
        // forceSave is funnelled through a single serial actor: the guard is
        // for the manager's own `cache` race, and MockKeychain is not itself
        // thread-safe (production forceSave is not called concurrently). The
        // interleaving with the concurrent barrier writers is what matters.
        let manager = SecureIdentityStateManager(LockedKeychain())
        let noiseKeys = (0..<32).map { Data(repeating: UInt8($0), count: 32) }
        let forceSaveQueue = DispatchQueue(label: "test.forceSave.serial")

        let group = DispatchGroup()
        for (index, noiseKey) in noiseKeys.enumerated() {
            group.enter()
            DispatchQueue.global().async {
                let fingerprint = noiseKey.sha256Fingerprint()
                for iteration in 0..<20 {
                    manager.upsertCryptographicIdentity(
                        fingerprint: fingerprint,
                        noisePublicKey: noiseKey,
                        signingPublicKey: Data(repeating: UInt8(index), count: 32),
                        claimedNickname: "peer-\(index)-\(iteration)"
                    )
                    // Interleave a serialized off-queue save with the in-flight
                    // barrier writes from all the other threads.
                    forceSaveQueue.async { manager.forceSave() }
                }
                group.leave()
            }
        }

        let completed = group.wait(timeout: .now() + 20)
        XCTAssertEqual(completed, .success, "concurrent upsert/forceSave workload hung")
        forceSaveQueue.sync {} // drain outstanding saves

        // The pins landed and are readable (also fences pending barrier writes).
        for (index, noiseKey) in noiseKeys.enumerated() {
            let peerID = PeerID(publicKey: noiseKey)
            XCTAssertEqual(
                manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey,
                Data(repeating: UInt8(index), count: 32)
            )
        }
    }

    func test_setBlocked_clearsFavoriteState() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "ab", count: 32)

        manager.setFavorite(fingerprint, isFavorite: true)
        let favoriteSet = await waitUntil { manager.isFavorite(fingerprint: fingerprint) }
        XCTAssertTrue(favoriteSet)

        manager.setBlocked(fingerprint, isBlocked: true)
        let blockedSet = await waitUntil { manager.isBlocked(fingerprint: fingerprint) }
        XCTAssertTrue(blockedSet)

        XCTAssertFalse(manager.isFavorite(fingerprint: fingerprint))
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.claimedNickname, "Unknown")
    }

    func test_isBlocked_unknownFingerprintReturnsFalse() {
        let manager = SecureIdentityStateManager(MockKeychain())

        XCTAssertFalse(manager.isBlocked(fingerprint: String(repeating: "ff", count: 32)))
    }

    func test_setVerified_updatesTrustLevelAndVerifiedSet() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "cd", count: 32)

        manager.setFavorite(fingerprint, isFavorite: false)
        _ = await waitUntil { manager.getSocialIdentity(for: fingerprint) != nil }
        manager.setVerified(fingerprint: fingerprint, verified: true)

        let verifiedSet = await waitUntil { manager.isVerified(fingerprint: fingerprint) }
        XCTAssertTrue(verifiedSet)
        XCTAssertTrue(manager.getVerifiedFingerprints().contains(fingerprint))
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.trustLevel, .verified)
    }

    func test_forceSave_persistsFavoriteStateAcrossReinit() async {
        let keychain = MockKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let fingerprint = String(repeating: "ef", count: 32)

        manager.setFavorite(fingerprint, isFavorite: true)
        let favoriteSet = await waitUntil { manager.isFavorite(fingerprint: fingerprint) }
        XCTAssertTrue(favoriteSet)
        manager.forceSave()

        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertTrue(reloaded.isFavorite(fingerprint: fingerprint))
    }

    func test_updateSocialIdentity_reindexesClaimedNickname() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "34", count: 32)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: "Alice",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        )
        let initialIndexed = await waitUntil {
            manager.debugNicknameIndex["Alice"]?.contains(fingerprint) == true
        }
        XCTAssertTrue(initialIndexed)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: "Friend",
                claimedNickname: "Bob",
                trustLevel: .trusted,
                isFavorite: true,
                isBlocked: false,
                notes: "updated"
            )
        )

        let reindexed = await waitUntil {
            manager.debugNicknameIndex["Alice"]?.contains(fingerprint) != true &&
            manager.debugNicknameIndex["Bob"]?.contains(fingerprint) == true
        }
        XCTAssertTrue(reindexed)
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.claimedNickname, "Bob")
    }

    func test_upsertCryptographicIdentity_sameClaimedNicknamePreservesExistingSocialIdentity() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "35", count: 32)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: "Pal",
                claimedNickname: "Alice",
                trustLevel: .trusted,
                isFavorite: true,
                isBlocked: false,
                notes: "keep me"
            )
        )
        _ = await waitUntil { manager.getSocialIdentity(for: fingerprint) != nil }

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            claimedNickname: "Alice"
        )

        let inserted = await waitUntil {
            manager.getCryptoIdentitiesByPeerIDPrefix(PeerID(str: String(fingerprint.prefix(16)))).count == 1
        }
        XCTAssertTrue(inserted)
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.localPetname, "Pal")
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.notes, "keep me")
        XCTAssertTrue(manager.getSocialIdentity(for: fingerprint)?.isFavorite == true)
    }

    func test_getFavorites_returnsOnlyFavoritedFingerprints() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let favoriteOne = String(repeating: "45", count: 32)
        let favoriteTwo = String(repeating: "56", count: 32)
        let other = String(repeating: "67", count: 32)

        manager.setFavorite(favoriteOne, isFavorite: true)
        manager.setFavorite(favoriteTwo, isFavorite: true)
        manager.setFavorite(other, isFavorite: false)

        let favoritesLoaded = await waitUntil {
            manager.getFavorites() == Set([favoriteOne, favoriteTwo])
        }
        XCTAssertTrue(favoritesLoaded)
    }

    func test_setFavorite_existingIdentityCanBeClearedWithoutChangingNickname() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "68", count: 32)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: "Alice",
                trustLevel: .trusted,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        )
        _ = await waitUntil { manager.getSocialIdentity(for: fingerprint) != nil }

        manager.setFavorite(fingerprint, isFavorite: true)
        _ = await waitUntil { manager.isFavorite(fingerprint: fingerprint) }

        manager.setFavorite(fingerprint, isFavorite: false)
        let cleared = await waitUntil {
            !manager.isFavorite(fingerprint: fingerprint) &&
            manager.getSocialIdentity(for: fingerprint)?.claimedNickname == "Alice" &&
            manager.getSocialIdentity(for: fingerprint)?.trustLevel == .trusted
        }
        XCTAssertTrue(cleared)
    }

    func test_setBlocked_createsIdentityAndCanLaterUnblock() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "78", count: 32)

        manager.setBlocked(fingerprint, isBlocked: true)
        let blocked = await waitUntil {
            manager.isBlocked(fingerprint: fingerprint)
        }
        XCTAssertTrue(blocked)
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.claimedNickname, "Unknown")

        manager.setBlocked(fingerprint, isBlocked: false)
        let unblocked = await waitUntil {
            !manager.isBlocked(fingerprint: fingerprint)
        }
        XCTAssertTrue(unblocked)
    }

    func test_setVerified_false_downgradesTrustLevelToCasual() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "89", count: 32)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: "Verifier",
                trustLevel: .trusted,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        )
        _ = await waitUntil { manager.getSocialIdentity(for: fingerprint) != nil }

        manager.setVerified(fingerprint: fingerprint, verified: true)
        _ = await waitUntil { manager.isVerified(fingerprint: fingerprint) }

        manager.setVerified(fingerprint: fingerprint, verified: false)
        let downgraded = await waitUntil {
            !manager.isVerified(fingerprint: fingerprint) &&
            manager.getSocialIdentity(for: fingerprint)?.trustLevel == .casual
        }
        XCTAssertTrue(downgraded)
    }

    func test_ephemeralSessionLifecycle_tracksHandshakeProgressAndLastInteraction() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let peerID = PeerID(str: "1234567890abcdef")
        let fingerprint = String(repeating: "90", count: 32)

        manager.registerEphemeralSession(peerID: peerID, handshakeState: .initiated)
        let registered = await waitUntil {
            if case .initiated? = manager.debugEphemeralSession(for: peerID)?.handshakeState {
                return true
            }
            return false
        }
        XCTAssertTrue(registered)

        manager.updateHandshakeState(peerID: peerID, state: .inProgress)
        let progressed = await waitUntil {
            if case .inProgress? = manager.debugEphemeralSession(for: peerID)?.handshakeState {
                return true
            }
            return false
        }
        XCTAssertTrue(progressed)

        manager.updateHandshakeState(peerID: peerID, state: .completed(fingerprint: fingerprint))
        let completed = await waitUntil {
            if case .completed(let completedFingerprint)? = manager.debugEphemeralSession(for: peerID)?.handshakeState {
                return completedFingerprint == fingerprint && manager.debugLastInteraction(for: fingerprint) != nil
            }
            return false
        }
        XCTAssertTrue(completed)

        manager.removeEphemeralSession(peerID: peerID)
        let removed = await waitUntil {
            manager.debugEphemeralSession(for: peerID) == nil
        }
        XCTAssertTrue(removed)
    }

    func test_setNostrBlocked_normalizesToLowercaseAndPersists() async {
        let keychain = MockKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let pubkey = "ABCDEF1234"

        manager.setNostrBlocked(pubkey, isBlocked: true)
        let nostrBlocked = await waitUntil {
            manager.isNostrBlocked(pubkeyHexLowercased: pubkey.lowercased())
        }
        XCTAssertTrue(nostrBlocked)
        manager.forceSave()

        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertEqual(reloaded.getBlockedNostrPubkeys(), Set([pubkey.lowercased()]))
        XCTAssertTrue(reloaded.isNostrBlocked(pubkeyHexLowercased: pubkey))
    }

    func test_setNostrBlocked_falseRemovesExistingKey() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let pubkey = "ABCDEF1234"

        manager.setNostrBlocked(pubkey, isBlocked: true)
        _ = await waitUntil { manager.isNostrBlocked(pubkeyHexLowercased: pubkey) }

        manager.setNostrBlocked(pubkey, isBlocked: false)
        let cleared = await waitUntil {
            !manager.isNostrBlocked(pubkeyHexLowercased: pubkey) &&
            manager.getBlockedNostrPubkeys().isEmpty
        }
        XCTAssertTrue(cleared)
    }

    func test_corruptPersistedCache_fallsBackToEmptyState() {
        let keychain = MockKeychain()
        _ = keychain.saveIdentityKey(Data(repeating: 0x01, count: 32), forKey: "identityCacheEncryptionKey")
        _ = keychain.saveIdentityKey(Data([0xFF, 0x00, 0xAA]), forKey: "bitchat.identityCache.v2")

        let manager = SecureIdentityStateManager(keychain)

        XCTAssertTrue(manager.getFavorites().isEmpty)
        XCTAssertTrue(manager.getVerifiedFingerprints().isEmpty)
        XCTAssertTrue(manager.getBlockedNostrPubkeys().isEmpty)
        XCTAssertNil(keychain.getIdentityKey(forKey: "bitchat.identityCache.v2"))
    }

    func test_clearAllIdentityData_removesCachedState() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "12", count: 32)

        manager.setFavorite(fingerprint, isFavorite: true)
        manager.setVerified(fingerprint: fingerprint, verified: true)
        manager.setNostrBlocked("ABCD", isBlocked: true)
        let primed = await waitUntil {
            manager.isFavorite(fingerprint: fingerprint) &&
            manager.isVerified(fingerprint: fingerprint)
        }
        XCTAssertTrue(primed)

        manager.clearAllIdentityData()
        let cleared = await waitUntil {
            !manager.isFavorite(fingerprint: fingerprint) &&
            !manager.isVerified(fingerprint: fingerprint) &&
            manager.getBlockedNostrPubkeys().isEmpty
        }
        XCTAssertTrue(cleared)
    }

    func test_forceSave_withFailingCacheWriteDoesNotPersistCache() async {
        let keychain = FailingCacheSaveKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let fingerprint = String(repeating: "de", count: 32)

        manager.setFavorite(fingerprint, isFavorite: true)
        let primed = await waitUntil { manager.isFavorite(fingerprint: fingerprint) }
        XCTAssertTrue(primed)

        manager.forceSave()

        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertFalse(reloaded.isFavorite(fingerprint: fingerprint))
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

/// Thread-safe in-memory keychain for the concurrent stress test. MockKeychain
/// itself is not synchronized (production keychain access is serialized), so a
/// dedicated lock-guarded double is used so the test exercises the manager's
/// `cache` race rather than crashing on the double's own unsynchronized dict.
private final class LockedKeychain: KeychainManagerProtocol {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        sync { storage[key] = keyData; return true }
    }

    func getIdentityKey(forKey key: String) -> Data? {
        sync { storage[key] }
    }

    func deleteIdentityKey(forKey key: String) -> Bool {
        sync { storage.removeValue(forKey: key); return true }
    }

    func deleteAllKeychainData() -> Bool {
        sync { storage.removeAll(); serviceStorage.removeAll(); return true }
    }

    func secureClear(_ data: inout Data) { data = Data() }
    func secureClear(_ string: inout String) { string = "" }

    func verifyIdentityKeyExists() -> Bool {
        sync { storage["identity_noiseStaticKey"] != nil }
    }

    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        sync {
            if let data = storage[key] { return .success(data) }
            return .itemNotFound
        }
    }

    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        sync { storage[key] = keyData; return .success }
    }

    func save(key: String, data: Data, service: String, accessible: CFString?) {
        sync {
            if serviceStorage[service] == nil { serviceStorage[service] = [:] }
            serviceStorage[service]?[key] = data
        }
    }

    func load(key: String, service: String) -> Data? {
        sync { serviceStorage[service]?[key] }
    }

    func delete(key: String, service: String) {
        sync { serviceStorage[service]?.removeValue(forKey: key) }
    }
}

private final class FailingCacheSaveKeychain: KeychainManagerProtocol {
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        if key == "bitchat.identityCache.v2" {
            return false
        }
        storage[key] = keyData
        return true
    }

    func getIdentityKey(forKey key: String) -> Data? {
        storage[key]
    }

    func deleteIdentityKey(forKey key: String) -> Bool {
        storage.removeValue(forKey: key)
        return true
    }

    func deleteAllKeychainData() -> Bool {
        storage.removeAll()
        serviceStorage.removeAll()
        return true
    }

    func secureClear(_ data: inout Data) {
        data = Data()
    }

    func secureClear(_ string: inout String) {
        string = ""
    }

    func verifyIdentityKeyExists() -> Bool {
        storage["identity_noiseStaticKey"] != nil
    }

    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        if let data = storage[key] {
            return .success(data)
        }
        return .itemNotFound
    }

    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        if saveIdentityKey(keyData, forKey: key) {
            return .success
        }
        return .otherError(OSStatus(-1))
    }

    func save(key: String, data: Data, service: String, accessible: CFString?) {
        if serviceStorage[service] == nil {
            serviceStorage[service] = [:]
        }
        serviceStorage[service]?[key] = data
    }

    func load(key: String, service: String) -> Data? {
        serviceStorage[service]?[key]
    }

    func delete(key: String, service: String) {
        serviceStorage[service]?.removeValue(forKey: key)
    }
}
