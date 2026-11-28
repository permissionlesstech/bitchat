//
// NostrProcessedEventStoreTests.swift
// bitchatTests
//
// Regression tests for write-failure retries, deferred recovery flushing on
// load/loadAsync, and deferred queue deduplication in NostrProcessedEventStore.
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import bitchat

@Suite("Nostr Processed Event Store")
struct NostrProcessedEventStoreTests {
    private final class FaultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var shouldFailRead = false
        private var shouldFailWrite = false

        func setFailRead(_ value: Bool) {
            lock.lock()
            shouldFailRead = value
            lock.unlock()
        }

        func setFailWrite(_ value: Bool) {
            lock.lock()
            shouldFailWrite = value
            lock.unlock()
        }

        func failRead() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return shouldFailRead
        }

        func failWrite() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return shouldFailWrite
        }
    }

    private func makeFaultyStore(
        fileURL: URL,
        failRead: Bool = false,
        failWrite: Bool = false
    ) -> (store: NostrProcessedEventStore, faults: FaultBox) {
        let faults = FaultBox()
        faults.setFailRead(failRead)
        faults.setFailWrite(failWrite)
        let store = NostrProcessedEventStore(
            fileURL: fileURL,
            saveEventIDs: { ids in
                if faults.failWrite() {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
                }
                let data = try JSONEncoder().encode(ids)
                try data.write(to: fileURL, options: [.atomic])
            },
            readData: { url in
                if faults.failRead() {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                }
                return try Data(contentsOf: url)
            }
        )
        return (store, faults)
    }

    @Test func append_retriesAfterTransientWriteFailure() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostr-write-retry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let (store, faults) = makeFaultyStore(fileURL: fileURL, failWrite: true)

        store.append(["evt-1"], cap: 100)
        #expect(store.load().isEmpty)
        #expect(NostrProcessedEventStore(fileURL: fileURL).load().isEmpty)

        faults.setFailWrite(false)
        store.append(["evt-1"], cap: 100)
        #expect(store.load() == ["evt-1"])
        #expect(NostrProcessedEventStore(fileURL: fileURL).load() == ["evt-1"])
    }

    @Test func append_retainsUnsavedIDsAcrossSubsequentAppendAfterWriteFailure() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostr-write-retain-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let (store, faults) = makeFaultyStore(fileURL: fileURL, failWrite: true)

        store.append(["evt-1"], cap: 100)
        #expect(store.load().isEmpty)

        faults.setFailWrite(false)
        store.append(["evt-2"], cap: 100)
        #expect(store.load() == ["evt-1", "evt-2"])
        #expect(NostrProcessedEventStore(fileURL: fileURL).load() == ["evt-1", "evt-2"])
    }

    @Test func load_drainsAndPersistsDeferredIDsAfterReadRecovery() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostr-load-drain-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try JSONEncoder().encode(["old1", "old2"]).write(to: fileURL, options: [.atomic])
        let (store, faults) = makeFaultyStore(fileURL: fileURL, failRead: true)

        store.append(["while-locked"], cap: 100)
        #expect(store.load().isEmpty)

        faults.setFailRead(false)
        #expect(store.load() == ["old1", "old2", "while-locked"])
        #expect(NostrProcessedEventStore(fileURL: fileURL).load() == ["old1", "old2", "while-locked"])
    }

    @Test func loadAsync_drainsAndPersistsDeferredIDsAfterReadRecovery() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostr-load-async-drain-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try JSONEncoder().encode(["old1", "old2"]).write(to: fileURL, options: [.atomic])
        let (store, faults) = makeFaultyStore(fileURL: fileURL, failRead: true)

        store.append(["while-locked"], cap: 100)
        #expect(store.load().isEmpty)

        faults.setFailRead(false)
        let loaded = await withCheckedContinuation { continuation in
            store.loadAsync { ids in
                continuation.resume(returning: ids)
            }
        }
        #expect(loaded == ["old1", "old2", "while-locked"])
        #expect(NostrProcessedEventStore(fileURL: fileURL).load() == ["old1", "old2", "while-locked"])
    }

    @Test func deferredIDs_deduplicatedBeforeCapTrimDuringTransientError() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostr-deferred-dedup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try JSONEncoder().encode(["old1"]).write(to: fileURL, options: [.atomic])
        let (store, faults) = makeFaultyStore(fileURL: fileURL, failRead: true)

        store.append(["a", "b"], cap: 3)
        store.append(["b", "b", "b"], cap: 3)
        #expect(store.load().isEmpty)

        faults.setFailRead(false)
        #expect(store.load() == ["old1", "a", "b"])
    }

    @Test func mergeAndSave_writeFailureAfterReadRecovery_prunesAlreadyPersistedDeferredIDs() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostr-prune-deferred-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try JSONEncoder().encode(["old1"]).write(to: fileURL, options: [.atomic])
        let (store, faults) = makeFaultyStore(fileURL: fileURL, failRead: true, failWrite: true)

        store.append(["old1", "d1"], cap: 2)
        #expect(store.load().isEmpty)

        faults.setFailRead(false)
        store.append(["d2"], cap: 2)
        #expect(store.load() == ["old1"])

        faults.setFailWrite(false)
        #expect(store.load() == ["d1", "d2"])
    }

    @Test func wipe_clearsDeferredIDs() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nostr-wipe-deferred-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try JSONEncoder().encode(["old1"]).write(to: fileURL, options: [.atomic])
        let (store, faults) = makeFaultyStore(fileURL: fileURL, failRead: true)

        store.append(["pre-panic"], cap: 100)
        store.wipe()

        faults.setFailRead(false)
        #expect(store.load().isEmpty)
    }
}
