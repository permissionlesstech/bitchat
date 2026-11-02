//
// PeopleListOrdering.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

/// Row ordering for the people sheet's rosters.
///
/// Rows stay where they are while the sheet is open: ids already on screen
/// keep their relative order (minus anyone who left) and newcomers append in
/// the producer's order. Without this, recency-sorted rosters reshuffle on
/// every heartbeat and rows move out from under a tap.
enum PeopleListOrdering {
    /// Linear in the roster size; duplicate ids in `current` collapse to
    /// their first occurrence so `ForEach` identities stay unique.
    static func stableOrder(previous: [String], current: [String]) -> [String] {
        let currentIDs = Set(current)
        var ordered: [String] = []
        ordered.reserveCapacity(current.count)
        var placed = Set<String>()
        placed.reserveCapacity(current.count)
        for id in previous where currentIDs.contains(id) && placed.insert(id).inserted {
            ordered.append(id)
        }
        for id in current where placed.insert(id).inserted {
            ordered.append(id)
        }
        return ordered
    }
}
