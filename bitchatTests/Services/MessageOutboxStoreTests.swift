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

    @Test func wipeRemovesFileAndKey() {
        let fileURL = makeTempURL()
        let keychain = MockKeychain()
        let store = MessageOutboxStore(keychain: keychain, fileURL: fileURL)
        store.save([PeerID(str: "0000000000000001"): [makeMessage("m1")]])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        store.wipe()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
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
