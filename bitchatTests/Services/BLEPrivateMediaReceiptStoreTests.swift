import Foundation
import Testing
@testable import bitchat

struct BLEPrivateMediaReceiptStoreTests {
    private struct TestError: Error {}
    private struct LegacyReceiptFixture: Codable {
        let kind: String
        let relativePath: String?
        let recordedAt: Date
    }
    private struct LegacyJournalEntryFixture: Codable {
        let relativePaths: [String]
        let recordedAt: Date
    }
    private struct LegacyJournalFixture: Codable {
        let version: Int
        let entries: [String: LegacyJournalEntryFixture]
    }

    private let messageID = "media-00112233445566778899aabbccddeeff"
    private let secondMessageID = "media-ffeeddccbbaa99887766554433221100"

    @Test
    func acceptedReceiptPersistsAcrossStoreInstances() throws {
        let root = makeRoot("persist")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)

        let first = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(first.commitAccepted(messageID: messageID, storedURL: payload))
        #expect(first.state(for: messageID) == .accepted(payload))

        let relaunched = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .accepted(payload))
    }

    @Test
    func acceptedReceiptRejectsOutgoingPayloadAndCrossIDPathReuse() throws {
        let root = makeRoot("accepted-ownership")
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = try makePayload(in: root)
        let outgoingDirectory = root.appendingPathComponent("files/images/outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: outgoingDirectory, withIntermediateDirectories: true)
        let outgoing = outgoingDirectory.appendingPathComponent("image.jpg")
        try Data([0x01]).write(to: outgoing)
        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)

        #expect(!store.commitAccepted(messageID: messageID, storedURL: outgoing))
        #expect(store.commitAccepted(messageID: messageID, storedURL: incoming))
        #expect(!store.commitAccepted(messageID: secondMessageID, storedURL: incoming))
        #expect(FileManager.default.fileExists(atPath: incoming.path))
        #expect(FileManager.default.fileExists(atPath: outgoing.path))
    }

    @Test
    func liveAcceptedPathSurvivesTTLAndCapacityPressure() throws {
        let root = makeRoot("accepted-retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPayload = try makePayload(in: root, name: "first.jpg")
        let secondPayload = try makePayload(in: root, name: "second.jpg")
        let recordedAt = Date(timeIntervalSince1970: 2_000)
        let seed = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            capacity: 1,
            ttl: 1,
            now: { recordedAt }
        )
        #expect(seed.commitAccepted(messageID: messageID, storedURL: firstPayload))

        let relaunched = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            capacity: 1,
            ttl: 1,
            now: { recordedAt.addingTimeInterval(2) }
        )
        #expect(relaunched.state(for: messageID) == .accepted(firstPayload))
        #expect(!relaunched.commitAccepted(messageID: secondMessageID, storedURL: secondPayload))
        #expect(relaunched.state(for: messageID) == .accepted(firstPayload))
    }

    @Test
    func incomingAllocationUsesUniqueUUIDPrefixForEverySave() throws {
        let root = makeRoot("uuid-filenames")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root)

        let first = try #require(store.save(
            data: Data([0x01, 0x02]),
            preferredName: "image.jpg",
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "image"
        ))
        let second = try #require(store.save(
            data: Data([0x03, 0x04]),
            preferredName: "image.jpg",
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "image"
        ))

        #expect(first != second)
        #expect(first.lastPathComponent.hasSuffix("_image.jpg"))
        #expect(second.lastPathComponent.hasSuffix("_image.jpg"))
        #expect(first.lastPathComponent != "image.jpg")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test
    func missingAcceptedPayloadPrunesStaleReceiptSoRetryCanRestore() throws {
        let root = makeRoot("quota-evicted-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makePayload(in: root, name: "first.jpg")
        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(store.commitAccepted(messageID: messageID, storedURL: original))
        try FileManager.default.removeItem(at: original)

        #expect(store.state(for: messageID) == .absent)

        let restored = try makePayload(in: root, name: "second.jpg")
        #expect(store.commitAccepted(messageID: messageID, storedURL: restored))
        #expect(store.state(for: messageID) == .accepted(restored))
    }

    @Test
    func corruptLedgerFailsClosedWithoutDeletingOrOverwriting() throws {
        let root = makeRoot("corrupt-ledger")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        let seed = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(seed.commitAccepted(messageID: messageID, storedURL: payload))

        let ledger = ledgerURL(in: root)
        let corruptBytes = Data("{not-json".utf8)
        try corruptBytes.write(to: ledger, options: .atomic)

        let relaunched = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .unavailable)
        #expect(!relaunched.commitAccepted(messageID: messageID, storedURL: payload))
        #expect(!relaunched.recordDeleted(messageID: messageID))
        #expect(relaunched.isPayloadOwned(relativePath: "images/incoming/image.jpg") == nil)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(try Data(contentsOf: ledger) == corruptBytes)
    }

    @Test
    func transientReadFailureRecoversOnSubsequentLookup() throws {
        let root = makeRoot("transient-read-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        #expect(BLEPrivateMediaReceiptStore(baseDirectory: root).commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))

        var shouldFail = true
        let store = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            dataReader: { url in
                if shouldFail {
                    shouldFail = false
                    throw TestError()
                }
                return try Data(contentsOf: url)
            }
        )

        #expect(store.state(for: messageID) == .unavailable)
        #expect(store.state(for: messageID) == .accepted(payload))
    }

    @Test
    func deletionBatchCommitsAtomicallyBeforeRemovingPayloads() throws {
        let root = makeRoot("batch")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPayload = try makePayload(in: root, name: "first.jpg")
        let secondPayload = try makePayload(in: root, name: "second.jpg")
        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(store.commitAccepted(messageID: messageID, storedURL: firstPayload))
        #expect(store.commitAccepted(messageID: secondMessageID, storedURL: secondPayload))

        #expect(store.recordDeleted(messageIDs: [secondMessageID, messageID]))

        #expect(store.state(for: messageID) == .tombstoned)
        #expect(store.state(for: secondMessageID) == .tombstoned)
        #expect(!FileManager.default.fileExists(atPath: firstPayload.path))
        #expect(!FileManager.default.fileExists(atPath: secondPayload.path))

        let relaunched = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .tombstoned)
        #expect(relaunched.state(for: secondMessageID) == .tombstoned)
    }

    @Test
    func failedLedgerWriteLeavesAcceptedStateAndPayloadIntact() throws {
        let root = makeRoot("failed-delete-write")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        #expect(BLEPrivateMediaReceiptStore(baseDirectory: root).commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))

        let failingStore = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            dataWriter: { _, _, _ in throw TestError() }
        )

        #expect(!failingStore.recordDeleted(messageID: messageID))
        #expect(failingStore.state(for: messageID) == .accepted(payload))
        #expect(FileManager.default.fileExists(atPath: payload.path))
    }

    @Test
    func failedPayloadUnlinkCommitsTombstoneAndRetriesOnNextLookup() throws {
        let root = makeRoot("unlink-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        #expect(BLEPrivateMediaReceiptStore(baseDirectory: root).commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))

        let failingUnlink = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            payloadRemover: { _ in throw TestError() }
        )
        #expect(failingUnlink.recordDeleted(messageID: messageID))
        #expect(failingUnlink.state(for: messageID) == .tombstoned)
        #expect(FileManager.default.fileExists(atPath: payload.path))

        // On relaunch with a working remover, pendingUnlinkPaths finishes cleanup.
        let recovered = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(recovered.state(for: messageID) == .tombstoned)
        #expect(!FileManager.default.fileExists(atPath: payload.path))
    }

    @Test
    func pathlessNewDeletionFailsWithoutChangingReceiverState() {
        let root = makeRoot("pathless-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)

        #expect(!store.recordDeleted(messageID: messageID))
        #expect(store.state(for: messageID) == .absent)
    }

    @Test
    func deletionNeverRemovesDirectoryOrOutgoingTarget() throws {
        let root = makeRoot("safe-targets")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("files/images/incoming/archive", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let child = directory.appendingPathComponent("child.jpg")
        try Data([0x01]).write(to: child)

        let outgoingDir = root.appendingPathComponent("files/images/outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: outgoingDir, withIntermediateDirectories: true)
        let outgoing = outgoingDir.appendingPathComponent("victim.jpg")
        try Data([0x02]).write(to: outgoing)

        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(!store.recordDeleted(
            messageIDs: [messageID],
            payloadRelativePaths: [messageID: "images/incoming/archive"]
        ))
        #expect(!store.recordDeleted(
            messageIDs: [messageID],
            payloadRelativePaths: [messageID: "images/outgoing/victim.jpg"]
        ))
        #expect(FileManager.default.fileExists(atPath: child.path))
        #expect(FileManager.default.fileExists(atPath: outgoing.path))
    }

    @Test
    func migratesLegacyPerIDDirectoryJournalAndQuarantineOnceOnStartup() throws {
        let root = makeRoot("legacy-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let thirdMessageID = "media-11223344556677889900aabbccddeeff"
        let fourthMessageID = "media-aa11bb22cc33dd44ee55ff6600778899"

        let acceptedPayload = try makePayload(in: root, name: "accepted.jpg")
        let journalPayload = try makePayload(in: root, name: "journal-delete.jpg")
        let legacyPathfulPayload = try makePayload(in: root, name: "ambiguous.jpg")

        let legacyDir = legacyReceiptDirectory(in: root)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 5_000)

        // 1. Valid accepted record.
        try JSONEncoder().encode(LegacyReceiptFixture(
            kind: "accepted",
            relativePath: "images/incoming/accepted.jpg",
            recordedAt: now
        )).write(to: legacyDir.appendingPathComponent("\(messageID).json"), options: .atomic)

        // 2. Legacy pathful tombstone — must scrub path without unlinking ambiguous file.
        try JSONEncoder().encode(LegacyReceiptFixture(
            kind: "tombstone",
            relativePath: "images/incoming/ambiguous.jpg",
            recordedAt: now
        )).write(to: legacyDir.appendingPathComponent("\(secondMessageID).json"), options: .atomic)

        // 3. Corrupt per-ID file — must be quarantined without breaking other records.
        try Data("{corrupt".utf8).write(
            to: legacyDir.appendingPathComponent("\(thirdMessageID).json"),
            options: .atomic
        )

        // 4. Legacy deletion journal — must commit tombstone and unlink payload.
        try JSONEncoder().encode(LegacyJournalFixture(
            version: 1,
            entries: [
                fourthMessageID: LegacyJournalEntryFixture(
                    relativePaths: ["images/incoming/journal-delete.jpg"],
                    recordedAt: now
                )
            ]
        )).write(to: legacyDir.appendingPathComponent(".deletion-journal.json"), options: .atomic)

        let store = BLEPrivateMediaReceiptStore(baseDirectory: root, now: { now })
        #expect(store.state(for: messageID) == .accepted(acceptedPayload))
        #expect(store.state(for: secondMessageID) == .tombstoned)
        #expect(store.state(for: thirdMessageID) == .unavailable)
        #expect(store.state(for: fourthMessageID) == .tombstoned)

        #expect(FileManager.default.fileExists(atPath: acceptedPayload.path))
        #expect(FileManager.default.fileExists(atPath: legacyPathfulPayload.path))
        #expect(!FileManager.default.fileExists(atPath: journalPayload.path))
        #expect(FileManager.default.fileExists(atPath: ledgerURL(in: root).path))
        #expect(!FileManager.default.fileExists(atPath: legacyDir.path))

        // Quarantined ID stays fail-closed across relaunches.
        let relaunched = BLEPrivateMediaReceiptStore(baseDirectory: root, now: { now })
        #expect(relaunched.state(for: thirdMessageID) == .unavailable)
        #expect(!relaunched.commitAccepted(messageID: thirdMessageID, storedURL: acceptedPayload))
    }

    @Test
    func corruptLegacyDeletionJournalFailsClosedWithoutDeletingLegacyDirectory() throws {
        let root = makeRoot("corrupt-legacy-journal")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        let legacyDir = legacyReceiptDirectory(in: root)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(
            to: legacyDir.appendingPathComponent(".deletion-journal.json"),
            options: .atomic
        )

        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(store.state(for: messageID) == .unavailable)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(FileManager.default.fileExists(atPath: legacyDir.path))
    }

    @Test
    func unreleasedAggregateLedgerIsIgnoredAndLeftUntouched() throws {
        let root = makeRoot("no-unreleased-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let legacy = files.appendingPathComponent(".private-media-receipts.json", isDirectory: false)
        let bytes = Data(
            #"{"entries":{"media-00112233445566778899aabbccddeeff":{"relativePath":"images/incoming/old.jpg","acceptedAt":0}}}"#.utf8
        )
        try bytes.write(to: legacy, options: .atomic)

        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(store.state(for: messageID) == .absent)
        #expect(try Data(contentsOf: legacy) == bytes)
    }

    // MARK: - Helpers

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "private-media-receipt-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makePayload(in root: URL, name: String = "image.jpg") throws -> URL {
        let directory = root.appendingPathComponent("files/images/incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = directory.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: payload)
        return payload
    }

    private func ledgerURL(in root: URL) -> URL {
        root
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(BLEPrivateMediaReceiptStore.ledgerFileName, isDirectory: false)
    }

    private func legacyReceiptDirectory(in root: URL) -> URL {
        root.appendingPathComponent("files/.private-media-receipts", isDirectory: true)
    }
}
