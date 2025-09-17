import XCTest
@testable import bitchat

final class AppLockTests: XCTestCase {
    final class MockAuth: LocalAuthProviderProtocol {
        var canEvaluate = true
        var nextResult: (Bool, Error?) = (true, nil)
        func canEvaluateOwnerAuth() -> Bool { canEvaluate }
        func evaluateOwnerAuth(reason: String, completion: @escaping (Bool, Error?) -> Void) { completion(nextResult.0, nextResult.1) }
        func invalidate() {}
    }

    final class MockKeychain: KeychainManagerProtocol {
        var store: [String: Data] = [:]
        func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool { false }
        func getIdentityKey(forKey key: String) -> Data? { nil }
        func deleteIdentityKey(forKey key: String) -> Bool { true }
        func deleteAllKeychainData() -> Bool { store.removeAll(); return true }
        func secureClear(_ data: inout Data) { data.removeAll() }
        func secureClear(_ string: inout String) { string.removeAll() }
        func verifyIdentityKeyExists() -> Bool { false }
        func saveAppLockSecret(_ data: Data, key: String) -> Bool { store[key] = data; return true }
        func getAppLockSecret(key: String) -> Data? { store[key] }
        func deleteAppLockSecret(key: String) -> Bool { store.removeValue(forKey: key) != nil }
    }

    func testGraceAndLockOnActivate() {
        let kc = MockKeychain()
        let auth = MockAuth()
        let defaults = UserDefaults(suiteName: "test.applock.\(UUID().uuidString)")!
        let mgr = AppLockManager(keychain: kc, localAuth: auth, defaults: defaults)

        mgr.setEnabled(true)
        mgr.setMethod(.deviceAuth)
        mgr.setGrace(30)
        // Simulate background now
        mgr.onDidEnterBackground()
        // Within grace, should not lock
        mgr.onDidBecomeActive()
        XCTAssertFalse(mgr.isLocked)
        // Force grace expiry
        defaults.set(Date(timeIntervalSinceNow: -60), forKey: AppLockManager.ConfigKeys.lastBackgroundAt)
        mgr.onDidBecomeActive()
        XCTAssertTrue(mgr.isLocked)
    }

    func testLockOnLaunch() {
        let kc = MockKeychain()
        let auth = MockAuth()
        let defaults = UserDefaults(suiteName: "test.applock.\(UUID().uuidString)")!
        let mgr = AppLockManager(keychain: kc, localAuth: auth, defaults: defaults)
        mgr.setEnabled(true)
        mgr.setMethod(.deviceAuth)
        mgr.setLockOnLaunch(true)
        // No lastBackgroundAt => cold launch => locked
        mgr.onDidBecomeActive()
        XCTAssertTrue(mgr.isLocked)
    }

    func testPINSetAndValidate() {
        let kc = MockKeychain()
        let auth = MockAuth()
        let defaults = UserDefaults(suiteName: "test.applock.\(UUID().uuidString)")!
        let mgr = AppLockManager(keychain: kc, localAuth: auth, defaults: defaults)
        mgr.setEnabled(true)
        mgr.setMethod(.pin)
        mgr.lockNow()
        XCTAssertTrue(mgr.setPIN("1234"))
        XCTAssertTrue(mgr.validate(pin: "1234"))
        XCTAssertFalse(mgr.validate(pin: "9999"))
    }

    func testBackoffSchedule() {
        let kc = MockKeychain()
        let auth = MockAuth()
        let defaults = UserDefaults(suiteName: "test.applock.\(UUID().uuidString)")!
        let mgr = AppLockManager(keychain: kc, localAuth: auth, defaults: defaults)
        mgr.setEnabled(true)
        mgr.setMethod(.pin)
        XCTAssertTrue(mgr.setPIN("1234"))
        mgr.lockNow()

        // 4 failures: under threshold, no wait
        for _ in 0..<4 { _ = mgr.validate(pin: "0000") }
        var avail = mgr.canAttemptPIN()
        XCTAssertTrue(avail.allowed)

        // 5th failure: start backoff ~30s
        _ = mgr.validate(pin: "0000")
        avail = mgr.canAttemptPIN()
        XCTAssertFalse(avail.allowed)
        XCTAssertGreaterThanOrEqual(Int(avail.wait), 29)

        // Simulate time passing by overwriting nextAllowedAt to now
        // NOTE: Using internal helper via public API by setting successful validate after wait cleared
    }

    func testBackoffResetsOnSuccess() {
        let kc = MockKeychain()
        let auth = MockAuth()
        let defaults = UserDefaults(suiteName: "test.applock.\(UUID().uuidString)")!
        let mgr = AppLockManager(keychain: kc, localAuth: auth, defaults: defaults)
        mgr.setEnabled(true)
        mgr.setMethod(.pin)
        XCTAssertTrue(mgr.setPIN("1234"))
        mgr.lockNow()
        for _ in 0..<6 { _ = mgr.validate(pin: "0000") }
        XCTAssertFalse(mgr.canAttemptPIN().allowed)
        // Now succeed and ensure counters clear
        // Force allow by simulating wait elapsed with sleep(1) + assume schedule minimal
        // We just test that after success, allowed returns true again
        _ = mgr.validate(pin: "1234")
        XCTAssertTrue(mgr.canAttemptPIN().allowed)
    }
}
