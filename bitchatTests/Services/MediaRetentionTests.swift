import BitFoundation
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

    @Test
    func quotaEvictionSkipsFilesAwaitingUIDeliveryUntilFinalized() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root, quotaBytes: 12)

        let pending = try #require(store.save(
            data: Data(repeating: 0xAA, count: 10),
            preferredName: "first.jpg",
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "img"
        ))
        store.beginPendingDelivery(at: pending)

        // Even under quota pressure from a second arrival, the pending file
        // stays protected on disk until UI delivery finishes.
        store.enforceQuota(reservingBytes: 10)
        #expect(FileManager.default.fileExists(atPath: pending.path))

        store.finishPendingDelivery(at: pending)
        store.enforceQuota(reservingBytes: 10)
        #expect(!FileManager.default.fileExists(atPath: pending.path))
    }

    @Test
    func publicQuotaEvictionNeverDeletesCommittedPrivateMedia() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root, quotaBytes: 25)

        let privateFileName = "img_\(UUID().uuidString).jpg"
        let privateFile = try #require(store.save(
            data: Data(repeating: 0x11, count: 15),
            preferredName: privateFileName,
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "img"
        ))
        let stableID = try #require(PrivateMediaMessageIdentity.stableID(
            senderPeerID: PeerID(str: "1122334455667788"),
            recipientPeerID: PeerID(str: "aabbccddeeff0011"),
            fileName: privateFileName
        ))
        #expect(store.commitPrivateMediaFile(messageID: stableID, storedURL: privateFile))

        let publicFile = try #require(store.save(
            data: Data(repeating: 0x22, count: 10),
            preferredName: "pub.jpg",
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "img"
        ))

        // Public broadcast flood under tight quota evicts old public media
        // but leaves committed private media intact.
        store.enforceQuota(reservingBytes: 20, isPrivate: false)
        #expect(FileManager.default.fileExists(atPath: privateFile.path))
        #expect(!FileManager.default.fileExists(atPath: publicFile.path))

        // Private arrivals may still reclaim oldest private media once no
        // public files remain to satisfy the quota.
        store.enforceQuota(reservingBytes: 20, isPrivate: true)
        #expect(!FileManager.default.fileExists(atPath: privateFile.path))
    }

    @Test
    func saveRecreatesDeletedFilesDirectoryAndFormatsFallbackTimestamp() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = BLEIncomingFileStore(baseDirectory: root, dateProvider: { fixedDate })

        let first = try #require(store.save(
            data: Data([0x01, 0x02]),
            preferredName: nil,
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "img"
        ))
        #expect(FileManager.default.fileExists(atPath: first.path))

        // Validate deterministic yyyyMMdd_HHmmss fallback naming when preferredName is nil.
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fixedDate)
        let expectedStamp = String(
            format: "%04d%02d%02d_%02d%02d%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            comps.year ?? 0,
            comps.month ?? 0,
            comps.day ?? 0,
            comps.hour ?? 0,
            comps.minute ?? 0,
            comps.second ?? 0
        )
        #expect(first.lastPathComponent.contains("_img_\(expectedStamp).jpg"))

        // Removing files/ externally must not leave a stale directory cache.
        try FileManager.default.removeItem(at: root.appendingPathComponent("files", isDirectory: true))
        let second = try #require(store.save(
            data: Data([0x03, 0x04]),
            preferredName: "second.jpg",
            subdirectory: "images/incoming",
            fallbackExtension: "jpg",
            defaultPrefix: "img"
        ))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    #if os(iOS)
    /// Media was the one persistence layer that never stated a protection
    /// class at its write site, so payloads inherited the container
    /// default. Saves must survive the added write option,
    /// and on device the class must read back. The simulator's filesystem
    /// does not model data protection (the attribute reads back nil there),
    /// so the readback assertion is device-only.
    @Test
    func savedMediaSurvivesExplicitProtectionClass() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root)

        let payload = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let saved = try #require(store.save(
            data: payload,
            preferredName: "note.m4a",
            subdirectory: "voicenotes/incoming",
            fallbackExtension: "m4a",
            defaultPrefix: "voice"
        ))

        #expect(try Data(contentsOf: saved) == payload)
        #if !targetEnvironment(simulator)
        let protection = try FileManager.default.attributesOfItem(
            atPath: saved.path
        )[.protectionKey] as? FileProtectionType
        #expect(protection == .completeUntilFirstUserAuthentication)
        #endif
    }

    /// Files written before payloads carried an explicit class are stamped
    /// by the launch-time migration that follows the retention sweep: the
    /// directory plus each resident file, without error. In-flight live
    /// captures are left alone, exactly as the sweep leaves them: the
    /// coordinator may still be writing to one through an open FileHandle,
    /// and new captures receive the class at creation. Readback is device-only for the same
    /// reason as above.
    @Test
    func migrationStampsPreexistingMediaAndSkipsLiveCaptures() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root)
        let incoming = try store.incomingDirectory(subdirectory: "voicenotes/incoming")

        let legacy = try write(
            "received.m4a",
            in: incoming,
            modified: Date(timeIntervalSinceNow: -60)
        )
        _ = try write(
            "\(BLEIncomingFileStore.liveCapturePrefix)00112233445566ff_dm.aac",
            in: incoming,
            modified: Date(timeIntervalSinceNow: -60)
        )

        // Exactly the directory itself plus the legacy file; strict equality
        // is what proves the live capture was not stamped.
        #expect(store.migrateFileProtectionIfNeeded() == 2)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #if !targetEnvironment(simulator)
        let protection = try FileManager.default.attributesOfItem(
            atPath: legacy.path
        )[.protectionKey] as? FileProtectionType
        #expect(protection == .completeUntilFirstUserAuthentication)
        #endif
    }

    /// A store with no media on disk has nothing to stamp.
    @Test
    func migrationWithNoMediaIsANoOp() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BLEIncomingFileStore(baseDirectory: root)

        #expect(store.migrateFileProtectionIfNeeded() == 0)
    }
    #endif
}
