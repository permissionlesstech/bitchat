//
// KeychainManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import BitFoundation
import Foundation
import Security

enum KeychainInstallLifecycleAction: Equatable {
    case markerPresent
    case bootstrapMarker
    case clearStaleKeys
    case retryLater
}

/// Process-local fail-closed gate for an unresolved install lifecycle.
///
/// A blocked caller may perform one synchronous reconciliation attempt.
/// Concurrent callers fail closed instead of reading while that cleanup is
/// in flight. Once reconciliation succeeds, access remains open.
final class KeychainInstallAccessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false
    private var reconciliationInProgress = false

    func block() {
        lock.lock()
        blocked = true
        lock.unlock()
    }

    func allowsAccess(reconcile: () -> Bool) -> Bool {
        lock.lock()
        if !blocked {
            lock.unlock()
            return true
        }
        guard !reconciliationInProgress else {
            lock.unlock()
            return false
        }
        reconciliationInProgress = true
        lock.unlock()

        let completed = reconcile()

        lock.lock()
        if completed {
            blocked = false
        }
        reconciliationInProgress = false
        lock.unlock()
        return completed
    }
}

final class KeychainManager: KeychainManagerProtocol {
    /// Default keychain for components that construct their own rather than
    /// having one injected. Under test this is an in-memory keychain: the
    /// xctest runner's code signature changes every build, so any read of a
    /// real login-keychain item triggers a macOS password prompt that
    /// "Always Allow" can never satisfy — and tests must never read or
    /// mutate the developer's real keychain (`SecItemCopyMatching` can also
    /// hang in test environments). Production behavior is unchanged.
    static func makeDefault() -> KeychainManagerProtocol {
        // PreviewKeychainManager lives in _PreviewHelpers, a development
        // asset excluded from archive builds — release code must not
        // reference it. Tests always run Debug, so the guard is lossless.
        #if DEBUG
        if TestEnvironment.isRunningTests { return sharedTestKeychain }
        #endif
        return KeychainManager()
    }

    #if DEBUG
    /// One store per process, mirroring the real keychain: separate
    /// default-constructed components (e.g. two NostrIdentityBridge
    /// instances in BoardManager's publish and delete paths) must see each
    /// other's writes, or they would derive different Nostr identities
    /// under test.
    private static let sharedTestKeychain = PreviewKeychainManager()
    #endif

    // Use consistent service name for all keychain items
    private let service = BitchatApp.bundleID
    private let appGroup = "group.\(BitchatApp.bundleID)"
    #if os(iOS)
    private let installAccessGate = KeychainInstallAccessGate()
    #endif
    /// Every generic-password service owned by this app, including names used
    /// by older releases. Keep custom services here so one-time security
    /// migrations and panic deletion cannot silently miss them.
    private static let additionalApplicationOwnedServices = [
        "chat.bitchat.nostr",
        "chat.bitchat.favorites",
        "chat.bitchat.outbox",
        "com.bitchat.passwords",
        "com.bitchat.deviceidentity",
        "com.bitchat.noise.identity",
        "chat.bitchat.passwords",
        "bitchat.keychain",
        "bitchat",
        "com.bitchat"
    ]
    // AfterFirstUnlock, not WhenUnlocked: the mesh keeps running with the
    // device locked (identity-cache saves failed with -25308 throughout
    // locked-phone testing), and a wake-on-proximity relaunch via BLE state
    // restoration must be able to read the noise keys before the user
    // unlocks. ThisDeviceOnly prevents private identities and group keys from
    // migrating through device backups onto a second device.
    private static let itemAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    init() {
        #if os(iOS)
        if reconcileInstallLifecycle() {
            migrateAccessibilityIfNeeded()
        } else {
            installAccessGate.block()
        }
        #endif
    }

