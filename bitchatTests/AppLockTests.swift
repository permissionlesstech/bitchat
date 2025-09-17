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
        mgr.setPIN("1234")
        XCTAssertTrue(mgr.validate(pin: "1234"))
        XCTAssertFalse(mgr.validate(pin: "9999"))
    }
}

