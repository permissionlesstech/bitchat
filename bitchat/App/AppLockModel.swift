//
// AppLockModel.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation
import LocalAuthentication

/// Optional biometric/passcode gate on the whole app.
///
/// The keychain is AfterFirstUnlock and private chats live in memory, so an
/// unlocked, seized, or borrowed phone hands over everything — the panic
/// wipe only helps while the phone is still in your hand. This is the
/// missing complement: with the lock enabled, returning from the background
/// requires Face ID / Touch ID / the device passcode.
enum AppLockSettings {
    private static let enabledKey = "privacy.appLockEnabled"

    static var isEnabled: Bool {
        isEnabled(in: .standard)
    }

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    /// Panic-wipe hook: a wiped device behaves like a fresh install.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledKey)
    }
}

@MainActor
final class AppLockModel: ObservableObject {
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false

    private let isEnabledProvider: () -> Bool
    private let authenticate: (@escaping @MainActor (Bool) -> Void) -> Void

    /// Providers are injectable so tests drive the lock without LAContext
    /// or the shared UserDefaults.
    init(
        isEnabledProvider: @escaping () -> Bool = { AppLockSettings.isEnabled },
        authenticate: ((@escaping @MainActor (Bool) -> Void) -> Void)? = nil
    ) {
        self.isEnabledProvider = isEnabledProvider
        self.authenticate = authenticate ?? Self.systemAuthenticate
        // Locked from the first frame when enabled: the gate must cover
        // launch, not just returns from the background.
        self.isLocked = isEnabledProvider()
    }

    /// Whether the device can authenticate at all (passcode set). The
    /// settings toggle refuses to arm without this.
    static func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func lockIfEnabled() {
        guard isEnabledProvider() else { return }
        isLocked = true
    }

    func requestUnlock() {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        authenticate { [weak self] success in
            guard let self else { return }
            self.isAuthenticating = false
            if success {
                self.isLocked = false
            }
        }
    }

    private static func systemAuthenticate(_ completion: @escaping @MainActor (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Fail OPEN, deliberately: removing the device passcode already
            // requires knowing it, so this state means the owner disabled
            // it — locking them out of their own chats would punish exactly
            // the wrong person. The settings copy states this rule.
            Task { @MainActor in completion(true) }
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: String(localized: "app_lock.reason", defaultValue: "unlock bitchat", comment: "Reason line shown in the system Face ID/Touch ID/passcode prompt")
        ) { success, _ in
            Task { @MainActor in completion(success) }
        }
    }
}
