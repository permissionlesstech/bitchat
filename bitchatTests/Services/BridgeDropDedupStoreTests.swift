//
// BridgeDropDedupStoreTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

@Suite("Bridge drop dedup persistence")
struct BridgeDropDedupStoreTests {

    // MARK: - ExpiringIDSet

    @Test func entriesExpireAfterLifetime() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var set = ExpiringIDSet(capacity: 8, lifetime: 60)

        let inserted = set.insert("a", now: start)
        #expect(inserted)
        #expect(set.contains("a", now: start))
        let duplicate = set.insert("a", now: start.addingTimeInterval(30))
        #expect(!duplicate)

        // Past the lifetime the slot is free again.
        let later = start.addingTimeInterval(61)
        #expect(!set.contains("a", now: later))
        let reinserted = set.insert("a", now: later)
        #expect(reinserted)
    }

    @Test func capacityEvictsOldestFirst() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var set = ExpiringIDSet(capacity: 2, lifetime: 3600)

        set.insert("oldest", now: start)
        set.insert("middle", now: start.addingTimeInterval(1))
        set.insert("newest", now: start.addingTimeInterval(2))

        let check = start.addingTimeInterval(3)
        #expect(!set.contains("oldest", now: check))
        #expect(set.contains("middle", now: check))
        #expect(set.contains("newest", now: check))
    }

    @Test func removeReleasesSlot() {
        let now = Date()
        var set = ExpiringIDSet(capacity: 8, lifetime: 3600)
        set.insert("a", now: now)
        set.remove("a")
        #expect(!set.contains("a", now: now))
        let reinserted = set.insert("a", now: now)
        #expect(reinserted)
    }

    @Test func initPrunesExpiredPersistedEntries() {
        let now = Date()
        let set = ExpiringIDSet(
            capacity: 8,
            lifetime: 3600,
            entries: [
                "stale": now.addingTimeInterval(-7200),
                "fresh": now.addingTimeInterval(-60)
            ],
            now: now
        )
        #expect(!set.contains("stale", now: now))
        #expect(set.contains("fresh", now: now))
    }

    // MARK: - Store round trip

    @Test func snapshotRoundTripsThroughDisk() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-dedup-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recorded = Date(timeIntervalSince1970: 1_700_000_000)

        let store = BridgeDropDedupStore(fileURL: fileURL)
        store.save(BridgeDropDedupStore.Snapshot(
            publishedDropKeys: ["msg-1": recorded],
            seenDropEventIDs: ["event-1": recorded]
        ))

        let reloaded = BridgeDropDedupStore(fileURL: fileURL).load()
        #expect(reloaded.publishedDropKeys["msg-1"] == recorded)
        #expect(reloaded.seenDropEventIDs["event-1"] == recorded)
    }

    @Test func wipeRemovesTheRecord() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-dedup-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = BridgeDropDedupStore(fileURL: fileURL)
        store.save(BridgeDropDedupStore.Snapshot(
            publishedDropKeys: ["msg-1": Date()],
            seenDropEventIDs: [:]
        ))
        store.wipe()

        let reloaded = BridgeDropDedupStore(fileURL: fileURL).load()
        #expect(reloaded.publishedDropKeys.isEmpty)
        #expect(reloaded.seenDropEventIDs.isEmpty)
    }

    @Test func nonPersistingStoreStaysEmpty() {
        let store = BridgeDropDedupStore(persistsToDisk: false)
        store.save(BridgeDropDedupStore.Snapshot(
            publishedDropKeys: ["msg-1": Date()],
            seenDropEventIDs: [:]
        ))
        #expect(store.load().publishedDropKeys.isEmpty)
    }
}
