import Foundation
import Combine
import Security
import CryptoKit
import BitLogger

@MainActor
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
    private let nowProvider: () -> Date

    @Published private(set) var isLocked: Bool = false
    @Published var method: Method
    @Published var isEnabled: Bool
    @Published var gracePeriodSeconds: Int
    @Published var lockOnLaunch: Bool

    private let pinSaltKey = "applock_pin_salt"
    private let pinHashKey = "applock_pin_hash"
    private let pinFailedCountKey = "applock_pin_failedCount"
    private let pinNextAllowedAtKey = "applock_pin_nextAllowedAt"
    private let pinLastAttemptAtKey = "applock_pin_lastAttemptAt"

    // Backoff configuration
    private let pinBackoffThreshold = 5
    private let pinBackoffScheduleSeconds: [TimeInterval] = [30, 60, 120, 240, 480] // cap at 15m
    private let pinBackoffCapSeconds: TimeInterval = 900
    private let pinDecayIntervalSeconds: TimeInterval = 3600 // subtract 1 after 1h inactivity

    init(keychain: KeychainManagerProtocol = KeychainManager(),
         localAuth: LocalAuthProviderProtocol = LocalAuthProvider(),
         defaults: UserDefaults = .standard,
         nowProvider: @escaping () -> Date = { Date() }) {
        self.keychain = keychain
        self.localAuth = localAuth
        self.defaults = defaults
        self.nowProvider = nowProvider

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
        localAuth.evaluateOwnerAuth(reason: reason, fallbackTitle: "Enter Passcode") { [weak self] success, err in
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

    @discardableResult
    func setPIN(_ pin: String) -> Bool {
        guard let data = pin.data(using: .utf8) else { return false }
        let salt = Self.randomData(count: 16)
        var combined = Data(salt)
        combined.append(data)
        let hash = Self.sha256(data: combined)
        guard keychain.saveAppLockSecret(salt, key: pinSaltKey),
              keychain.saveAppLockSecret(hash, key: pinHashKey) else {
            _ = keychain.deleteAppLockSecret(key: pinSaltKey)
            _ = keychain.deleteAppLockSecret(key: pinHashKey)
            SecureLogger.error(NSError(domain: "AppLock", code: -1), context: "Failed to persist PIN salt/hash", category: .security)
            return false
        }
        SecureLogger.info("AppLock PIN set", category: .security)
        return true
    }

    func clearPIN() {
        _ = keychain.deleteAppLockSecret(key: pinSaltKey)
        _ = keychain.deleteAppLockSecret(key: pinHashKey)
        SecureLogger.info("AppLock PIN cleared", category: .security)
    }

    func validate(pin: String) -> Bool {
        // Enforce backoff
        let availability = canAttemptPIN()
        if !availability.allowed {
            return false
        }

        // Validate
        guard let salt = keychain.getAppLockSecret(key: pinSaltKey),
              let stored = keychain.getAppLockSecret(key: pinHashKey),
              let data = pin.data(using: .utf8) else { return false }
        var combined = Data(salt)
        combined.append(data)
        let computed = Self.sha256(data: combined)
        let match = constantTimeEqual(computed, stored)
        // Update failure accounting
        let now = nowProvider()
        _ = saveDate(now, forKey: pinLastAttemptAtKey)
        if match {
            // Success: clear counters
            _ = deleteKey(forKey: pinFailedCountKey)
            _ = deleteKey(forKey: pinNextAllowedAtKey)
            isLocked = false
        } else {
            // Failure: increment and compute backoff if above threshold
            let current = (loadInt(forKey: pinFailedCountKey) ?? 0) + 1
            _ = saveInt(current, forKey: pinFailedCountKey)
            if current >= pinBackoffThreshold {
                let step = min(current - pinBackoffThreshold, pinBackoffScheduleSeconds.count - 1)
                let delay = min(pinBackoffScheduleSeconds[step], pinBackoffCapSeconds)
                let next = now.addingTimeInterval(delay)
                _ = saveDate(next, forKey: pinNextAllowedAtKey)
                if delay >= pinBackoffCapSeconds {
                    SecureLogger.warning("AppLock PIN backoff at cap reached", category: .security)
                } else {
                    SecureLogger.info("AppLock PIN backoff: wait \(Int(delay))s (failures=\(current))", category: .security)
                }
            }
        }
        return match
    }

    // MARK: - Backoff helpers
    func canAttemptPIN(now: Date) -> (allowed: Bool, wait: TimeInterval) {
        // Apply decay based on inactivity
        if let last = loadDate(forKey: pinLastAttemptAtKey) {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= pinDecayIntervalSeconds {
                let dec = Int(elapsed / pinDecayIntervalSeconds)
                if dec > 0 {
                    let current = max(0, (loadInt(forKey: pinFailedCountKey) ?? 0) - dec)
                    _ = saveInt(current, forKey: pinFailedCountKey)
                    _ = saveDate(now, forKey: pinLastAttemptAtKey)
                }
            }
        }

        if let next = loadDate(forKey: pinNextAllowedAtKey) {
            let remaining = next.timeIntervalSince(now)
            if remaining > 0 { return (false, remaining) }
        }
        return (true, 0)
    }

    func canAttemptPIN() -> (allowed: Bool, wait: TimeInterval) {
        return canAttemptPIN(now: nowProvider())
    }

    func backoffRemaining(now: Date) -> TimeInterval {
        if let next = loadDate(forKey: pinNextAllowedAtKey) {
            return max(0, next.timeIntervalSince(now))
        }
        return 0
    }

    func backoffRemaining() -> TimeInterval { backoffRemaining(now: nowProvider()) }

    func biometryType() -> BiometryType { localAuth.biometryType() }

    func deviceAuthAvailable() -> Bool { localAuth.canEvaluateOwnerAuth() }

    func hasPINConfigured() -> Bool {
        return keychain.getAppLockSecret(key: pinSaltKey) != nil && keychain.getAppLockSecret(key: pinHashKey) != nil
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

    // MARK: - Keychain encoding helpers
    private func saveInt(_ value: Int, forKey key: String) -> Bool {
        var v = Int64(value).bigEndian
        let data = Data(bytes: &v, count: MemoryLayout<Int64>.size)
        return keychain.saveAppLockSecret(data, key: key)
    }

    private func loadInt(forKey key: String) -> Int? {
        guard let data = keychain.getAppLockSecret(key: key), data.count == MemoryLayout<Int64>.size else { return nil }
        let v = data.withUnsafeBytes { $0.load(as: Int64.self) }.bigEndian
        return Int(v)
    }

    private func saveDate(_ value: Date, forKey key: String) -> Bool {
        var seconds = value.timeIntervalSince1970.bitPattern.bigEndian
        let data = Data(bytes: &seconds, count: MemoryLayout<UInt64>.size)
        return keychain.saveAppLockSecret(data, key: key)
    }

    private func loadDate(forKey key: String) -> Date? {
        guard let data = keychain.getAppLockSecret(key: key), data.count == MemoryLayout<UInt64>.size else { return nil }
        let bits = data.withUnsafeBytes { $0.load(as: UInt64.self) }.bigEndian
        let ti = TimeInterval(bitPattern: bits)
        return Date(timeIntervalSince1970: ti)
    }

    private func deleteKey(forKey key: String) -> Bool {
        return keychain.deleteAppLockSecret(key: key)
    }
}
