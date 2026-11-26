import BitFoundation
import Foundation
import XCTest
@testable import bitchat

final class KeychainTransientReadSafetyTests: XCTestCase {
    private final class FaultInjectingKeychain: KeychainManagerProtocol {
        private let backing = PreviewKeychainManager()
        var failingIdentityKeys: Set<String> = []
        var failingServiceKeys: Set<String> = []
        var faultResult: KeychainReadResult = .deviceLocked

        func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
            backing.saveIdentityKey(keyData, forKey: key)
        }

        func getIdentityKey(forKey key: String) -> Data? {
            if failingIdentityKeys.contains(key) { return nil }
            return backing.getIdentityKey(forKey: key)
        }

        func deleteIdentityKey(forKey key: String) -> Bool {
            backing.deleteIdentityKey(forKey: key)
        }

        func deleteAllKeychainData() -> Bool {
            backing.deleteAllKeychainData()
        }

        func secureClear(_ data: inout Data) {
            backing.secureClear(&data)
        }

        func verifyIdentityKeyExists() -> Bool {
            backing.verifyIdentityKeyExists()
        }

        func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
            if failingIdentityKeys.contains(key) { return faultResult }
            return backing.getIdentityKeyWithResult(forKey: key)
        }

        func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
            backing.saveIdentityKeyWithResult(keyData, forKey: key)
        }

        func save(key: String, data: Data, service: String, accessible: CFString?) {
            backing.save(key: key, data: data, service: service, accessible: accessible)
        }

        func load(key: String, service: String) -> Data? {
            if failingServiceKeys.contains("\(service)::\(key)") { return nil }
            return backing.load(key: key, service: service)
        }

        func loadWithResult(key: String, service: String) -> KeychainReadResult {
            if failingServiceKeys.contains("\(service)::\(key)") { return faultResult }
            return backing.loadWithResult(key: key, service: service)
        }

        func delete(key: String, service: String) {
            backing.delete(key: key, service: service)
        }

        func deleteAll(service: String) {
            backing.deleteAll(service: service)
        }
    }

    func test_secureIdentityStateManager_transientCacheReadErrorDoesNotOverwritePersistedPins() {
        let keychain = FaultInjectingKeychain()
        let fingerprint = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

        // First launch: persist a verified fingerprint in the identity cache.
        let initial = SecureIdentityStateManager(keychain)
        initial.setVerified(fingerprint: fingerprint, verified: true)
        XCTAssertTrue(initial.isVerified(fingerprint: fingerprint))

        // Second launch: encryption key succeeds, but reading cacheKey transiently fails.
        keychain.failingIdentityKeys = ["bitchat.identityCache.v2"]
        let degraded = SecureIdentityStateManager(keychain)
        XCTAssertFalse(degraded.isVerified(fingerprint: fingerprint))

        // Mutating during the degraded session must NOT overwrite the persisted cache.
        degraded.setVerified(fingerprint: "other-fp", verified: true)
        degraded.forceSave()

        // Third launch (healthy): original verified fingerprint is still intact.
        keychain.failingIdentityKeys = []
        let recovered = SecureIdentityStateManager(keychain)
        XCTAssertTrue(recovered.isVerified(fingerprint: fingerprint))
        XCTAssertFalse(recovered.isVerified(fingerprint: "other-fp"))
    }

    func test_nostrIdentityBridge_transientReadErrorsDoNotOverwriteIdentityOrDeviceSeed() throws {
        let keychain = FaultInjectingKeychain()
        let bridge = NostrIdentityBridge(keychain: keychain)

        let originalIdentity = try XCTUnwrap(try bridge.getCurrentNostrIdentity())
        let originalGeo = try bridge.deriveIdentity(forGeohash: "u4pruy")

        // Simulate locked keychain on fresh bridge instances (cold cache).
        keychain.failingServiceKeys = [
            "chat.bitchat.nostr::nostr-current-identity",
            "chat.bitchat.nostr::nostr-device-seed"
        ]
        let lockedBridge = NostrIdentityBridge(keychain: keychain)
        XCTAssertNil(try lockedBridge.getCurrentNostrIdentity())
        XCTAssertThrowsError(try lockedBridge.deriveIdentity(forGeohash: "u4pruy"))

        // Once unlocked, original identity and derived geohash key remain intact.
        keychain.failingServiceKeys = []
        let recoveredBridge = NostrIdentityBridge(keychain: keychain)
        let recoveredIdentity = try XCTUnwrap(try recoveredBridge.getCurrentNostrIdentity())
        let recoveredGeo = try recoveredBridge.deriveIdentity(forGeohash: "u4pruy")
        XCTAssertEqual(recoveredIdentity.publicKeyHex, originalIdentity.publicKeyHex)
        XCTAssertEqual(recoveredGeo.publicKeyHex, originalGeo.publicKeyHex)
    }

    func test_localPrekeyStore_transientReadErrorFailsClosedAndRecoversWithoutOverwriting() throws {
        let keychain = FaultInjectingKeychain()
        let store1 = LocalPrekeyStore(keychain: keychain)
        let initialBundle = store1.currentBundlePrekeys()
        XCTAssertFalse(initialBundle.prekeys.isEmpty)
        let firstPrekeyID = try XCTUnwrap(initialBundle.prekeys.first?.id)
        let firstPrivateBefore = try XCTUnwrap(store1.privateKey(for: firstPrekeyID))

        // Simulate locked keychain on next launch: store must fail closed and
        // must NOT latch `loaded = true` or overwrite Keychain with fresh IDs.
        keychain.failingIdentityKeys = ["prekeysV1"]
        let store2 = LocalPrekeyStore(keychain: keychain)
        XCTAssertTrue(store2.currentBundlePrekeys().prekeys.isEmpty)
        XCTAssertNil(store2.privateKey(for: firstPrekeyID))
        XCTAssertFalse(store2.replenishIfNeeded())
        XCTAssertEqual(store2.unconsumedCount, 0)

        // Once unlocked, the SAME store2 instance retries loadLocked() and
        // recovers the exact persisted prekey privates intact.
        keychain.failingIdentityKeys = []
        let recoveredPrivate = try XCTUnwrap(store2.privateKey(for: firstPrekeyID))
        XCTAssertEqual(recoveredPrivate.rawRepresentation, firstPrivateBefore.rawRepresentation)
        XCTAssertEqual(store2.currentBundlePrekeys().prekeys, initialBundle.prekeys)
    }
}
