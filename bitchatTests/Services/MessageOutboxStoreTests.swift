//
// MessageOutboxStoreTests.swift
// bitchatTests
//
// Tests for the encrypted-at-rest outbox persistence.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

struct MessageOutboxStoreTests {

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-\(UUID().uuidString).sealed")
    }

    private func makeMessage(_ id: String, content: String = "hello") -> MessageOutboxStore.QueuedMessage {
        MessageOutboxStore.QueuedMessage(
            content: content,
            nickname: "peer",
            messageID: id,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            sendAttempts: 2,
            depositedCourierKeys: [Data(repeating: 0xC1, count: 32)]
        )
    }

    @Test func roundTripAcrossInstances() {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "0000000000000001")

        let store = MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        store.save([peerID: [makeMessage("m1")]])

        // Same keychain (encryption key) reads it back, fields intact.
        let reloaded = MessageOutboxStore(keychain: keychain, fileURL: fileURL).load()
        #expect(reloaded[peerID]?.count == 1)
        #expect(reloaded[peerID]?.first?.messageID == "m1")
        #expect(reloaded[peerID]?.first?.sendAttempts == 2)
        #expect(reloaded[peerID]?.first?.depositedCourierKeys.count == 1)
    }

    @Test func contentIsNotPlaintextOnDisk() throws {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = MessageOutboxStore(keychain: MockKeychain(), fileURL: fileURL)
        store.save([PeerID(str: "0000000000000001"): [makeMessage("m1", content: "very secret message")]])

        let raw = try Data(contentsOf: fileURL)
        #expect(!raw.isEmpty)
        // Sealed bytes must not contain the message plaintext.
        #expect(raw.range(of: Data("very secret message".utf8)) == nil)
    }

    @Test func loadWithoutKeyReturnsEmpty() {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = MessageOutboxStore(keychain: MockKeychain(), fileURL: fileURL)
        store.save([PeerID(str: "0000000000000001"): [makeMessage("m1")]])

        // A different keychain (fresh device / wiped key) cannot read the file.
        let other = MessageOutboxStore(keychain: MockKeychain(), fileURL: fileURL)
        #expect(other.load().isEmpty)
    }

    @Test func permanentlyMissingDeviceKeyDiscardsOrphanAndNewSavesSurviveRelaunch() {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "0000000000000001")

        MessageOutboxStore(keychain: keychain, fileURL: fileURL)
            .save([peerID: [makeMessage("orphaned")]])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        // Models a device restore: Application Support brought the sealed
        // file across, but its AfterFirstUnlockThisDeviceOnly key cannot.
        keychain.deleteAll(service: "chat.bitchat.outbox")
        let restored = MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        #expect(restored.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        restored.save([peerID: [makeMessage("fresh")]])
        let relaunched = MessageOutboxStore(keychain: keychain, fileURL: fileURL).load()
        #expect(relaunched[peerID]?.map(\.messageID) == ["fresh"])
    }

    @Test func temporarilyLockedKeyDoesNotDiscardDurableSnapshot() {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "0000000000000001")

        MessageOutboxStore(keychain: keychain, fileURL: fileURL)
            .save([peerID: [makeMessage("durable")]])
        let durableBytes = try? Data(contentsOf: fileURL)

        keychain.simulatedGenericReadError = .deviceLocked
        let restored = MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        #expect(restored.load().isEmpty)
        #expect((try? Data(contentsOf: fileURL)) == durableBytes)

        keychain.simulatedGenericReadError = nil
        let recovered = restored.retryDeferredLoad()
        #expect(recovered?[peerID]?.map(\.messageID) == ["durable"])
    }

    @Test @MainActor
    func panicWipeInvalidatesQueuedRecoveryCallback() async {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "0000000000000001")
        MessageOutboxStore(keychain: keychain, fileURL: fileURL)
            .save([peerID: [makeMessage("durable")]])

        var protectedDataUnavailable = true
        let restored = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        #expect(restored.load().isEmpty)
        var deliveredRecoveries: [MessageOutboxStore.Snapshot] = []
        restored.setRecoveryHandler { deliveredRecoveries.append($0) }

        protectedDataUnavailable = false
        restored.retryDeferredLoad() // queues the handler onto MainActor
        restored.wipe() // invalidates it before the queued Task runs
        await Task.yield()

        #expect(deliveredRecoveries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test @MainActor
    func wipeBetweenRecoveryUnlockAndNotificationDropsRecoveredSnapshot() async {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "0000000000000001")
        MessageOutboxStore(keychain: keychain, fileURL: fileURL)
            .save([peerID: [makeMessage("durable")]])

        var protectedDataUnavailable = true
        var gapAction: (() -> Void)?
        let restored = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            },
            beforeRecoveryNotification: { gapAction?() }
        )
        #expect(restored.load().isEmpty)
        var deliveredRecoveries: [MessageOutboxStore.Snapshot] = []
        restored.setRecoveryHandler { deliveredRecoveries.append($0) }
        gapAction = { restored.wipe() }

        protectedDataUnavailable = false
        restored.retryDeferredLoad()
        await Task.yield()

        #expect(deliveredRecoveries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func deferredRemovalTombstoneFiltersUnseenDurableMessage() {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "0000000000000001")
        MessageOutboxStore(keychain: keychain, fileURL: fileURL)
            .save([peerID: [makeMessage("durable")]])

        var protectedDataUnavailable = true
        let restored = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        #expect(restored.load().isEmpty)
        restored.recordRemoval(messageID: "durable")
        restored.save([:])

        protectedDataUnavailable = false
        let recovered = restored.retryDeferredLoad()
        #expect(recovered?.isEmpty == true)
        #expect(MessageOutboxStore(keychain: keychain, fileURL: fileURL).load().isEmpty)
    }

    @Test func deferredScopedRemovalTombstoneFiltersOnlySelectedPeer() {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let acknowledgedPeer = PeerID(str: "0000000000000001")
        let otherPeer = PeerID(str: "0000000000000002")
        MessageOutboxStore(keychain: keychain, fileURL: fileURL).save([
            acknowledgedPeer: [makeMessage("shared-id", content: "for acknowledged peer")],
            otherPeer: [makeMessage("shared-id", content: "for other peer")]
        ])

        var protectedDataUnavailable = true
        let restored = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        #expect(restored.load().isEmpty)
        restored.recordRemoval(messageID: "shared-id", for: [acknowledgedPeer])
        restored.save([:])

        protectedDataUnavailable = false
        let recovered = restored.retryDeferredLoad()
        #expect(recovered?[acknowledgedPeer] == nil)
        #expect(recovered?[otherPeer]?.map(\.messageID) == ["shared-id"])

        let relaunched = MessageOutboxStore(keychain: keychain, fileURL: fileURL).load()
        #expect(relaunched[acknowledgedPeer] == nil)
        #expect(relaunched[otherPeer]?.map(\.messageID) == ["shared-id"])
    }

    @Test func deniedPanicDeletionRetainsCiphertextButClearsMemoryAndMockedKey() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("outbox-panic-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }
        let file = root.appendingPathComponent("outbox.sealed")
        let sibling = root.appendingPathComponent("keep.txt")
        let siblingBytes = Data("SYNTHETIC_UNRELATED_FILE".utf8)
        try siblingBytes.write(to: sibling)
        let keychain = MockKeychain()
        let peerID = PeerID(str: "0000000000000001")
        let store = MessageOutboxStore(keychain: keychain, fileURL: file)
        store.save([peerID: [makeMessage("synthetic-before-panic")]])
        #expect(store.load()[peerID]?.map(\.messageID) == ["synthetic-before-panic"])
        #expect(keychain.load(key: "outbox-encryption-key", service: "chat.bitchat.outbox") != nil)
        let ciphertext = try Data(contentsOf: file)

        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(!store.wipe(), "Denied outbox byte deletion must be reported")
        #expect(store.load().isEmpty, "Outbox memory must clear despite failed byte deletion")
        #expect(keychain.load(key: "outbox-encryption-key", service: "chat.bitchat.outbox") == nil,
                "Failed byte deletion must still attempt mocked key deletion")
        #expect(try Data(contentsOf: file) == ciphertext)
        let reopened = MessageOutboxStore(keychain: keychain, fileURL: file)
        #expect(reopened.load().isEmpty, "The retained ciphertext must not recover messages without its mocked key")
        #expect(try Data(contentsOf: file) == ciphertext)
        #expect(try Data(contentsOf: sibling) == siblingBytes)

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(store.wipe(), "Outbox byte deletion must succeed after access is restored")
        #expect(!fm.fileExists(atPath: file.path))
        #expect(store.wipe(), "An absent outbox file must count as successful cleanup")
        #expect(try Data(contentsOf: sibling) == siblingBytes)
        store.save([peerID: [makeMessage("synthetic-after-panic")]])
        let fresh = MessageOutboxStore(keychain: keychain, fileURL: file).load()
        #expect(fresh[peerID]?.map(\.messageID) == ["synthetic-after-panic"])
    }

    @Test func unresolvedPanicLocationRetriesAndRetainsRecoveredOutboxLocation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("outbox-location-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("outbox.sealed")
        let keychain = MockKeychain()
        let peerID = PeerID(str: "0000000000000001")
        MessageOutboxStore(keychain: keychain, fileURL: file)
            .save([peerID: [makeMessage("synthetic-before-panic")]])
        let ciphertext = try Data(contentsOf: file)
        var available = false
        var lookups = 0
        let store = MessageOutboxStore(keychain: keychain, resolveDefaultFileURL: {
            lookups += 1
            return available ? file : nil
        })
        #expect(lookups == 1)
        #expect(!store.wipe(), "An unresolved outbox location must fail panic cleanup")
        #expect(lookups == 2, "Panic must retry an unresolved outbox location")
        #expect(store.load().isEmpty)
        #expect(try Data(contentsOf: file) == ciphertext)
        #expect(keychain.load(key: "outbox-encryption-key", service: "chat.bitchat.outbox") == nil)

        available = true
        #expect(store.wipe(), "A later panic attempt must resolve and remove the outbox file")
        #expect(lookups == 3)
        #expect(!fm.fileExists(atPath: file.path))
        available = false
        store.save([peerID: [makeMessage("synthetic-after-panic")]])
        #expect(lookups == 3)
        let reopened = MessageOutboxStore(keychain: keychain, fileURL: file).load()
        #expect(reopened[peerID]?.map(\.messageID) == ["synthetic-after-panic"],
                "Fresh outbox messages must persist at the recovered location")
        #expect(store.wipe())
        #expect(lookups == 3, "The recovered outbox location must remain cached")
        #expect(!fm.fileExists(atPath: file.path))
    }

    @Test func wipeRemovesFileAndKey() {
        let fileURL = makeTempURL()
        let keychain = MockKeychain()
        let store = MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        store.save([PeerID(str: "0000000000000001"): [makeMessage("m1")]])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        #expect(keychain.load(key: "outbox-encryption-key", service: "chat.bitchat.outbox") != nil)
        #expect(store.wipe())
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(keychain.load(key: "outbox-encryption-key", service: "chat.bitchat.outbox") == nil)
        #expect(store.load().isEmpty)
    }

    @Test func savingEmptyOutboxRemovesFile() {
        let fileURL = makeTempURL()
        let keychain = MockKeychain()
        let store = MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        let peerID = PeerID(str: "0000000000000001")
        store.save([peerID: [makeMessage("m1")]])
        store.save([peerID: []])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func protectedDataReadFailureDefersWriteAndMergesOnRecovery() {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "0000000000000001")

        let seed = MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        seed.save([peerID: [makeMessage("durable")]])
        let durableBytes = try? Data(contentsOf: fileURL)

        var protectedDataUnavailable = true
        let restored = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        #expect(restored.load().isEmpty)
        restored.save([peerID: [makeMessage("during-wake")]])

        // The unreadable durable snapshot was not replaced by the partial
        // in-memory outbox from the locked restoration.
        #expect((try? Data(contentsOf: fileURL)) == durableBytes)

        protectedDataUnavailable = false
        let recovered = restored.retryDeferredLoad()
        #expect(Set(recovered?[peerID]?.map(\.messageID) ?? []) == ["durable", "during-wake"])

        let relaunched = MessageOutboxStore(keychain: keychain, fileURL: fileURL).load()
        #expect(Set(relaunched[peerID]?.map(\.messageID) ?? []) == ["durable", "during-wake"])
    }

    @Test func lockedWakeRemovalDoesNotResurrectPendingMessageOnRecovery() {
        let fileURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let keychain = MockKeychain()
        let peerID = PeerID(str: "0000000000000001")
        MessageOutboxStore(keychain: keychain, fileURL: fileURL)
            .save([peerID: [makeMessage("durable")]])

        var protectedDataUnavailable = true
        let restored = MessageOutboxStore(
            keychain: keychain,
            fileURL: fileURL,
            readData: { url in
                if protectedDataUnavailable {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        #expect(restored.load().isEmpty)
        restored.save([peerID: [makeMessage("wake")]])
        // A later delivery ack produces the complete empty in-memory view.
        restored.save([:])

        protectedDataUnavailable = false
        let recovered = restored.retryDeferredLoad()
        #expect(recovered?[peerID]?.map(\.messageID) == ["durable"])
    }
}
