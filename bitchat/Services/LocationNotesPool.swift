//
// LocationNotesPool.swift
// bitchat
//
// Refcounted pool of LocationNotesManager instances keyed by geohash, so
// surfaces watching the same place (the nearby-notes counter and the notices
// sheet's geo tab) share one relay subscription instead of opening two
// identical 9-cell REQs.
// This is free and unencumbered software released into the public domain.
//

import Foundation

@MainActor
final class LocationNotesPool {
    static let shared = LocationNotesPool()

    private var entries: [String: (manager: LocationNotesManager, refs: Int)] = [:]
    private let makeManager: @MainActor (String) -> LocationNotesManager

    /// The factory is injectable so tests can pool managers built over stub
    /// dependencies; live use derives one real manager per geohash.
    init(makeManager: @escaping @MainActor (String) -> LocationNotesManager = { LocationNotesManager(geohash: $0) }) {
        self.makeManager = makeManager
    }

    /// Returns the shared manager for `geohash` (case-insensitive), creating
    /// it on first acquire and reviving a cancelled one on re-acquire.
    /// Callers must never `cancel` a pooled manager — release it and acquire
    /// the new geohash instead.
    func acquire(_ geohash: String) -> LocationNotesManager {
        let key = geohash.lowercased()
        if let entry = entries[key] {
            entries[key] = (entry.manager, entry.refs + 1)
            if entry.manager.state == .idle {
                entry.manager.refresh()
            }
            return entry.manager
        }
        let manager = makeManager(key)
        entries[key] = (manager, 1)
        return manager
    }

    /// Balances `acquire`: the last release cancels the subscription and
    /// drops the entry. Releasing an instance the pool doesn't own (a
    /// test-injected manager) degrades to a plain `cancel()`.
    func release(_ manager: LocationNotesManager?) {
        guard let manager else { return }
        guard let entry = entries[manager.geohash], entry.manager === manager else {
            manager.cancel()
            return
        }
        if entry.refs <= 1 {
            entries[manager.geohash] = nil
            manager.cancel()
        } else {
            entries[manager.geohash] = (entry.manager, entry.refs - 1)
        }
    }
}
