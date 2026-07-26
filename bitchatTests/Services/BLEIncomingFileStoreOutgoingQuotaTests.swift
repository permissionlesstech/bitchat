import Foundation
import Testing
@testable import bitchat

@Suite("BLEIncomingFileStore outgoing quotas")
struct BLEIncomingFileStoreOutgoingQuotaTests {
    private func makeTempStore() throws -> (store: BLEIncomingFileStore, root: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitchat-outgoing-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BLEIncomingFileStore(baseDirectory: root)
        return (store, root, { try? FileManager.default.removeItem(at: root) })
    }

    private func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func writeBytes(_ count: Int, to url: URL, modified: Date) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: count).write(to: url)
        try setModificationDate(modified, at: url)
    }

    @Test func outgoingQuotaEvictsOldestAcrossMediaKinds() throws {
        let (store, root, cleanup) = try makeTempStore()
        defer { cleanup() }

        let oldURL = root.appendingPathComponent("files/voicenotes/outgoing/voice_old.m4a")
        let newURL = root.appendingPathComponent("files/images/outgoing/img_new.jpg")
        try writeBytes(60 * 1024 * 1024, to: oldURL, modified: Date(timeIntervalSinceNow: -3600))
        try writeBytes(45 * 1024 * 1024, to: newURL, modified: Date(timeIntervalSinceNow: -60))

        store.enforceOutgoingQuota(reservingBytes: 10 * 1024 * 1024)

        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newURL.path))
    }

    @Test func outgoingQuotaDoesNotEvictIncomingFiles() throws {
        let (store, root, cleanup) = try makeTempStore()
        defer { cleanup() }

        let incomingURL = root.appendingPathComponent("files/voicenotes/incoming/voice_incoming.m4a")
        let outgoingOld = root.appendingPathComponent("files/voicenotes/outgoing/voice_out_old.m4a")
        let outgoingNew = root.appendingPathComponent("files/voicenotes/outgoing/voice_out_new.m4a")
        try writeBytes(80 * 1024 * 1024, to: incomingURL, modified: Date(timeIntervalSinceNow: -7200))
        try writeBytes(60 * 1024 * 1024, to: outgoingOld, modified: Date(timeIntervalSinceNow: -3600))
        try writeBytes(45 * 1024 * 1024, to: outgoingNew, modified: Date(timeIntervalSinceNow: -60))

        store.enforceOutgoingQuota(reservingBytes: 10 * 1024 * 1024)

        #expect(FileManager.default.fileExists(atPath: incomingURL.path))
        #expect(!FileManager.default.fileExists(atPath: outgoingOld.path))
        #expect(FileManager.default.fileExists(atPath: outgoingNew.path))
    }

    @Test func outgoingQuotaHonorsPendingDeliveryReservationAndLiveCapturePrefix() throws {
        let (store, root, cleanup) = try makeTempStore()
        defer { cleanup() }

        // Unprotected oldest candidate — should be the one that yields.
        let unprotectedOld = root.appendingPathComponent(
            "files/images/outgoing/unprotected_old.jpg"
        )
        try writeBytes(
            70 * 1024 * 1024,
            to: unprotectedOld,
            modified: Date(timeIntervalSinceNow: -7200)
        )

        // In-flight live capture in the outgoing tree must never be unlinked
        // under an open FileHandle, even when it is the LRU-oldest file.
        let liveCapture = root.appendingPathComponent(
            "files/voicenotes/outgoing/\(BLEIncomingFileStore.liveCapturePrefix)aabbccddeeff0011.aac"
        )
        try writeBytes(
            20 * 1024 * 1024,
            to: liveCapture,
            modified: Date(timeIntervalSinceNow: -10_000)
        )

        // save() registers pendingDeliveryPaths on this instance — the same
        // coordination BLE deletion/delivery uses. Eviction must skip it.
        let pending = try #require(store.save(
            data: Data(count: 15 * 1024 * 1024),
            preferredName: "pending_outgoing.jpg",
            subdirectory: "images/outgoing",
            fallbackExtension: "jpg",
            defaultPrefix: "image"
        ))
        try setModificationDate(Date(timeIntervalSinceNow: -8000), at: pending)

        store.enforceOutgoingQuota(reservingBytes: 10 * 1024 * 1024)

        #expect(!FileManager.default.fileExists(atPath: unprotectedOld.path))
        #expect(FileManager.default.fileExists(atPath: liveCapture.path))
        #expect(FileManager.default.fileExists(atPath: pending.path))
    }

    @Test func outgoingQuotaHonorsIncomingDeletionReservationIsolation() throws {
        // Deletion reservations are registered on incoming receipt paths.
        // Prove that an active reservation on the *same store instance*
        // still protects that path when the incoming quota runs, while
        // outgoing eviction continues to free unprotected outgoing bytes.
        let (store, root, cleanup) = try makeTempStore()
        defer { cleanup() }

        let reservedIncoming = try #require(store.save(
            data: Data(count: 40 * 1024 * 1024),
            preferredName: "reserved.jpg",
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "image"
        ))
        try setModificationDate(Date(timeIntervalSinceNow: -7200), at: reservedIncoming)
        #expect(store.commitPrivateMediaFile(
            messageID: "media-aabbccddeeff00112233445566778899",
            storedURL: reservedIncoming
        ))
        // Finish delivery so pendingDeliveryPaths no longer protects it —
        // only the deletion reservation should.
        store.finishIncomingFileDelivery(at: reservedIncoming)

        let reservation = try #require(store.reservePrivateMediaDeletion(
            messageIDs: ["media-aabbccddeeff00112233445566778899"],
            payloadRelativePaths: [
                "media-aabbccddeeff00112233445566778899":
                    "images/incoming/\(reservedIncoming.lastPathComponent)"
            ]
        ))
        _ = reservation

        let otherIncoming = root.appendingPathComponent(
            "files/images/incoming/other_old.jpg"
        )
        try writeBytes(
            70 * 1024 * 1024,
            to: otherIncoming,
            modified: Date(timeIntervalSinceNow: -3600)
        )

        let outgoingOld = root.appendingPathComponent(
            "files/images/outgoing/out_old.jpg"
        )
        try writeBytes(
            60 * 1024 * 1024,
            to: outgoingOld,
            modified: Date(timeIntervalSinceNow: -3600)
        )
        let outgoingNew = root.appendingPathComponent(
            "files/images/outgoing/out_new.jpg"
        )
        try writeBytes(
            45 * 1024 * 1024,
            to: outgoingNew,
            modified: Date(timeIntervalSinceNow: -60)
        )

        store.enforceQuota(reservingBytes: 10 * 1024 * 1024)
        store.enforceOutgoingQuota(reservingBytes: 10 * 1024 * 1024)

        #expect(FileManager.default.fileExists(atPath: reservedIncoming.path))
        #expect(!FileManager.default.fileExists(atPath: otherIncoming.path))
        #expect(!FileManager.default.fileExists(atPath: outgoingOld.path))
        #expect(FileManager.default.fileExists(atPath: outgoingNew.path))
    }
}
