import Foundation
import Testing
@testable import bitchat

struct BLEPrivateMediaReceiptStoreTests {
    private struct TestError: Error {}

    private let messageID = "media-00112233445566778899aabbccddeeff"

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
    func failedTombstonePersistenceDoesNotPoisonVolatileState() throws {
        let root = makeRoot("failed-tombstone-write")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(store.state(for: messageID) == .absent)

        // Force the atomic record write itself to fail after the store has
        // successfully loaded its empty index.
        let record = receiptRecord(in: root)
        try FileManager.default.createDirectory(
            at: record,
            withIntermediateDirectories: true
        )
        #expect(!store.recordDeleted(messageID: messageID))
        try FileManager.default.removeItem(at: record)

        // The UI must be able to report the deletion failure without a
        // process-lifetime tombstone silently hiding a later retry.
        #expect(store.state(for: messageID) == .absent)
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

    private func receiptRecord(in root: URL) -> URL {
        root
            .appendingPathComponent(
                "files/.private-media-receipts",
                isDirectory: true
            )
            .appendingPathComponent(messageID)
            .appendingPathExtension("json")
    }

    private func quarantinedRecord(in root: URL) -> URL {
        receiptRecord(in: root).appendingPathExtension("corrupt")
    }
}

/// Collects the URLs a store's data reader touched. A reference type so the
/// `@Sendable`-shaped reader closure can record without mutating captures.
private final class ReadTracker: @unchecked Sendable {
    private(set) var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}
