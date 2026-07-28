import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Nostr identity lifecycle", .serialized)
struct NostrIdentityBridgeLifecycleTests {
    private static let identityKey = "nostr-current-identity"
    private static let service = "chat.bitchat.nostr"

    @Test("A truly absent identity is created durably and reused")
    func firstRunCreatesDurableIdentity() throws {
        let keychain = MockKeychain()
        let bridge = NostrIdentityBridge(keychain: keychain)

        let firstRead = try bridge.getCurrentNostrIdentity()
        let secondRead = try bridge.getCurrentNostrIdentity()
        let created = try #require(firstRead)
        let restored = try #require(secondRead)

        #expect(restored.publicKeyHex == created.publicKeyHex)
        guard case .success(let stored) = keychain.loadWithResult(
            key: Self.identityKey,
            service: Self.service
        ) else {
            Issue.record("Expected a durable identity after first-run creation")
            return
        }
        #expect(
            try JSONDecoder().decode(
                NostrIdentity.self,
                from: stored
            ).publicKeyHex == created.publicKeyHex
        )
    }

    @Test("Protected-data read failures never mint a replacement identity")
    func protectedDataFailureFailsClosed() {
        let keychain = MockKeychain()
        keychain.simulatedGenericReadError = .deviceLocked
        let bridge = NostrIdentityBridge(keychain: keychain)

        #expect(throws: (any Error).self) {
            _ = try bridge.getCurrentNostrIdentity()
        }
    }

    @Test("Transient keychain read failures never mint a replacement identity")
    func transientReadFailureFailsClosed() {
        let keychain = MockKeychain()
        keychain.simulatedGenericReadError = .otherError(-1)
        let bridge = NostrIdentityBridge(keychain: keychain)

        #expect(throws: (any Error).self) {
            _ = try bridge.getCurrentNostrIdentity()
        }
    }

    @Test("An undurable first-run identity is never returned")
    func saveFailureFailsClosed() {
        let keychain = MockKeychain()
        keychain.simulatedGenericSaveFailureKeys.insert(Self.identityKey)
        let bridge = NostrIdentityBridge(keychain: keychain)

        #expect(throws: (any Error).self) {
            _ = try bridge.getCurrentNostrIdentity()
        }
    }

    @Test("Concurrent bridge instances return one durable identity")
    func concurrentBridgeInstancesReturnSameIdentity() async throws {
        let keychain = BlockingIdentityLifecycleKeychain()
        let firstBridge = NostrIdentityBridge(keychain: keychain)
        let secondBridge = NostrIdentityBridge(keychain: keychain)

        let firstTask = Task.detached {
            try firstBridge.getCurrentNostrIdentity()
        }
        guard keychain.waitForFirstSave() else {
            keychain.releaseFirstSave()
            Issue.record("First identity creation never reached persistence")
            return
        }

        let secondTask = Task.detached {
            try secondBridge.getCurrentNostrIdentity()
        }
        // With instance-local locking the second bridge can create and read a
        // different identity while the first save is paused. With the shared
        // lifecycle lock it remains outside the keychain until the first
        // identity is durable.
        _ = keychain.waitForSecondCreation()
        keychain.releaseFirstSave()

        let first = try #require(try await firstTask.value)
        let second = try #require(try await secondTask.value)
        #expect(first.publicKeyHex == second.publicKeyHex)
        #expect(keychain.identitySaveCount == 1)
    }

    @Test("Panic clear cannot be overtaken by an in-flight identity save")
    func panicClearSerializesWithInFlightCreate() async throws {
        let keychain = BlockingIdentityLifecycleKeychain()
        let creatingBridge = NostrIdentityBridge(keychain: keychain)
        let clearingBridge = NostrIdentityBridge(keychain: keychain)

        let createTask = Task.detached {
            try creatingBridge.getCurrentNostrIdentity()
        }
        guard keychain.waitForFirstSave() else {
            keychain.releaseFirstSave()
            Issue.record("Identity creation never reached persistence")
            return
        }

        let clearTask = Task.detached {
            clearingBridge.clearAllAssociations()
        }
        // Before lifecycle serialization, panic deletion completes while the
        // pre-panic save is paused and that save can resurrect the identity.
        _ = keychain.waitForDeleteAll()
        keychain.releaseFirstSave()

        _ = try await createTask.value
        await clearTask.value

        guard case .itemNotFound = keychain.loadWithResult(
            key: Self.identityKey,
            service: Self.service
        ) else {
            Issue.record("A pre-panic identity was saved after panic clear")
            return
        }
    }
}