    static func installLifecycleAction(
        containerKnowsMarker: Bool,
        cleanupPending: Bool = false,
        markerRead: KeychainReadResult
    ) -> KeychainInstallLifecycleAction {
        // Once a reinstall cleanup has started, its container-local latch
        // must win even if the keychain marker was deleted before a later
        // keychain operation failed. Otherwise the next launch could mistake
        // a partial cleanup for a fresh bootstrap and preserve stale secrets.
        if cleanupPending {
            return .clearStaleKeys
        }

        switch markerRead {
        case .success:
            return containerKnowsMarker ? .markerPresent : .clearStaleKeys
        case .itemNotFound:
            return .bootstrapMarker
        case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            return .retryLater
        }
    }

    static func applicationOwnedKeychainServices(primaryService: String) -> [String] {
        var seen = Set<String>()
        return ([primaryService] + additionalApplicationOwnedServices).filter {
            seen.insert($0).inserted
        }
    }

    /// Runs every service update even after one failure. Successful updates
    /// are idempotent, while returning false keeps the one-time flag unset so
    /// a later unlocked launch retries the incomplete migration.
    static func migrateAccessibilityForApplicationOwnedServices(
        primaryService: String,
        updateService: (String) -> OSStatus
    ) -> Bool {
        var completed = true
        for serviceName in applicationOwnedKeychainServices(
            primaryService: primaryService
        ) {
            let status = updateService(serviceName)
            if status != errSecSuccess && status != errSecItemNotFound {
                completed = false
            }
        }
        return completed
    }

    /// Deletes every declared service even after one failure. An empty scope
    /// is already clean, while any other status leaves the cleanup
    /// incomplete so its durable retry marker remains set.
    static func deleteApplicationOwnedKeychainServices(
        primaryService: String,
        deleteService: (String) -> OSStatus
    ) -> Bool {
        var completed = true
        for serviceName in applicationOwnedKeychainServices(
            primaryService: primaryService
        ) {
            let status = deleteService(serviceName)
            if status != errSecSuccess && status != errSecItemNotFound {
                completed = false
            }
        }
        return completed
    }

    /// The app currently has an application-group entitlement, not a
    /// keychain-access-group entitlement. Keep the historical group cleanup
    /// probe as best effort without making its expected -34018 response block
    /// panic recovery forever.
    static func completedApplicationGroupDelete(status: OSStatus) -> Bool {
        status == errSecSuccess
            || status == errSecItemNotFound
            || status == -34018
    }

    #if os(iOS)

    private static let installMarkerAccount = "install_lifecycle_marker"
    private static let installMarkerDefaultsKey = "keychain.installLifecycleMarker.present"
    private static let installCleanupPendingDefaultsKey =
        "keychain.installLifecycleCleanup.pending"

