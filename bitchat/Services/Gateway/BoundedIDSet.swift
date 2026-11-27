//
// BoundedIDSet.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

/// Insertion-ordered string set with a fixed capacity; the oldest entry is
/// evicted when full. Shared by the gateway and bridge loop-prevention
/// caches.
struct BoundedIDSet {
    private var cache: BoundedCache<String, Void>

    init(capacity: Int) {
        self.cache = BoundedCache(capacity: capacity)
    }

    func contains(_ id: String) -> Bool {
        cache.contains(id)
    }

    /// Returns false when the ID was already present.
    @discardableResult
    mutating func insert(_ id: String) -> Bool {
        cache.set(id, value: (), refreshOrder: false)
    }
}