private final class BlockingIdentityLifecycleKeychain:
    KeychainManagerProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let firstSaveEntered = DispatchSemaphore(value: 0)
    private let firstSaveRelease = DispatchSemaphore(value: 0)
    private let secondCreationRead = DispatchSemaphore(value: 0)
    private let deleteAllCompleted = DispatchSemaphore(value: 0)
    private var serviceStorage: [String: [String: Data]] = [:]
    private var saveCount = 0
    private var didSignalSecondCreation = false

    var identitySaveCount: Int {
        lock.withLock { saveCount }
    }

    func waitForFirstSave() -> Bool {
        firstSaveEntered.wait(timeout: .now() + 1) == .success
    }

    func waitForSecondCreation() -> Bool {
        secondCreationRead.wait(timeout: .now() + 1) == .success
    }

    func waitForDeleteAll() -> Bool {
        deleteAllCompleted.wait(timeout: .now() + 1) == .success
    }

    func releaseFirstSave() {
        firstSaveRelease.signal()
    }

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        save(key: key, data: keyData, service: "identity", accessible: nil)
        return true
    }

    func getIdentityKey(forKey key: String) -> Data? {
        load(key: key, service: "identity")
    }

    func deleteIdentityKey(forKey key: String) -> Bool {
        delete(key: key, service: "identity")
        return true
    }

    func deleteAllKeychainData() -> Bool {
        lock.withLock {
            serviceStorage.removeAll()
        }
        return true
    }

    func secureClear(_ data: inout Data) {
        data = Data()
    }

    func secureClear(_ string: inout String) {
        string = ""
    }

    func verifyIdentityKeyExists() -> Bool {
        getIdentityKey(forKey: "identity_noiseStaticKey") != nil
    }

    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        guard let data = getIdentityKey(forKey: key) else {
            return .itemNotFound
        }
        return .success(data)
    }

    func saveIdentityKeyWithResult(
        _ keyData: Data,
        forKey key: String
    ) -> KeychainSaveResult {
        saveIdentityKey(keyData, forKey: key) ? .success : .otherError(-1)
    }

    func save(
        key: String,
        data: Data,
        service: String,
        accessible _: CFString?
    ) {
        let isFirstSave = lock.withLock {
            saveCount += 1
            return saveCount == 1
        }
        if isFirstSave {
            firstSaveEntered.signal()
            firstSaveRelease.wait()
        }
        lock.withLock {
            serviceStorage[service, default: [:]][key] = data
        }
    }

    func load(key: String, service: String) -> Data? {
        guard case .success(let data) = loadWithResult(
            key: key,
            service: service
        ) else {
            return nil
        }
        return data
    }

    func loadWithResult(
        key: String,
        service: String
    ) -> KeychainReadResult {
        let result: KeychainReadResult
        let shouldSignalSecondCreation: Bool
        (result, shouldSignalSecondCreation) = lock.withLock {
            guard let data = serviceStorage[service]?[key] else {
                return (.itemNotFound, false)
            }
            let shouldSignal = saveCount >= 2 && !didSignalSecondCreation
            if shouldSignal {
                didSignalSecondCreation = true
            }
            return (.success(data), shouldSignal)
        }
        if shouldSignalSecondCreation {
            secondCreationRead.signal()
        }
        return result
    }

    func delete(key: String, service: String) {
        _ = lock.withLock {
            serviceStorage[service]?.removeValue(forKey: key)
        }
    }

    func deleteAll(service: String) {
        _ = lock.withLock {
            serviceStorage.removeValue(forKey: service)
        }
        deleteAllCompleted.signal()
    }
}
