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
    func recordReadFailureIsUnavailableAndPreservesReceiptForRetry() throws {
        let root = makeRoot("read-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        #expect(BLEPrivateMediaReceiptStore(baseDirectory: root).commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))
        let record = receiptRecord(in: root)

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
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(store.state(for: messageID) == .accepted(payload))
    }

    @Test
    func decodeFailureIsUnavailableAndDoesNotDeleteOrCachePastRepair() throws {
        let root = makeRoot("decode-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makePayload(in: root)
        #expect(BLEPrivateMediaReceiptStore(baseDirectory: root).commitAccepted(
            messageID: messageID,
            storedURL: payload
        ))
        let record = receiptRecord(in: root)
        let durableBytes = try Data(contentsOf: record)
        let corruptBytes = Data("{not-json".utf8)
        try corruptBytes.write(to: record, options: .atomic)

        let store = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(store.state(for: messageID) == .unavailable)
        #expect(!store.commitAccepted(messageID: messageID, storedURL: payload))
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(try Data(contentsOf: record) == corruptBytes)

        try durableBytes.write(to: record, options: .atomic)
        #expect(store.state(for: messageID) == .accepted(payload))
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
        let durableBytes = try Data(contentsOf: record)
        try Data([0xFF, 0x00, 0x7B]).write(to: record, options: .atomic)

        let relaunched = BLEPrivateMediaReceiptStore(baseDirectory: root)
        #expect(relaunched.state(for: messageID) == .unavailable)
        #expect(FileManager.default.fileExists(atPath: record.path))

        try durableBytes.write(to: record, options: .atomic)
        #expect(relaunched.state(for: messageID) == .tombstoned)
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

    private func makePayload(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(
            "files/images/incoming",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let payload = directory.appendingPathComponent("image.jpg")
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
}
