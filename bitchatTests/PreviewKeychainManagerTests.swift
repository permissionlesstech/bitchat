import Foundation
import Security
import Testing
import BitFoundation
@testable import bitchat

@Suite("PreviewKeychainManager Tests")
struct PreviewKeychainManagerTests {

    @Test("Install lifecycle distinguishes upgrade, reinstall, bootstrap, and unreadable keychain")
    func installLifecycleDecision() {
        #expect(KeychainManager.installLifecycleAction(
            containerKnowsMarker: true,
            markerRead: .success(Data([1]))
        ) == .markerPresent)
        #expect(KeychainManager.installLifecycleAction(
            containerKnowsMarker: false,
            markerRead: .success(Data([1]))
        ) == .clearStaleKeys)
        #expect(KeychainManager.installLifecycleAction(
            containerKnowsMarker: false,
            markerRead: .itemNotFound
        ) == .bootstrapMarker)
        #expect(KeychainManager.installLifecycleAction(
            containerKnowsMarker: false,
            markerRead: .deviceLocked
        ) == .retryLater)
        #expect(KeychainManager.installLifecycleAction(
            containerKnowsMarker: false,
            cleanupPending: true,
            markerRead: .itemNotFound
        ) == .clearStaleKeys)
    }

    @Test("Accessibility migration covers custom services and retries after any incomplete update")
    func accessibilityMigrationCoversEveryApplicationOwnedService() {
        let primaryService = "chat.bitchat.test-primary"
        var visitedServices: [String] = []

        let completed = KeychainManager
            .migrateAccessibilityForApplicationOwnedServices(
                primaryService: primaryService
            ) { service in
                visitedServices.append(service)
                return service == "chat.bitchat.favorites"
                    ? errSecInteractionNotAllowed
                    : errSecItemNotFound
            }

        #expect(!completed)
        #expect(visitedServices.first == primaryService)
        #expect(Set(visitedServices).isSuperset(of: [
            "chat.bitchat.nostr",
            "chat.bitchat.favorites",
            "chat.bitchat.outbox"
        ]))
        #expect(Set(visitedServices).count == visitedServices.count)

        let retryCompleted = KeychainManager
            .migrateAccessibilityForApplicationOwnedServices(
                primaryService: primaryService
            ) { _ in errSecSuccess }
        #expect(retryCompleted)
    }

    @Test("Keychain cleanup is complete only when every owned scope is clean")
    func keychainCleanupRequiresEveryApplicationOwnedService() {
        let primaryService = "chat.bitchat.test-primary"
        var visitedServices: [String] = []

        let partialCleanup = KeychainManager
            .deleteApplicationOwnedKeychainServices(
                primaryService: primaryService
            ) { service in
                visitedServices.append(service)
                return service == "chat.bitchat.outbox"
                    ? errSecInteractionNotAllowed
                    : errSecSuccess
            }

        #expect(!partialCleanup)
        #expect(visitedServices.first == primaryService)
        #expect(Set(visitedServices).isSuperset(of: [
            "chat.bitchat.nostr",
            "chat.bitchat.favorites",
            "chat.bitchat.outbox"
        ]))
        #expect(Set(visitedServices).count == visitedServices.count)

        let emptyCleanup = KeychainManager
            .deleteApplicationOwnedKeychainServices(
                primaryService: primaryService
            ) { _ in errSecItemNotFound }
        #expect(emptyCleanup)
        #expect(KeychainManager.completedApplicationGroupDelete(status: -34018))
        #expect(!KeychainManager.completedApplicationGroupDelete(
            status: errSecInteractionNotAllowed
        ))
    }

    @Test("Preview keychain manager stores identity and service-scoped data in memory")
    func previewKeychainManagerRoundTripsData() {
        let manager = PreviewKeychainManager()
        let identityKey = Data([1, 2, 3, 4])
        let serviceKey = "preview-service"
        let scopedData = Data([9, 8, 7, 6])

        #expect(!manager.verifyIdentityKeyExists())
        #expect(manager.saveIdentityKey(identityKey, forKey: "noiseStaticKey"))
        #expect(manager.getIdentityKey(forKey: "noiseStaticKey") == identityKey)
        #expect(manager.saveIdentityKey(identityKey, forKey: "identity_noiseStaticKey"))
        #expect(manager.verifyIdentityKeyExists())

        if case .success(let stored) = manager.getIdentityKeyWithResult(forKey: "noiseStaticKey") {
            #expect(stored == identityKey)
        } else {
            Issue.record("Expected stored preview identity key")
        }

        if case .success = manager.saveIdentityKeyWithResult(Data([5, 6, 7]), forKey: "ed25519SigningKey") {
        } else {
            Issue.record("Expected preview keychain save to succeed")
        }

        manager.save(key: "blob", data: scopedData, service: serviceKey, accessible: nil)
        #expect(manager.load(key: "blob", service: serviceKey) == scopedData)
        manager.delete(key: "blob", service: serviceKey)
        #expect(manager.load(key: "blob", service: serviceKey) == nil)

        var secretData = Data([4, 3, 2, 1])
        var secretString = "secret"
        manager.secureClear(&secretData)
        manager.secureClear(&secretString)
        #expect(secretData == Data([4, 3, 2, 1]))
        #expect(secretString == "secret")

        #expect(manager.deleteIdentityKey(forKey: "noiseStaticKey"))
        #expect(manager.deleteIdentityKey(forKey: "identity_noiseStaticKey"))
        #expect(manager.getIdentityKey(forKey: "noiseStaticKey") == nil)
        #expect(manager.deleteAllKeychainData())

        if case .itemNotFound = manager.getIdentityKeyWithResult(forKey: "ed25519SigningKey") {
        } else {
            Issue.record("Expected preview keychain to be empty after deleteAllKeychainData")
        }
    }

    @Test("Failed reinstall cleanup blocks stale data until a successful retry")
    func failedReinstallCleanupBlocksEveryNamespaceUntilSuccessfulRetry() {
        let gate = KeychainInstallAccessGate()
        var cleanupCanComplete = false
        var reconciliationAttempts = 0
        var manager: PreviewKeychainManager!
        manager = PreviewKeychainManager(
            installAccessGate: gate
        ) {
            reconciliationAttempts += 1
            guard cleanupCanComplete else { return false }
            return manager.deleteAllKeychainData()
        }

        let staleIdentity = Data([1, 2, 3])
        let staleFavorite = Data([4, 5, 6])
        let staleOutbox = Data([7, 8, 9])
        let staleCustom = Data([10, 11, 12])
        #expect(manager.saveIdentityKey(
            staleIdentity,
            forKey: "noiseStaticKey"
        ))
        #expect(manager.saveIdentityKey(
            staleIdentity,
            forKey: "identity_noiseStaticKey"
        ))
        #expect(manager.verifyIdentityKeyExists())
        manager.save(
            key: "favorite",
            data: staleFavorite,
            service: "chat.bitchat.favorites",
            accessible: nil
        )
        manager.save(
            key: "outbox",
            data: staleOutbox,
            service: "chat.bitchat.outbox",
            accessible: nil
        )
        manager.save(
            key: "custom",
            data: staleCustom,
            service: "chat.bitchat.future-custom",
            accessible: nil
        )

        gate.block()

        #expect(manager.getIdentityKey(forKey: "noiseStaticKey") == nil)
        #expect(!manager.verifyIdentityKeyExists())
        if case .accessDenied = manager.getIdentityKeyWithResult(
            forKey: "noiseStaticKey"
        ) {
        } else {
            Issue.record("Expected blocked identity read to fail closed")
        }

        for (key, service) in [
            ("favorite", "chat.bitchat.favorites"),
            ("outbox", "chat.bitchat.outbox"),
            ("custom", "chat.bitchat.future-custom")
        ] {
            #expect(manager.load(key: key, service: service) == nil)
            if case .accessDenied = manager.loadWithResult(
                key: key,
                service: service
            ) {
            } else {
                Issue.record(
                    "Expected blocked \(service) read to fail closed"
                )
            }
        }

        #expect(!manager.saveIdentityKey(
            Data([13]),
            forKey: "replacement"
        ))
        if case .accessDenied = manager.saveIdentityKeyWithResult(
            Data([14]),
            forKey: "replacement"
        ) {
        } else {
            Issue.record("Expected blocked identity save to fail closed")
        }

        let failedAttempts = reconciliationAttempts
        #expect(failedAttempts > 0)
        cleanupCanComplete = true

        // The first access retries cleanup synchronously. It must not return
        // any surviving value from before the reinstall.
        #expect(manager.getIdentityKey(forKey: "noiseStaticKey") == nil)
        #expect(reconciliationAttempts == failedAttempts + 1)
        #expect(manager.load(
            key: "favorite",
            service: "chat.bitchat.favorites"
        ) == nil)
        #expect(manager.load(
            key: "outbox",
            service: "chat.bitchat.outbox"
        ) == nil)
        #expect(manager.load(
            key: "custom",
            service: "chat.bitchat.future-custom"
        ) == nil)

        let replacementIdentity = Data([21, 22, 23])
        let replacementCustom = Data([24, 25, 26])
        #expect(manager.saveIdentityKey(
            replacementIdentity,
            forKey: "noiseStaticKey"
        ))
        #expect(manager.getIdentityKey(
            forKey: "noiseStaticKey"
        ) == replacementIdentity)
        manager.save(
            key: "custom",
            data: replacementCustom,
            service: "chat.bitchat.future-custom",
            accessible: nil
        )
        #expect(manager.load(
            key: "custom",
            service: "chat.bitchat.future-custom"
        ) == replacementCustom)
    }
}
