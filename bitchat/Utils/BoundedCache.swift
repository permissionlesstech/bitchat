//
// BoundedCache.swift
// bitchat
//
// O(1)-amortized bounded FIFO/LRU cache with optional TTL expiry.
// This is free and unencumbered software released into the public domain.
//

import Foundation

/// Bounded key-value cache with O(1)-amortized insertion, lookup, removal,
/// capacity eviction, and optional TTL expiry.
///
/// Order is tracked with a head-indexed sequence ring that skips tombstoned
/// or superseded entries and compacts when the dead prefix exceeds half the
/// buffer — avoiding O(N) `removeFirst()` shifts and O(N log N) sorts.
struct BoundedCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var timestamp: Date?
        var seq: UInt64
    }

    private let capacity: Int
    private let ttl: TimeInterval?

    private var storage: [Key: Entry] = [:]
    private var order: [(key: Key, seq: UInt64)] = []
    private var head: Int = 0
    private var nextSeq: UInt64 = 0

    init(capacity: Int, ttl: TimeInterval? = nil) {
        precondition(capacity > 0, "BoundedCache capacity must be positive")
        self.capacity = capacity
        self.ttl = ttl
    }

    var count: Int {
        storage.count
    }

    var allValues: [Key: Value] {
        storage.mapValues(\.value)
    }

    func value(for key: Key, now: Date? = nil) -> Value? {
        guard let entry = storage[key] else { return nil }
        if let ttl, let now, let recorded = entry.timestamp,
           now.timeIntervalSince(recorded) > ttl {
            return nil
        }
        return entry.value
    }

    func contains(_ key: Key, now: Date? = nil) -> Bool {
        value(for: key, now: now) != nil
    }

    /// Inserts or updates `key` with `value`.
    /// - Parameters:
    ///   - refreshOrder: When `true`, updating an existing key moves it to the
    ///     back of the eviction queue (LRU-on-write); when `false`, existing
    ///     keys keep their original insertion position (FIFO).
    /// - Returns: `true` if `key` was not previously present (or had expired).
    @discardableResult
    mutating func set(
        _ key: Key,
        value: Value,
        now: Date? = nil,
        refreshOrder: Bool = true
    ) -> Bool {
        if let now, ttl != nil {
            pruneExpired(now: now)
        }
        let wasPresent = storage[key] != nil
        if wasPresent && !refreshOrder {
            storage[key]?.value = value
            if let now { storage[key]?.timestamp = now }
            return false
        }

        let seq = nextSeq
        nextSeq &+= 1
        storage[key] = Entry(value: value, timestamp: now, seq: seq)
        order.append((key: key, seq: seq))
        evictIfNeeded()
        return !wasPresent
    }

    @discardableResult
    mutating func remove(_ key: Key) -> Value? {
        storage.removeValue(forKey: key)?.value
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        order.removeAll(keepingCapacity: keepingCapacity)
        head = 0
    }

    mutating func pruneExpired(now: Date) {
        guard let ttl else { return }
        while head < order.count {
            let item = order[head]
            guard let entry = storage[item.key], entry.seq == item.seq else {
                head += 1
                continue
            }
            if let recorded = entry.timestamp, now.timeIntervalSince(recorded) > ttl {
                storage.removeValue(forKey: item.key)
                head += 1
            } else {
                break
            }
        }
        compactIfNeeded()
    }

    mutating func shrinkIfOversized() {
        compactIfNeeded(force: true)
        if order.capacity > capacity * 2 && order.count < capacity {
            order.reserveCapacity(capacity)
        }
    }

    private mutating func evictIfNeeded() {
        while storage.count > capacity, head < order.count {
            let item = order[head]
            head += 1
            if let entry = storage[item.key], entry.seq == item.seq {
                storage.removeValue(forKey: item.key)
            }
        }
        compactIfNeeded()
    }

    /// Exposed for tests verifying that hot-key refreshes keep history bounded.
    var historyCountForTesting: Int {
        order.count
    }

    private mutating func compactIfNeeded(force: Bool = false) {
        while head < order.count {
            let item = order[head]
            if let entry = storage[item.key], entry.seq == item.seq {
                break
            }
            head += 1
        }
        let activeSpan = order.count - head
        let compactionThreshold = max(capacity * 2, 64)
        if activeSpan > compactionThreshold {
            order = order[head...].filter { item in
                guard let entry = storage[item.key] else { return false }
                return entry.seq == item.seq
            }
            head = 0
            return
        }
        guard head > 0 else { return }
        if force || (head >= 32 && head * 2 >= order.count) {
            order.removeFirst(head)
            head = 0
        }
    }
}
