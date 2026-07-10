//
// BLERecentPeripheralCacheTests.swift
// bitchatTests
//
// Eviction, expiry, and reconnect-target selection for the background
// wake-on-proximity peripheral cache.
//

import Testing
import Foundation
@testable import bitchat

struct BLERecentPeripheralCacheTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCache(capacity: Int = 4, maxAge: TimeInterval = 900) -> BLERecentPeripheralCache<String> {
        BLERecentPeripheralCache<String>(capacity: capacity, maxAge: maxAge)
    }

    @Test
    func recordUpsertsByPeripheralID() {
        let cache = makeCache()
        cache.record("p1", peripheralID: "A", at: base)
        cache.record("p1-updated", peripheralID: "A", at: base.addingTimeInterval(10))

        #expect(cache.count == 1)
        let targets = cache.reconnectTargets(now: base.addingTimeInterval(11), limit: 10) { _ in false }
        #expect(targets.map(\.peripheral) == ["p1-updated"])
    }

    @Test
    func overCapacityEvictsStalestEntry() {
        let cache = makeCache(capacity: 2)
        cache.record("p1", peripheralID: "A", at: base)
        cache.record("p2", peripheralID: "B", at: base.addingTimeInterval(1))
        cache.record("p3", peripheralID: "C", at: base.addingTimeInterval(2))

        #expect(cache.count == 2)
        let targets = cache.reconnectTargets(now: base.addingTimeInterval(3), limit: 10) { _ in false }
        #expect(targets.map(\.peripheralID) == ["C", "B"])
    }

    @Test
    func refreshingAnEntryProtectsItFromEviction() {
        let cache = makeCache(capacity: 2)
        cache.record("p1", peripheralID: "A", at: base)
        cache.record("p2", peripheralID: "B", at: base.addingTimeInterval(1))
        // A becomes the freshest again; adding C must evict B, not A
        cache.record("p1", peripheralID: "A", at: base.addingTimeInterval(2))
        cache.record("p3", peripheralID: "C", at: base.addingTimeInterval(3))

        let targets = cache.reconnectTargets(now: base.addingTimeInterval(4), limit: 10) { _ in false }
        #expect(targets.map(\.peripheralID) == ["C", "A"])
    }

    @Test
    func expiredEntriesArePruned() {
        let cache = makeCache(maxAge: 100)
        cache.record("p1", peripheralID: "A", at: base)
        cache.record("p2", peripheralID: "B", at: base.addingTimeInterval(50))

        let targets = cache.reconnectTargets(now: base.addingTimeInterval(120), limit: 10) { _ in false }
        #expect(targets.map(\.peripheralID) == ["B"])
        #expect(cache.count == 1)
    }

    @Test
    func targetsAreFreshestFirstAndCappedAtLimit() {
        let cache = makeCache(capacity: 8)
        for (index, id) in ["A", "B", "C", "D"].enumerated() {
            cache.record("p\(id)", peripheralID: id, at: base.addingTimeInterval(TimeInterval(index)))
        }

        let targets = cache.reconnectTargets(now: base.addingTimeInterval(10), limit: 2) { _ in false }
        #expect(targets.map(\.peripheralID) == ["D", "C"])
    }

    @Test
    func excludedPeripheralsAreSkippedWithoutConsumingTheLimit() {
        let cache = makeCache(capacity: 8)
        for (index, id) in ["A", "B", "C"].enumerated() {
            cache.record("p\(id)", peripheralID: id, at: base.addingTimeInterval(TimeInterval(index)))
        }

        // C (freshest) is already connected; the two slots go to B and A
        let targets = cache.reconnectTargets(now: base.addingTimeInterval(10), limit: 2) { $0 == "C" }
        #expect(targets.map(\.peripheralID) == ["B", "A"])
    }

    @Test
    func nonPositiveLimitReturnsNothing() {
        let cache = makeCache()
        cache.record("p1", peripheralID: "A", at: base)

        #expect(cache.reconnectTargets(now: base, limit: 0) { _ in false }.isEmpty)
        #expect(cache.reconnectTargets(now: base, limit: -3) { _ in false }.isEmpty)
    }
}