    /// Keychain items can survive app removal while the app container and its
    /// UserDefaults do not. The first version carrying this marker bootstraps
    /// without deleting existing users' identities. On a later reinstall, a
    /// surviving keychain marker plus a missing defaults marker proves the app
    /// container was replaced, so stale secrets are removed before use.
    @discardableResult
    private func reconcileInstallLifecycle() -> Bool {
        let defaults = UserDefaults.standard
        let containerKnowsMarker = defaults.bool(forKey: Self.installMarkerDefaultsKey)
        let cleanupPending = defaults.bool(
            forKey: Self.installCleanupPendingDefaultsKey
        )

        let markerRead = retrieveDataWithResult(forKey: Self.installMarkerAccount)
        switch Self.installLifecycleAction(
            containerKnowsMarker: containerKnowsMarker,
            cleanupPending: cleanupPending,
            markerRead: markerRead
        ) {
        case .markerPresent:
            defaults.set(true, forKey: Self.installMarkerDefaultsKey)
            return true

        case .bootstrapMarker:
            if case .success = saveDataWithResult(Data([1]), forKey: Self.installMarkerAccount) {
                defaults.set(true, forKey: Self.installMarkerDefaultsKey)
            }
            // A missing marker is the intentional bootstrap path for both a
            // fresh install and the first marker-carrying upgrade. Preserve
            // existing users' identities even if marker creation must retry
            // on a later construction.
            return true

        case .clearStaleKeys:
            // Establish a container-local retry latch before deleting the
            // surviving keychain marker. If the process exits or any keychain
            // operation fails, the next launch retries even when that marker
            // can no longer be read.
            defaults.set(true, forKey: Self.installCleanupPendingDefaultsKey)
            guard defaults.synchronize(),
                  defaults.bool(forKey: Self.installCleanupPendingDefaultsKey)
            else {
                SecureLogger.error(
                    "Could not persist reinstall keychain-cleanup intent",
                    category: .security
                )
                return false
            }

            guard deleteAllKeychainData() else {
                SecureLogger.error(
                    "Reinstall keychain cleanup incomplete; retry remains pending",
                    category: .security
                )
                return false
            }

            defaults.set(true, forKey: Self.installMarkerDefaultsKey)
            defaults.removeObject(
                forKey: Self.installCleanupPendingDefaultsKey
            )
            guard defaults.synchronize(),
                  defaults.bool(forKey: Self.installMarkerDefaultsKey),
                  !defaults.bool(
                    forKey: Self.installCleanupPendingDefaultsKey
                  )
            else {
                // Preserve the fail-closed state in memory and make one more
                // best-effort persistence attempt before startup continues.
                defaults.set(
                    true,
                    forKey: Self.installCleanupPendingDefaultsKey
                )
                _ = defaults.synchronize()
                SecureLogger.error(
                    "Could not commit reinstall keychain-cleanup state; retry remains pending",
                    category: .security
                )
                return false
            }
            return true

        case .retryLater:
            // Do not guess that a temporarily unreadable marker is absent.
            // An established container may keep using ordinary protected-data
            // semantics: reads fail while locked and recover after unlock. A
            // container that has not committed the marker must stay blocked
            // until the marker becomes readable and this state machine can
            // distinguish bootstrap from reinstall.
            return containerKnowsMarker
        }
    }

    /// One-time upgrade of items created under WhenUnlocked. New saves get
    /// the right class on their own (saves are delete-then-add), but the
    /// long-lived identity keys are written once and would otherwise stay
    /// unreadable while the device is locked.
    private func migrateAccessibilityIfNeeded() {
        let flag = "keychain.accessibility.afterFirstUnlockThisDeviceOnly.migrated"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }

