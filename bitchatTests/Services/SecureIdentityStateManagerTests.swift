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

    func test_setBlocked_clearsFavoriteState() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "ab", count: 32)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: "Unknown",
                trustLevel: .unknown,
                isFavorite: true,
                isBlocked: false,
                notes: nil
            )
        )
        manager.setBlocked(fingerprint, isBlocked: true)
        let blockedSet = await waitUntil { manager.isBlocked(fingerprint: fingerprint) }
        XCTAssertTrue(blockedSet)

        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.isFavorite, false)
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.claimedNickname, "Unknown")
    }

    func test_isBlocked_unknownFingerprintReturnsFalse() {
        let manager = SecureIdentityStateManager(MockKeychain())

        XCTAssertFalse(manager.isBlocked(fingerprint: String(repeating: "ff", count: 32)))
    }

    func test_setVerified_updatesTrustLevelAndVerifiedSet() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "cd", count: 32)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: "Peer",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        )
        manager.setVerified(fingerprint: fingerprint, verified: true)

        let verifiedSet = await waitUntil { manager.isVerified(fingerprint: fingerprint) }
        XCTAssertTrue(verifiedSet)
        XCTAssertTrue(manager.getVerifiedFingerprints().contains(fingerprint))
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.trustLevel, .verified)
    }

    func test_forceSave_persistsSocialIdentityAcrossReinit() async {
        let keychain = MockKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let fingerprint = String(repeating: "ef", count: 32)

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
        manager.forceSave()

        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertEqual(reloaded.getSocialIdentity(for: fingerprint)?.claimedNickname, "Bob")
        XCTAssertEqual(reloaded.getSocialIdentity(for: fingerprint)?.localPetname, "Friend")
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

        XCTAssertTrue(manager.getVerifiedFingerprints().isEmpty)
        XCTAssertTrue(manager.getBlockedNostrPubkeys().isEmpty)
        XCTAssertNil(keychain.getIdentityKey(forKey: "bitchat.identityCache.v2"))
    }

    func test_clearAllIdentityData_removesCachedState() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "12", count: 32)

        manager.setVerified(fingerprint: fingerprint, verified: true)
        manager.setNostrBlocked("ABCD", isBlocked: true)
        let primed = await waitUntil {
            manager.isVerified(fingerprint: fingerprint)
        }
        XCTAssertTrue(primed)

        manager.clearAllIdentityData()
        let cleared = await waitUntil {
            !manager.isVerified(fingerprint: fingerprint) &&
            manager.getBlockedNostrPubkeys().isEmpty
        }
        XCTAssertTrue(cleared)
    }

    func test_privateMediaCapabilityPinPersistsMonotonicallyAndPanicClearRemovesIt() async {
        let keychain = MockKeychain()
        let fingerprint = Data(repeating: 0x42, count: 32).sha256Fingerprint()
        let manager = SecureIdentityStateManager(keychain)

        XCTAssertFalse(manager.hasObservedPrivateMediaCapability(fingerprint: fingerprint))
        manager.markPrivateMediaCapable(fingerprint: fingerprint)
        XCTAssertTrue(
            manager.hasObservedPrivateMediaCapability(fingerprint: fingerprint),
            "pin insertion must be synchronously visible to the next downgrade decision"
        )

        // Re-marking is idempotent, and the encrypted cache carries the pin
        // across launches.
        manager.markPrivateMediaCapable(fingerprint: fingerprint)
        manager.forceSave()
        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertTrue(reloaded.hasObservedPrivateMediaCapability(fingerprint: fingerprint))

        // ChatViewModel's panic path calls this same wipe after deleting
        // keychain data; the in-memory pin must disappear immediately too.
        reloaded.clearAllIdentityData()
        let cleared = await waitUntil {
            !reloaded.hasObservedPrivateMediaCapability(fingerprint: fingerprint)
        }
        XCTAssertTrue(cleared)
    }

    func test_noiseAuthenticatedSigningKeyBindingPersistsAndPanicClearRemovesIt() async {
        let keychain = MockKeychain()
        let fingerprint = Data(repeating: 0x31, count: 32).sha256Fingerprint()
        let firstKey = Data(repeating: 0x41, count: 32)
        let rotatedKey = Data(repeating: 0x42, count: 32)
        let manager = SecureIdentityStateManager(keychain)

        manager.bindAuthenticatedSigningPublicKey(firstKey, fingerprint: fingerprint)
        XCTAssertEqual(manager.authenticatedSigningPublicKey(forFingerprint: fingerprint), firstKey)
        // A later authenticated Noise session may legitimately rotate the
        // announcement signing key.
        manager.bindAuthenticatedSigningPublicKey(rotatedKey, fingerprint: fingerprint)
        XCTAssertEqual(manager.authenticatedSigningPublicKey(forFingerprint: fingerprint), rotatedKey)

        manager.forceSave()
        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertEqual(reloaded.authenticatedSigningPublicKey(forFingerprint: fingerprint), rotatedKey)

        reloaded.clearAllIdentityData()
        let cleared = await waitUntil {
            reloaded.authenticatedSigningPublicKey(forFingerprint: fingerprint) == nil
        }
        XCTAssertTrue(cleared)
    }

    func test_forceSave_withFailingCacheWriteDoesNotPersistCache() async {
        let keychain = FailingCacheSaveKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let fingerprint = String(repeating: "de", count: 32)

        manager.setVerified(fingerprint: fingerprint, verified: true)
        let primed = await waitUntil { manager.isVerified(fingerprint: fingerprint) }
        XCTAssertTrue(primed)

        manager.forceSave()

        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertFalse(reloaded.isVerified(fingerprint: fingerprint))
    }

    func test_upsertCryptographicIdentity_skipsRedundantKeychainWritesWhenUnchanged() async {
        let keychain = FailingCacheSaveKeychain(shouldFailCacheSave: false)
        let manager = SecureIdentityStateManager(keychain)
        let noisePublicKey = Data(repeating: 0x42, count: 32)
        let signingPublicKey = Data(repeating: 0x43, count: 32)
        let fingerprint = noisePublicKey.sha256Fingerprint()

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            claimedNickname: "Alice"
        )
        let savedInitial = await waitUntil { keychain.cacheSaveCount == 1 }
        XCTAssertTrue(savedInitial)

        // Repeated identical periodic announces must not re-encrypt and flush the Keychain cache.
        for _ in 0..<5 {
            manager.upsertCryptographicIdentity(
                fingerprint: fingerprint,
                noisePublicKey: noisePublicKey,
                signingPublicKey: signingPublicKey,
                claimedNickname: "Alice"
            )
        }
        // Fence barrier writes with a synchronous read.
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.claimedNickname, "Alice")
        XCTAssertEqual(keychain.cacheSaveCount, 1)

        // A real mutation (nickname update) still persists.
        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            claimedNickname: "Alice2"
        )
        let savedUpdate = await waitUntil { keychain.cacheSaveCount == 2 }
        XCTAssertTrue(savedUpdate)
    }

    func test_upsertCryptographicIdentity_retriesFailedKeychainWriteOnIdenticalAnnounce() async {
        let keychain = FailingCacheSaveKeychain(shouldFailCacheSave: true)
        let manager = SecureIdentityStateManager(keychain)
        let noisePublicKey = Data(repeating: 0x52, count: 32)
        let signingPublicKey = Data(repeating: 0x53, count: 32)
        let fingerprint = noisePublicKey.sha256Fingerprint()
        let peerID = PeerID(publicKey: noisePublicKey)

        // First write fails transiently.
        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            claimedNickname: "Bob"
        )
        let attemptedInitial = await waitUntil { keychain.cacheSaveCount == 1 }
        XCTAssertTrue(attemptedInitial)

        // Keychain recovers; an identical periodic announce must retry and persist.
        keychain.setShouldFailCacheSave(false)
        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            claimedNickname: "Bob"
        )
        let retried = await waitUntil { keychain.cacheSaveCount == 2 }
        XCTAssertTrue(retried)

        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertEqual(
            reloaded.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey,
            signingPublicKey
        )
        XCTAssertEqual(reloaded.getSocialIdentity(for: fingerprint)?.claimedNickname, "Bob")
    }

    func test_clearAllIdentityData_clearsPendingSaveAfterFailedWrite() async {
        let keychain = FailingCacheSaveKeychain(shouldFailCacheSave: true)
        let manager = SecureIdentityStateManager(keychain)
        let noisePublicKey = Data(repeating: 0x62, count: 32)
        let signingPublicKey = Data(repeating: 0x63, count: 32)
        let fingerprint = noisePublicKey.sha256Fingerprint()

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            claimedNickname: "Carol"
        )
        let attemptedInitial = await waitUntil { keychain.cacheSaveCount == 1 }
        XCTAssertTrue(attemptedInitial)

        // Panic wipe while a failed save is still pending must not let a later
        // flush recreate the cache item in Keychain.
        manager.clearAllIdentityData()
        keychain.setShouldFailCacheSave(false)
        manager.forceSave()

        XCTAssertEqual(keychain.cacheSaveCount, 1)
        XCTAssertNil(keychain.getIdentityKey(forKey: "bitchat.identityCache.v2"))
    }

    func test_identityCache_decodesLegacyPayloadContainingNicknameIndexAndLastInteractions() throws {
        let fingerprint = String(repeating: "ab", count: 32)
        let legacyJSON = """
        {
            "socialIdentities": {
                "\(fingerprint)": {
                    "fingerprint": "\(fingerprint)",
                    "localPetname": "Buddy",
                    "claimedNickname": "Alice",
                    "trustLevel": "trusted",
                    "isFavorite": true,
                    "isBlocked": false,
                    "notes": null
                }
            },
            "nicknameIndex": {
                "Alice": ["\(fingerprint)"]
            },
            "verifiedFingerprints": ["\(fingerprint)"],
            "lastInteractions": {
                "\(fingerprint)": 1700000000
            },
            "cryptographicIdentities": {}
        }
        """

        let decoded = try JSONDecoder().decode(IdentityCache.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.socialIdentities[fingerprint]?.claimedNickname, "Alice")
        XCTAssertEqual(decoded.socialIdentities[fingerprint]?.localPetname, "Buddy")
        XCTAssertTrue(decoded.verifiedFingerprints.contains(fingerprint))
    }

    private func waitUntil(
        timeout: TimeInterval = TestConstants.settleTimeout,
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

private final class FailingCacheSaveKeychain: KeychainManagerProtocol {
    private let lock = NSLock()
    private var _shouldFailCacheSave: Bool
    private var _cacheSaveCount = 0
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]

    init(shouldFailCacheSave: Bool = true) {
        self._shouldFailCacheSave = shouldFailCacheSave
    }

    func setShouldFailCacheSave(_ value: Bool) {
        lock.lock()
        _shouldFailCacheSave = value
        lock.unlock()
    }

    var cacheSaveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _cacheSaveCount
    }

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        if key == "bitchat.identityCache.v2" {
            lock.lock()
            _cacheSaveCount += 1
            let shouldFail = _shouldFailCacheSave
            lock.unlock()
            if shouldFail {
                return false
            }
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

    func deleteAll(service: String) {
        serviceStorage.removeValue(forKey: service)
    }
}
