import Foundation
import Combine
import Security
import CryptoKit

final class AppLockManager: ObservableObject {
    enum Method: String { case off, deviceAuth, pin }

    struct ConfigKeys {
        static let enabled = "applock.enabled"
        static let method = "applock.method"
        static let grace = "applock.gracePeriodSeconds"
        static let lockOnLaunch = "applock.lockOnLaunch"
        static let lastBackgroundAt = "applock.lastBackgroundAt"
    }

    private let keychain: KeychainManagerProtocol
    private let localAuth: LocalAuthProviderProtocol
    private let defaults: UserDefaults

    @Published private(set) var isLocked: Bool = false
    @Published var method: Method
    @Published var isEnabled: Bool
    @Published var gracePeriodSeconds: Int
    @Published var lockOnLaunch: Bool

    private let pinSaltKey = "applock_pin_salt"
    private let pinHashKey = "applock_pin_hash"

    init(keychain: KeychainManagerProtocol = KeychainManager(),
         localAuth: LocalAuthProviderProtocol = LocalAuthProvider(),
         defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.localAuth = localAuth
        self.defaults = defaults

        self.isEnabled = defaults.bool(forKey: ConfigKeys.enabled)
        self.method = Method(rawValue: defaults.string(forKey: ConfigKeys.method) ?? Method.off.rawValue) ?? .off
        let grace = defaults.object(forKey: ConfigKeys.grace) as? Int
        self.gracePeriodSeconds = grace ?? 0
        self.lockOnLaunch = defaults.bool(forKey: ConfigKeys.lockOnLaunch)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: ConfigKeys.enabled)
        if !enabled { isLocked = false }
    }

    func setMethod(_ m: Method) {
        method = m
        defaults.set(m.rawValue, forKey: ConfigKeys.method)
    }

    func setGrace(_ seconds: Int) {
        gracePeriodSeconds = seconds
        defaults.set(seconds, forKey: ConfigKeys.grace)
    }

    func setLockOnLaunch(_ v: Bool) {
        lockOnLaunch = v
        defaults.set(v, forKey: ConfigKeys.lockOnLaunch)
    }

    func onDidEnterBackground() {
        defaults.set(Date(), forKey: ConfigKeys.lastBackgroundAt)
        // Cancel any pending auth prompt
        localAuth.invalidate()
    }

    func onDidBecomeActive() {
        guard isEnabled, method != .off else { return }
        if lockOnLaunch && didJustColdLaunch() { isLocked = true; return }
        if shouldLockOnActivate() { isLocked = true }
    }

    private func didJustColdLaunch() -> Bool {
        // If no last background time exists, treat as cold launch
        return defaults.object(forKey: ConfigKeys.lastBackgroundAt) == nil
    }

    func shouldLockOnActivate() -> Bool {
        guard gracePeriodSeconds > 0 else { return true }
        guard let last = defaults.object(forKey: ConfigKeys.lastBackgroundAt) as? Date else { return true }
        return Date().timeIntervalSince(last) >= TimeInterval(gracePeriodSeconds)
    }

    func lockNow() { if isEnabled && method != .off { isLocked = true } }

    func unlockWithDeviceAuth(reason: String = "Unlock bitchat") {
        localAuth.evaluateOwnerAuth(reason: reason) { [weak self] success, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if success {
                    self.isLocked = false
                } else {
                    if let err = err { SecureLogger.error(err, context: "AppLock device auth failed", category: .security) }
                }
            }
        }
    }

    func setPIN(_ pin: String) {
        guard let data = pin.data(using: .utf8) else { return }
        let salt = Self.randomData(count: 16)
        var combined = Data(salt)
        combined.append(data)
        let hash = Self.sha256(data: combined)
        _ = keychain.saveAppLockSecret(salt, key: pinSaltKey)
        _ = keychain.saveAppLockSecret(hash, key: pinHashKey)
        SecureLogger.info("AppLock PIN set", category: .security)
    }

    func clearPIN() {
        _ = keychain.deleteAppLockSecret(key: pinSaltKey)
        _ = keychain.deleteAppLockSecret(key: pinHashKey)
        SecureLogger.info("AppLock PIN cleared", category: .security)
    }

    func validate(pin: String) -> Bool {
        guard let salt = keychain.getAppLockSecret(key: pinSaltKey),
              let stored = keychain.getAppLockSecret(key: pinHashKey),
              let data = pin.data(using: .utf8) else { return false }
        var combined = Data(salt)
        combined.append(data)
        let computed = Self.sha256(data: combined)
        let match = constantTimeEqual(computed, stored)
        if match { isLocked = false }
        return match
    }

    func panicClear() {
        clearPIN()
        setEnabled(false)
        setMethod(.off)
        isLocked = false
    }

    // MARK: - Utils
    private static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess { return Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }
        return Data(bytes)
    }

    private static func sha256(data: Data) -> Data {
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