        let update: [String: Any] = [
            kSecAttrAccessible as String: Self.itemAccessibility
        ]
        let completed = Self.migrateAccessibilityForApplicationOwnedServices(
            primaryService: service
        ) { serviceName in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName
            ]
            return SecItemUpdate(
                query as CFDictionary,
                update as CFDictionary
            )
        }
        if completed {
            // Missing services on a fresh install are terminal, but the flag is
            // set only after every application-owned service was considered.
            UserDefaults.standard.set(true, forKey: flag)
            SecureLogger.info(
                "Keychain accessibility migrated to AfterFirstUnlockThisDeviceOnly",
                category: .keychain
            )
        } else {
            // Likely errSecInteractionNotAllowed (relaunched while locked) —
            // leave the flag unset so the next launch retries.
            SecureLogger.warning(
                "Keychain accessibility migration deferred for at least one application-owned service",
                category: .keychain
            )
        }
    }
    #endif

    private func installAccessAllowed() -> Bool {
        #if os(iOS)
        return installAccessGate.allowsAccess { [self] in
            guard reconcileInstallLifecycle() else { return false }
            migrateAccessibilityIfNeeded()
            return true
        }
        #else
        return true
        #endif
    }

    // MARK: - Identity Keys
    
    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        guard installAccessAllowed() else {
            SecureLogger.logKeyOperation(.save, keyType: key, success: false)
            return false
        }
        let fullKey = "identity_\(key)"
        let result = saveData(keyData, forKey: fullKey)
        SecureLogger.logKeyOperation(.save, keyType: key, success: result)
        return result
    }
    
    func getIdentityKey(forKey key: String) -> Data? {
        guard installAccessAllowed() else { return nil }
        let fullKey = "identity_\(key)"
        return retrieveData(forKey: fullKey)
    }
    
    func deleteIdentityKey(forKey key: String) -> Bool {
        guard installAccessAllowed() else {
            SecureLogger.logKeyOperation(.delete, keyType: key, success: false)
            return false
        }
        let result = delete(forKey: "identity_\(key)")
        SecureLogger.logKeyOperation(.delete, keyType: key, success: result)
        return result
    }

    // MARK: - BCH-01-009: Methods with Proper Error Classification

    /// Get identity key with detailed result for proper error handling
    /// Distinguishes between missing keys (expected) and critical failures
    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        guard installAccessAllowed() else { return .accessDenied }
        let fullKey = "identity_\(key)"
        return retrieveDataWithResult(forKey: fullKey)
    }

    /// Save identity key with detailed result and retry logic for transient errors
    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        guard installAccessAllowed() else { return .accessDenied }
        let fullKey = "identity_\(key)"
        return saveDataWithResult(keyData, forKey: fullKey)
    }

    /// Internal method to save data with detailed result and retry for transient errors
    private func saveDataWithResult(_ data: Data, forKey key: String, retryCount: Int = 2) -> KeychainSaveResult {
        // Delete any existing item first to ensure clean state
        _ = delete(forKey: key)

        // Build base query
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: Self.itemAccessibility,
            kSecAttrLabel as String: "bitchat-\(key)"
        ]
        #if os(macOS)
        base[kSecAttrSynchronizable as String] = false
        #endif

        func attempt(addAccessGroup: Bool) -> OSStatus {
            var query = base
            if addAccessGroup { query[kSecAttrAccessGroup as String] = appGroup }
            return SecItemAdd(query as CFDictionary, nil)
        }

        #if os(iOS)
        var status = attempt(addAccessGroup: true)
        if status == -34018 { // Missing entitlement, retry without access group
            status = attempt(addAccessGroup: false)
        }
        #else
        let status = attempt(addAccessGroup: false)
        #endif

        // Classify the result
        let result = classifySaveStatus(status)

        // Log all outcomes consistently
        switch result {
        case .success:
            SecureLogger.debug("Keychain save succeeded for key: \(key)", category: .keychain)
        case .duplicateItem:
            SecureLogger.warning("Keychain save found duplicate for key: \(key)", category: .keychain)
        case .accessDenied:
            SecureLogger.error(NSError(domain: "Keychain", code: Int(status)),
                               context: "Keychain access denied for key: \(key)", category: .keychain)
        case .deviceLocked:
            SecureLogger.warning("Device locked during keychain save for key: \(key)", category: .keychain)
        case .storageFull:
            SecureLogger.error(NSError(domain: "Keychain", code: Int(status)),
                               context: "Keychain storage full for key: \(key)", category: .keychain)
        case .otherError(let code):
            SecureLogger.error(NSError(domain: "Keychain", code: Int(code)),
                               context: "Keychain save failed for key: \(key)", category: .keychain)
        }

        // Retry transient errors with exponential backoff
        if result.isRecoverableError && retryCount > 0 {
            let delayMs = UInt32((3 - retryCount) * 100) // 100ms, 200ms backoff
            usleep(delayMs * 1000)
            SecureLogger.debug("Retrying keychain save for key: \(key), attempts remaining: \(retryCount)", category: .keychain)
            return saveDataWithResult(data, forKey: key, retryCount: retryCount - 1)
        }

        return result
    }

    /// Internal method to retrieve data with detailed result
    private func retrieveDataWithResult(forKey key: String) -> KeychainReadResult {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        func attempt(withAccessGroup: Bool) -> OSStatus {
            var q = base
            if withAccessGroup { q[kSecAttrAccessGroup as String] = appGroup }
            return SecItemCopyMatching(q as CFDictionary, &result)
        }

        #if os(iOS)
        var status = attempt(withAccessGroup: true)
        if status == -34018 { status = attempt(withAccessGroup: false) }
        #else
        let status = attempt(withAccessGroup: false)
        #endif

        // Classify the result
        let readResult = classifyReadStatus(status, data: result as? Data)

        // Log all outcomes consistently
        switch readResult {
        case .success:
            SecureLogger.debug("Keychain read succeeded for key: \(key)", category: .keychain)
        case .itemNotFound:
            // Expected case - no logging needed for missing keys
            break
        case .accessDenied:
            SecureLogger.error(NSError(domain: "Keychain", code: Int(status)),
                               context: "Keychain access denied for key: \(key)", category: .keychain)
        case .deviceLocked:
            SecureLogger.warning("Device locked during keychain read for key: \(key)", category: .keychain)
        case .authenticationFailed:
            SecureLogger.warning("Authentication failed for keychain read of key: \(key)", category: .keychain)
        case .otherError(let code):
            SecureLogger.error(NSError(domain: "Keychain", code: Int(code)),
                               context: "Keychain read failed for key: \(key)", category: .keychain)
        }

        return readResult
    }

    /// Classify keychain read status into meaningful categories
    private func classifyReadStatus(_ status: OSStatus, data: Data?) -> KeychainReadResult {
        switch status {
        case errSecSuccess:
            if let data = data {
                return .success(data)
            }
            return .otherError(status)
        case errSecItemNotFound:
            return .itemNotFound
        case errSecInteractionNotAllowed:
            // Device is locked or in a state that doesn't allow keychain access
            return .deviceLocked
        case errSecAuthFailed:
            return .authenticationFailed
        case -34018: // errSecMissingEntitlement
            return .accessDenied
        case errSecNotAvailable:
            return .accessDenied
        default:
            return .otherError(status)
        }
    }

    /// Classify keychain save status into meaningful categories
    private func classifySaveStatus(_ status: OSStatus) -> KeychainSaveResult {
        switch status {
        case errSecSuccess:
            return .success
        case errSecDuplicateItem:
            return .duplicateItem
        case errSecInteractionNotAllowed:
            return .deviceLocked
        case -34018: // errSecMissingEntitlement
            return .accessDenied
        case errSecNotAvailable:
            return .accessDenied
        case errSecDiskFull:
            return .storageFull
        default:
            return .otherError(status)
        }
    }

    // MARK: - Generic Operations
    
    private func saveData(_ data: Data, forKey key: String) -> Bool {
        // Delete any existing item first to ensure clean state
        _ = delete(forKey: key)
        
        // Build base query
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: Self.itemAccessibility,
            kSecAttrLabel as String: "bitchat-\(key)"
        ]
        #if os(macOS)
        base[kSecAttrSynchronizable as String] = false
        #endif

        // Try with access group where it is expected to work (iOS app builds)
        var triedWithoutGroup = false
        func attempt(addAccessGroup: Bool) -> OSStatus {
            var query = base
            if addAccessGroup { query[kSecAttrAccessGroup as String] = appGroup }
            return SecItemAdd(query as CFDictionary, nil)
        }

        #if os(iOS)
        var status = attempt(addAccessGroup: true)
        if status == -34018 { // Missing entitlement, retry without access group
            triedWithoutGroup = true
            status = attempt(addAccessGroup: false)
        }
        #else
        // On macOS dev/simulator default to no access group to avoid -34018
        let status = attempt(addAccessGroup: false)
        #endif

        if status == errSecSuccess { return true }
        if status == -34018 && !triedWithoutGroup {
            SecureLogger.error(NSError(domain: "Keychain", code: -34018), context: "Missing keychain entitlement", category: .keychain)
        } else if status != errSecDuplicateItem {
            SecureLogger.error(NSError(domain: "Keychain", code: Int(status)), context: "Error saving to keychain", category: .keychain)
        }
        return false
    }
    
    private func retrieveData(forKey key: String) -> Data? {
        // Base query
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        func attempt(withAccessGroup: Bool) -> OSStatus {
            var q = base
            if withAccessGroup { q[kSecAttrAccessGroup as String] = appGroup }
            return SecItemCopyMatching(q as CFDictionary, &result)
        }

        #if os(iOS)
        var status = attempt(withAccessGroup: true)
        if status == -34018 { status = attempt(withAccessGroup: false) }
        #else
        let status = attempt(withAccessGroup: false)
        #endif

        if status == errSecSuccess { return result as? Data }
        if status == -34018 {
            SecureLogger.error(NSError(domain: "Keychain", code: -34018), context: "Missing keychain entitlement", category: .keychain)
        }
        return nil
    }
    
    private func delete(forKey key: String) -> Bool {
        // Base delete query
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service
        ]

        func attempt(withAccessGroup: Bool) -> OSStatus {
            var q = base
            if withAccessGroup { q[kSecAttrAccessGroup as String] = appGroup }
            return SecItemDelete(q as CFDictionary)
        }

        #if os(iOS)
        var status = attempt(withAccessGroup: true)
        if status == -34018 { status = attempt(withAccessGroup: false) }
        #else
        let status = attempt(withAccessGroup: false)
        #endif
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    // MARK: - Cleanup

    // Delete ALL keychain data for panic mode
    func deleteAllKeychainData() -> Bool {
        SecureLogger.warning("Panic mode - deleting all keychain data", category: .security)

        let ownedServices = Set(
            Self.applicationOwnedKeychainServices(
                primaryService: service
            )
        )
        var enumerationCompleted = true
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        let searchStatus = SecItemCopyMatching(
            searchQuery as CFDictionary,
            &result
        )
        switch searchStatus {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else {
                enumerationCompleted = false
                SecureLogger.error(
                    "Unable to decode application-owned keychain inventory",
                    category: .security
                )
                break
            }

            // Preserve the access-group sweep for custom services that are
            // not yet in the declared legacy-service list.
            for item in items {
                let account =
                    item[kSecAttrAccount as String] as? String ?? ""
                let itemService =
                    item[kSecAttrService as String] as? String ?? ""
                let accessGroup =
                    item[kSecAttrAccessGroup as String] as? String
                guard accessGroup == appGroup
                        || ownedServices.contains(itemService)
                else {
                    continue
                }

                var deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword
                ]
                if !account.isEmpty {
                    deleteQuery[kSecAttrAccount as String] = account
                }
                if !itemService.isEmpty {
                    deleteQuery[kSecAttrService as String] = itemService
                }
                if let accessGroup,
                   !accessGroup.isEmpty,
                   accessGroup != "test" {
                    deleteQuery[kSecAttrAccessGroup as String] = accessGroup
                }

                let status = SecItemDelete(deleteQuery as CFDictionary)
                if status != errSecSuccess && status != errSecItemNotFound {
                    enumerationCompleted = false
                    SecureLogger.error(
                        NSError(domain: "Keychain", code: Int(status)),
                        context: "Unable to delete enumerated application-owned keychain item",
                        category: .keychain
                    )
                }
            }

        case errSecItemNotFound:
            break

        default:
            enumerationCompleted = false
            SecureLogger.error(
                NSError(domain: "Keychain", code: Int(searchStatus)),
                context: "Unable to enumerate application-owned keychain items",
                category: .keychain
            )
        }

        // Bulk deletion by every application-owned service is authoritative
        // and idempotent. It also verifies that every known service scope is
        // empty even when the inventory pass found no items.
        let servicesCompleted =
            Self.deleteApplicationOwnedKeychainServices(
                primaryService: service
            ) { serviceName in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: serviceName
                ]
                let status = SecItemDelete(query as CFDictionary)
                if status != errSecSuccess && status != errSecItemNotFound {
                    SecureLogger.error(
                        NSError(domain: "Keychain", code: Int(status)),
                        context: "Unable to delete application-owned keychain service \(serviceName)",
                        category: .keychain
                    )
                }
                return status
            }

        // Historical builds attempted this application-group identifier as a
        // keychain access group. It is not currently entitled, so -34018
        // means the scope is inapplicable rather than partially deleted.
        let groupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: appGroup
        ]
        let groupStatus = SecItemDelete(groupQuery as CFDictionary)
        let groupCompleted = Self.completedApplicationGroupDelete(
            status: groupStatus
        )
        if !groupCompleted {
            SecureLogger.error(
                NSError(domain: "Keychain", code: Int(groupStatus)),
                context: "Unable to delete historical application-group keychain items",
                category: .keychain
            )
        }

        var markerCompleted = true
        #if os(iOS)
        // The non-secret marker is intentionally recreated after a panic so a
        // later uninstall/reinstall can still be distinguished from an in-place
        // upgrade. Do not commit the container-side marker here: reinstall
        // reconciliation may still need to retry an incomplete cleanup.
        if case .success = saveDataWithResult(
            Data([1]),
            forKey: Self.installMarkerAccount
        ) {
            markerCompleted = true
        } else {
            markerCompleted = false
            SecureLogger.error(
                "Unable to restore install-lifecycle keychain marker",
                category: .security
            )
        }
        #endif

        let completed =
            enumerationCompleted
            && servicesCompleted
            && groupCompleted
            && markerCompleted
        if completed {
            SecureLogger.warning(
                "Panic mode keychain cleanup completed",
                category: .keychain
            )
        } else {
            SecureLogger.error(
                "Panic mode keychain cleanup incomplete",
                category: .security
            )
        }
        return completed
    }
    
    // MARK: - Security Utilities
    
    /// Securely clear sensitive data from memory
    func secureClear(_ data: inout Data) {
        _ = data.withUnsafeMutableBytes { bytes in
            // Use volatile memset to prevent compiler optimization
            memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
        }
        data = Data() // Clear the data object
    }
    
    /// Securely clear sensitive string from memory
    func secureClear(_ string: inout String) {
        // Convert to mutable data and clear
        if var data = string.data(using: .utf8) {
            secureClear(&data)
        }
        string = "" // Clear the string object
    }
    
    // MARK: - Debug

    func verifyIdentityKeyExists() -> Bool {
        guard installAccessAllowed() else { return false }
        let key = "identity_noiseStaticKey"
        return retrieveData(forKey: key) != nil
    }

    // MARK: - Generic Data Storage (consolidated from KeychainHelper)

    /// Save data with a custom service name
    func save(key: String, data: Data, service customService: String, accessible: CFString?) {
        guard installAccessAllowed() else { return }
        let primaryKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: customService,
            kSecAttrAccount as String: key
        ]
        var addQuery = primaryKeyQuery
        addQuery.merge([
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible ?? Self.itemAccessibility,
            kSecAttrSynchronizable as String: false
        ]) { _, new in new }

        // Delete by the item's primary key only. Value/accessibility fields
        // are add attributes, not valid selectors for replacing an existing
        // item; including them can leave the old item in place and make the
        // subsequent add fail as a duplicate.
        let deleteStatus = SecItemDelete(primaryKeyQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            SecureLogger.error(
                NSError(domain: "Keychain", code: Int(deleteStatus)),
                context: "Unable to replace custom-service keychain item",
                category: .keychain
            )
            return
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            SecureLogger.error(
                NSError(domain: "Keychain", code: Int(addStatus)),
                context: "Unable to save custom-service keychain item",
                category: .keychain
            )
        }
    }

    /// Load data from a custom service
    func load(key: String, service customService: String) -> Data? {
        guard case .success(let data) = loadWithResult(key: key, service: customService) else {
            return nil
        }
        return data
    }

    /// Load custom-service data without collapsing `itemNotFound` and
    /// protected-data/keychain failures into the same nil result.
    func loadWithResult(key: String, service customService: String) -> KeychainReadResult {
        guard installAccessAllowed() else { return .accessDenied }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: customService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return classifyReadStatus(status, data: result as? Data)
    }

    /// Delete data from a custom service
    func delete(key: String, service customService: String) {
        guard installAccessAllowed() else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: customService,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }

    /// Delete every item stored under a custom service
    func deleteAll(service customService: String) {
        guard installAccessAllowed() else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: customService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return
        }
        for item in items {
            var deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: customService
            ]
            if let account = item[kSecAttrAccount as String] as? String {
                deleteQuery[kSecAttrAccount as String] = account
            }
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }
}
