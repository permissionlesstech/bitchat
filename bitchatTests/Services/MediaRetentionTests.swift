import Foundation
import Testing
@testable import bitchat

/// Media used to be bounded only by a 100 MB incoming quota, so a received
/// photo or a sent voice note could sit on disk indefinitely — outliving the
/// conversation it belonged to, which is exactly what a seized device gives up.
/// These cover the age-based sweep that bounds it in time as well.
struct MediaRetentionTests {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("media-retention-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(
        _ name: String,
        in directory: URL,
        modified: Date
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: url.path
        )
        return url
    }

    @Test
    func expiresOutgoingMediaPastRetentionAndKeepsFreshMedia() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root)
        let outgoing = root.appendingPathComponent("files/images/outgoing", isDirectory: true)

        // Outgoing media had no lifetime at all before this sweep: the quota
        // only ever considered incoming directories.
        let stale = try write(
            "sent_old.jpg",
            in: outgoing,
            modified: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60)
        )
        let fresh = try write(
            "sent_new.jpg",
            in: outgoing,
            modified: Date(timeIntervalSinceNow: -60)
        )

        let removed = store.expireAgedMedia()

        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test
    func expiresIncomingMediaPastRetention() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root)
        let incoming = try store.incomingDirectory(subdirectory: "voicenotes/incoming")

        let stale = try write(
            "received.m4a",
            in: incoming,
            modified: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60)
        )

        #expect(store.expireAgedMedia() == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test
    func retentionSweepSkipsInFlightLiveCaptures() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root)
        let incoming = try store.incomingDirectory(subdirectory: "voicenotes/incoming")

        // Deleting a live capture mid-stream unlinks the inode under the
        // coordinator's open FileHandle, so age must not override the guard.
        let inFlight = try write(
            "\(BLEIncomingFileStore.liveCapturePrefix)00112233445566ff_dm.aac",
            in: incoming,
            modified: Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        )

        #expect(store.expireAgedMedia() == 0)
        #expect(FileManager.default.fileExists(atPath: inFlight.path))
    }

    @Test
    func nonPositiveRetentionIsANoOp() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root)
        let incoming = try store.incomingDirectory(subdirectory: "images/incoming")

        let file = try write(
            "received.jpg",
            in: incoming,
            modified: Date(timeIntervalSinceNow: -365 * 24 * 60 * 60)
        )

        #expect(store.expireAgedMedia(retention: 0) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func defaultRetentionIsSevenDays() {
        #expect(BLEIncomingFileStore.defaultMediaRetention == 7 * 24 * 60 * 60)
    }
}
