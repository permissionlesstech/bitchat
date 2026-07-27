import Foundation
import Testing
@testable import bitchat

struct BLEPrivateMediaReceiptStoreTests {
    private struct TestError: Error {}
    private struct ReceiptFixture: Codable {
        let kind: String
        let relativePath: String?
        let recordedAt: Date
    }
    private struct JournalEntryFixture: Codable {
        let relativePaths: [String]
        let recordedAt: Date
    }
    private struct JournalFixture: Codable {
        let version: Int
        let entries: [String: JournalEntryFixture]
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
        let outgoingDirectory = root.appendingPathComponent(
            "files/images/outgoing",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outgoingDirectory,
            withIntermediateDirectories: true
        )
        let outgoing = outgoingDirectory.appendingPathComponent("image.jpg")
        try Data([0x01]).write(to: outgoing)
        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)

        #expect(!store.commitAccepted(
            messageID: messageID,
            storedURL: outgoing
        ))
        #expect(store.commitAccepted(
            messageID: messageID,
            storedURL: incoming
        ))
        #expect(!store.commitAccepted(
            messageID: secondMessageID,
            storedURL: incoming
        ))
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
        #expect(seed.commitAccepted(
            messageID: messageID,
            storedURL: firstPayload
        ))

        let relaunched = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            capacity: 1,
            ttl: 1,
            now: { recordedAt.addingTimeInterval(2) }
        )
        #expect(relaunched.state(for: messageID) == .accepted(firstPayload))
        #expect(!relaunched.commitAccepted(
            messageID: secondMessageID,
            storedURL: secondPayload
        ))
        #expect(relaunched.state(for: messageID) == .accepted(firstPayload))
    }

    @Test
    func incomingAllocationDoesNotReuseReceiptOwnedMissingPath() throws {
        let root = makeRoot("accepted-reservation")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makePayload(in: root)
        #expect(BLEPrivateMediaReceiptStore(
            baseDirectory: root
        ).commitAccepted(
            messageID: messageID,
            storedURL: original
        ))
        try FileManager.default.removeItem(at: original)

        let stored = BLEIncomingFileStore(baseDirectory: root).save(
            data: Data([0x03]),
            preferredName: "image.jpg",
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "image"
        )

        #expect(stored?.lastPathComponent != "image.jpg")
        #expect(stored.map {
            FileManager.default.fileExists(atPath: $0.path)
        } == true)
    }

    @Test
    func pendingRawArrivalBlocksDeletionFallbackPathReuse() throws {
        let root = makeRoot("pending-raw-arrival")
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = BLEIncomingFileStore(baseDirectory: root)

        // The old stable bubble names image.jpg, but its receipt and payload
        // have already been pruned. A raw arrival saves that basename before
        // its main-actor bubble is inserted.
        let rawArrival = incoming.save(
            data: Data([0x03]),
            preferredName: "image.jpg",
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "image"
        )
        #expect(rawArrival?.lastPathComponent == "image.jpg")

        let reservation = incoming.reservePrivateMediaDeletion(
            messageIDs: [messageID],
            payloadRelativePaths: [
                messageID: "images/incoming/image.jpg"
            ]
        )
        #expect(reservation == nil)
        #expect(rawArrival.map {
            FileManager.default.fileExists(atPath: $0.path)
        } == true)
    }

    @Test
    func quotaDoesNotEvictOrReusePendingDeliveryPath() throws {
        let root = makeRoot("pending-quota")
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = BLEIncomingFileStore(
            baseDirectory: root,
            quotaBytes: 1
        )
        let first = try #require(incoming.save(
            data: Data([0x01, 0x02]),
            preferredName: "image.jpg",
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "image"
        ))

        incoming.enforceQuota(reservingBytes: 1)
        #expect(FileManager.default.fileExists(atPath: first.path))

        let second = try #require(incoming.save(
            data: Data([0x03]),
            preferredName: "image.jpg",
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "image"
        ))
        #expect(second != first)
        #expect(second.lastPathComponent == "image (1).jpg")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test
    func invalidReceiptAndJournalCannotTargetOutgoingPayload() throws {
        let root = makeRoot("invalid-owned-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let outgoingDirectory = root.appendingPathComponent(
            "files/images/outgoing",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outgoingDirectory,
            withIntermediateDirectories: true
        )
        let victim = outgoingDirectory.appendingPathComponent("victim.jpg")
        try Data([0x02]).write(to: victim)
        let receiptURL = receiptRecord(in: root)
        try FileManager.default.createDirectory(
            at: receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fixture = ReceiptFixture(
            kind: "tombstone",
            relativePath: "images/outgoing/victim.jpg",
            recordedAt: Date()
        )
        try JSONEncoder().encode(fixture).write(
            to: receiptURL,
            options: .atomic
        )

        #expect(
            BLEPrivateMediaReceiptStore(baseDirectory: root)
                .state(for: messageID) == .unavailable
        )
        #expect(FileManager.default.fileExists(atPath: victim.path))

        // The invalid record was quarantined aside, never executed. Clear it
        // so the second phase exercises the journal validation on its own.
        #expect(!FileManager.default.fileExists(atPath: receiptURL.path))
        try FileManager.default.removeItem(at: quarantinedRecord(in: root))
        let journal = JournalFixture(
            version: 1,
            entries: [messageID: JournalEntryFixture(
                relativePaths: ["images/outgoing/victim.jpg"],
                recordedAt: fixture.recordedAt
            )]
        )
        try JSONEncoder().encode(journal).write(
            to: deletionJournal(in: root),
            options: .atomic
        )

        #expect(
            BLEPrivateMediaReceiptStore(baseDirectory: root)
                .state(for: messageID) == .unavailable
        )
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test
    func directoryEnumerationFailureIsUnavailableAndRetriesWithoutCachingEmpty() throws {
        let root = makeRoot("list-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        #expect(BLEPrivateMediaReceiptStore(baseDirectory: root).commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))
        let record = receiptRecord(in: root)
        #expect(FileManager.default.fileExists(atPath: record.path))

        var shouldFail = true
        let store = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            directoryReader: { directory in
                if shouldFail {
                    shouldFail = false
                    throw TestError()
                }
                return try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            }
        )

        #expect(store.state(for: messageID) == .unavailable)
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(store.state(for: messageID) == .accepted(payload))
    }

    @Test
    func recordReadFailureQuarantinesOnlyThatRecord() throws {
        let root = makeRoot("read-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        #expect(BLEPrivateMediaReceiptStore(baseDirectory: root).commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))
        let record = receiptRecord(in: root)
        let durableBytes = try Data(contentsOf: record)

        let store = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            dataReader: { url in
                if url.lastPathComponent.hasPrefix(self.messageID) {
                    throw TestError()
                }
                return try Data(contentsOf: url)
            }
        )

        #expect(store.state(for: messageID) == .unavailable)
        // The record was moved aside, bytes intact, not deleted.
        #expect(!FileManager.default.fileExists(atPath: record.path))
        let quarantined = quarantinedRecord(in: root)
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        #expect(try Data(contentsOf: quarantined) == durableBytes)
        // The quarantine is sticky for this ID; no absent/accepted flapping.
        #expect(store.state(for: messageID) == .unavailable)
    }

    @Test
    func decodeFailureQuarantinesRecordWithoutRetryOrDeletion() throws {
        let root = makeRoot("decode-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        #expect(BLEPrivateMediaReceiptStore(baseDirectory: root).commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))
        let record = receiptRecord(in: root)
        let corruptBytes = Data("{not-json".utf8)
        try corruptBytes.write(to: record, options: .atomic)

        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        // Only this ID fails closed; it cannot be re-recorded past the
        // quarantine either.
        #expect(store.state(for: messageID) == .unavailable)
        #expect(!store.commitAccepted(messageID: messageID, storedURL: payload))
        #expect(!store.recordDeleted(messageID: messageID))
        #expect(store.state(for: messageID) == .unavailable)

        // The unreadable bytes were preserved at the quarantine name.
        let quarantined = quarantinedRecord(in: root)
        #expect(!FileManager.default.fileExists(atPath: record.path))
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        #expect(try Data(contentsOf: quarantined) == corruptBytes)

        // A relaunch stays fail-closed for this ID without ever re-reading
        // the quarantined file.
        let readURLs = ReadTracker()
        let relaunched = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            dataReader: { url in
                readURLs.append(url)
                return try Data(contentsOf: url)
            }
        )
        #expect(relaunched.state(for: messageID) == .unavailable)
        #expect(!readURLs.urls.contains {
            $0.lastPathComponent == quarantined.lastPathComponent
        })
    }

    @Test
    func corruptRecordDoesNotBlockAnotherSendersMedia() throws {
        let root = makeRoot("quarantine-isolation")
        defer { try? FileManager.default.removeItem(at: root) }
        let otherMessageID = "media-ffeeddccbbaa99887766554433221100"
        let corruptPayload = try makePayload(in: root, name: "corrupt.jpg")
        let healthyPayload = try makePayload(in: root, name: "healthy.jpg")

        let seed = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(seed.commitAccepted(
            messageID: messageID,
            storedURL: corruptPayload
        ))
        #expect(seed.commitAccepted(
            messageID: otherMessageID,
            storedURL: healthyPayload
        ))
        try Data("{not-json".utf8).write(
            to: receiptRecord(in: root),
            options: .atomic
        )

        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        // Only the damaged record fails closed; the other sender's ledger
        // entry keeps serving and new decisions still commit durably.
        #expect(store.state(for: messageID) == .unavailable)
        #expect(store.state(for: otherMessageID) == .accepted(healthyPayload))

        let freshMessageID = "media-0102030405060708090a0b0c0d0e0f10"
        let freshPayload = try makePayload(in: root, name: "fresh.jpg")
        #expect(store.commitAccepted(
            messageID: freshMessageID,
            storedURL: freshPayload
        ))
        #expect(store.state(for: freshMessageID) == .accepted(freshPayload))
    }

    @Test
    func unreadableTombstoneNeverBecomesAbsentOrGetsDeleted() throws {
        let root = makeRoot("tombstone-decode")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        let seed = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(seed.commitAccepted(messageID: messageID, storedURL: payload))
        #expect(seed.recordDeleted(messageID: messageID))
        #expect(!FileManager.default.fileExists(atPath: payload.path))

        let record = receiptRecord(in: root)
        let corruptBytes = Data([0xFF, 0x00, 0x7B])
        try corruptBytes.write(to: record, options: .atomic)

        let relaunched = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .unavailable)
        // The quarantined tombstone can never flip to absent — a sender retry
        // must not resurrect explicitly deleted media even when the payload
        // bytes arrive again.
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: payload)
        #expect(!relaunched.commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))
        let quarantined = quarantinedRecord(in: root)
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        #expect(try Data(contentsOf: quarantined) == corruptBytes)
        #expect(
            BLEPrivateMediaReceiptStore(baseDirectory: root)
                .state(for: messageID) == .unavailable
        )
    }

    @Test
    func deletionBatchCommitsEveryIDBeforeRemovingPayloads() throws {
        let root = makeRoot("batch")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPayload = try makePayload(in: root, name: "first.jpg")
        let secondPayload = try makePayload(in: root, name: "second.jpg")
        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(store.commitAccepted(
            messageID: messageID,
            storedURL: firstPayload
        ))
        #expect(store.commitAccepted(
            messageID: secondMessageID,
            storedURL: secondPayload
        ))

        #expect(store.recordDeleted(
            messageIDs: [secondMessageID, messageID]
        ))

        #expect(store.state(for: messageID) == .tombstoned)
        #expect(store.state(for: secondMessageID) == .tombstoned)
        #expect(!FileManager.default.fileExists(atPath: firstPayload.path))
        #expect(!FileManager.default.fileExists(atPath: secondPayload.path))
        #expect(!FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))
    }

    @Test
    func failedJournalCommitPreservesAcceptedStateAndPayloads() throws {
        let root = makeRoot("journal-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPayload = try makePayload(in: root, name: "first.jpg")
        let secondPayload = try makePayload(in: root, name: "second.jpg")
        let seed = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(seed.commitAccepted(
            messageID: messageID,
            storedURL: firstPayload
        ))
        #expect(seed.commitAccepted(
            messageID: secondMessageID,
            storedURL: secondPayload
        ))

        let failing = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            dataWriter: { _, _, _ in throw TestError() }
        )
        #expect(!failing.recordDeleted(
            messageIDs: [messageID, secondMessageID]
        ))

        // A failed commit must not install a volatile tombstone. Otherwise a
        // sender retry could be ACKed although the caller kept both bubbles.
        #expect(failing.state(for: messageID) == .accepted(firstPayload))
        #expect(
            failing.state(for: secondMessageID) == .accepted(secondPayload)
        )
        #expect(FileManager.default.fileExists(atPath: firstPayload.path))
        #expect(FileManager.default.fileExists(atPath: secondPayload.path))
        #expect(!FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))
    }

    @Test
    func journalRecoversBatchAfterCrashDuringMaterialization() throws {
        let root = makeRoot("crash-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPayload = try makePayload(in: root, name: "first.jpg")
        let secondPayload = try makePayload(in: root, name: "second.jpg")
        let seed = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(seed.commitAccepted(
            messageID: messageID,
            storedURL: firstPayload
        ))
        #expect(seed.commitAccepted(
            messageID: secondMessageID,
            storedURL: secondPayload
        ))

        let interrupted = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            dataWriter: { data, url, options in
                let isJournal =
                    url.lastPathComponent == ".deletion-journal.json"
                let isFirstRecord =
                    url.deletingPathExtension().lastPathComponent == messageID
                guard isJournal || isFirstRecord else {
                    throw TestError()
                }
                try data.write(to: url, options: options)
            }
        )
        #expect(interrupted.recordDeleted(
            messageIDs: [messageID, secondMessageID]
        ))
        #expect(FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))
        #expect(!FileManager.default.fileExists(atPath: firstPayload.path))
        #expect(FileManager.default.fileExists(atPath: secondPayload.path))
        #expect(interrupted.state(for: messageID) == .tombstoned)
        #expect(interrupted.state(for: secondMessageID) == .tombstoned)

        let relaunched = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .tombstoned)
        #expect(relaunched.state(for: secondMessageID) == .tombstoned)
        #expect(!FileManager.default.fileExists(atPath: firstPayload.path))
        #expect(!FileManager.default.fileExists(atPath: secondPayload.path))
        #expect(!FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))
    }

    @Test
    func journalRetriesPayloadUnlinkAfterRelaunch() throws {
        let root = makeRoot("unlink-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        let seed = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(seed.commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))

        let unlinkFailure = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            payloadRemover: { _ in throw TestError() }
        )
        #expect(unlinkFailure.recordDeleted(messageID: messageID))
        #expect(unlinkFailure.state(for: messageID) == .tombstoned)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))

        let relaunched = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .tombstoned)
        #expect(!FileManager.default.fileExists(atPath: payload.path))
        #expect(!FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))
    }

    @Test
    func expiredReceiptUsesFallbackPathForCrashSafeCleanup() throws {
        let root = makeRoot("expired-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        let recordedAt = Date(timeIntervalSince1970: 1_000)
        let seed = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            ttl: 10,
            now: { recordedAt }
        )
        #expect(seed.commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))
        // Simulate a receipt pruned by an older app version while its bubble
        // and payload remain. Current code retains live accepted-path owners.
        try FileManager.default.removeItem(at: receiptRecord(in: root))

        let afterExpiry = recordedAt.addingTimeInterval(11)
        let interrupted = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            ttl: 10,
            now: { afterExpiry },
            payloadRemover: { _ in throw TestError() }
        )
        #expect(interrupted.recordDeleted(
            messageIDs: [messageID],
            payloadRelativePaths: [
                messageID: "images/incoming/image.jpg"
            ]
        ))
        #expect(interrupted.state(for: messageID) == .tombstoned)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))

        let relaunched = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            ttl: 10,
            now: { afterExpiry }
        )
        #expect(relaunched.state(for: messageID) == .tombstoned)
        #expect(!FileManager.default.fileExists(atPath: payload.path))
        #expect(!FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))
    }

    @Test
    func retryAtSuffixedPathDeletesReceiptAndBubblePayloads() throws {
        let root = makeRoot("retry-suffix")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makePayload(in: root)
        let seed = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(seed.commitAccepted(
            messageID: messageID,
            storedURL: original
        ))

        // Simulate an older build pruning only the receipt. A retry must use a
        // suffixed filename while the old bubble still references image.jpg.
        try FileManager.default.removeItem(at: receiptRecord(in: root))
        let retry = try makePayload(in: root, name: "image (1).jpg")
        let retried = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(retried.commitAccepted(
            messageID: messageID,
            storedURL: retry
        ))

        #expect(retried.recordDeleted(
            messageIDs: [messageID],
            payloadRelativePaths: [
                messageID: "images/incoming/image.jpg"
            ]
        ))
        #expect(retried.state(for: messageID) == .tombstoned)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: retry.path))
        #expect(!FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))

        let relaunched = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .tombstoned)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: retry.path))
    }

    @Test
    func protectedUIPathRejectsAcceptedReceiptDeletion() throws {
        let root = makeRoot("protected-ui-owner")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(store.commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))

        #expect(!store.recordDeleted(
            messageIDs: [messageID],
            protectedPayloadRelativePaths: [
                "images/incoming/image.jpg"
            ]
        ))
        #expect(store.state(for: messageID) == .accepted(payload))
        #expect(FileManager.default.fileExists(atPath: payload.path))
    }

    @Test
    func pathlessNewDeletionFailsWithoutChangingReceiverState() {
        let root = makeRoot("pathless-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)

        #expect(!store.recordDeleted(messageID: messageID))
        #expect(store.state(for: messageID) == .absent)
        #expect(!FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))
    }

    @Test
    func completedTombstoneNeverDeletesReusedPayloadPath() throws {
        let root = makeRoot("path-reuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makePayload(in: root)
        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(store.commitAccepted(
            messageID: messageID,
            storedURL: original
        ))
        #expect(store.recordDeleted(messageID: messageID))
        #expect(!FileManager.default.fileExists(atPath: original.path))

        let reused = try makePayload(in: root)
        #expect(store.commitAccepted(
            messageID: secondMessageID,
            storedURL: reused
        ))
        #expect(store.state(for: messageID) == .tombstoned)
        #expect(FileManager.default.fileExists(atPath: reused.path))

        let relaunched = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .tombstoned)
        #expect(FileManager.default.fileExists(atPath: reused.path))
        #expect(
            relaunched.state(for: secondMessageID) == .accepted(reused)
        )
    }

    @Test
    func expiredLegacyPathfulTombstoneDoesNotDeleteAcceptedOwner() throws {
        let root = makeRoot("legacy-path-conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        let receiptDirectory = receiptRecord(in: root)
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: receiptDirectory,
            withIntermediateDirectories: true
        )
        let recordedAt = Date(timeIntervalSince1970: 3_000)
        try JSONEncoder().encode(ReceiptFixture(
            kind: "tombstone",
            relativePath: "images/incoming/image.jpg",
            recordedAt: recordedAt
        )).write(
            to: receiptRecord(in: root),
            options: .atomic
        )
        try JSONEncoder().encode(ReceiptFixture(
            kind: "accepted",
            relativePath: "images/incoming/image.jpg",
            recordedAt: recordedAt
        )).write(
            to: receiptRecord(
                in: root,
                messageID: secondMessageID
            ),
            options: .atomic
        )

        let store = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            ttl: 1,
            now: { recordedAt.addingTimeInterval(2) }
        )
        #expect(store.state(for: messageID) == .absent)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(
            store.state(for: secondMessageID) == .accepted(payload)
        )
        #expect(FileManager.default.fileExists(atPath: payload.path))
    }

    @Test
    func expiredLegacyPathfulTombstonePreservesAmbiguousPayload() throws {
        let root = makeRoot("legacy-expired-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        let receiptURL = receiptRecord(in: root)
        try FileManager.default.createDirectory(
            at: receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let recordedAt = Date(timeIntervalSince1970: 3_000)
        try JSONEncoder().encode(ReceiptFixture(
            kind: "tombstone",
            relativePath: "images/incoming/image.jpg",
            recordedAt: recordedAt
        )).write(to: receiptURL, options: .atomic)

        let store = BLEPrivateMediaReceiptStore(
            baseDirectory: root,
            ttl: 1,
            now: { recordedAt.addingTimeInterval(2) }
        )

        #expect(store.state(for: messageID) == .absent)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(!FileManager.default.fileExists(atPath: receiptURL.path))
    }

    @Test
    func deletionJournalNeverRecursivelyRemovesDirectoryTarget() throws {
        let root = makeRoot("journal-directory")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            "files/images/incoming/archive",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let child = directory.appendingPathComponent("child.jpg")
        try Data([0x01]).write(to: child)
        let receiptDirectory = receiptRecord(in: root)
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: receiptDirectory,
            withIntermediateDirectories: true
        )
        #expect(!BLEPrivateMediaReceiptStore(
            baseDirectory: root
        ).recordDeleted(
            messageIDs: [messageID],
            payloadRelativePaths: [
                messageID: "images/incoming/archive"
            ]
        ))
        #expect(!FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))
        try JSONEncoder().encode(JournalFixture(
            version: 1,
            entries: [messageID: JournalEntryFixture(
                relativePaths: ["images/incoming/archive"],
                recordedAt: Date()
            )]
        )).write(to: deletionJournal(in: root), options: .atomic)

        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(store.state(for: messageID) == .tombstoned)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: child.path))
        #expect(FileManager.default.fileExists(
            atPath: deletionJournal(in: root).path
        ))
    }

    @Test
    func corruptDeletionJournalFailsClosedWithoutRemovingPayload() throws {
        let root = makeRoot("corrupt-journal")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        #expect(BLEPrivateMediaReceiptStore(
            baseDirectory: root
        ).commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))
        let journal = deletionJournal(in: root)
        try Data("{not-json".utf8).write(to: journal, options: .atomic)

        let relaunched = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .unavailable)
        #expect(!relaunched.commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(try Data(contentsOf: journal) == Data("{not-json".utf8))
    }

    @Test
    func unreleasedAggregateLedgerIsIgnoredAndLeftUntouched() throws {
        let root = makeRoot("no-legacy-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(
            at: files,
            withIntermediateDirectories: true
        )
        let legacy = files.appendingPathComponent(
            ".private-media-receipts.json",
            isDirectory: false
        )
        let bytes = Data(
            #"{"entries":{"media-00112233445566778899aabbccddeeff":{"relativePath":"images/incoming/old.jpg","acceptedAt":0}}}"#
                .utf8
        )
        try bytes.write(to: legacy, options: .atomic)

        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(store.state(for: messageID) == .absent)
        #expect(try Data(contentsOf: legacy) == bytes)
    }

    private func makeRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "private-media-receipt-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makePayload(
        in root: URL,
        name: String = "image.jpg"
    ) throws -> URL {
        let directory = root.appendingPathComponent(
            "files/images/incoming",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let payload = directory.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: payload)
        return payload
    }

    private func receiptRecord(
        in root: URL,
        messageID requestedMessageID: String? = nil
    ) -> URL {
        root
            .appendingPathComponent(
                "files/.private-media-receipts",
                isDirectory: true
            )
            .appendingPathComponent(requestedMessageID ?? messageID)
            .appendingPathExtension("json")
    }

    private func quarantinedRecord(in root: URL) -> URL {
        receiptRecord(in: root).appendingPathExtension("corrupt")
    }

    private func deletionJournal(in root: URL) -> URL {
        root
            .appendingPathComponent(
                "files/.private-media-receipts",
                isDirectory: true
            )
            .appendingPathComponent(".deletion-journal.json")
    }
}

/// Collects the URLs a store's data reader touched. A reference type so the
/// `@Sendable`-shaped reader closure can record without mutating captures.
private final class ReadTracker: @unchecked Sendable {
    private(set) var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}
