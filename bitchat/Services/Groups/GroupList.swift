//
// GroupList.swift
// bitchat
//
// A shared checklist per private group, kept as a state-based CRDT: every
// edit is a small piece of row state, and merging is a join, so members who
// edit apart (different partitions, hours off the mesh) converge on the same
// list once their edits meet, in whatever order they arrive.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Total order for the last-writer-wins registers: time first, then the
/// author's signing key bytes, so two edits in the same millisecond still
/// resolve the same way on every device.
struct GroupListStamp: Codable, Hashable, Comparable {
    let timestampMs: UInt64
    let author: Data

    static func < (lhs: GroupListStamp, rhs: GroupListStamp) -> Bool {
        if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs < rhs.timestampMs }
        return lhs.author.lexicographicallyPrecedes(rhs.author)
    }
}

/// One row's registers. Text is fixed when the row is added (an edit is a
/// remove plus a new add), checked is last-writer-wins, and removal is
/// permanent so a late add or check can never bring a deleted row back.
struct GroupListItemState: Codable, Equatable {
    struct Added: Codable, Equatable {
        let stamp: GroupListStamp
        let text: String
    }

    struct Checked: Codable, Equatable {
        let stamp: GroupListStamp
        let value: Bool
    }

    var added: Added?
    var checked: Checked?
    var removed: GroupListStamp?

    func merged(with other: GroupListItemState) -> GroupListItemState {
        GroupListItemState(
            added: Self.later(added, other.added) { lhs, rhs in
                lhs.stamp != rhs.stamp ? lhs.stamp < rhs.stamp : lhs.text < rhs.text
            },
            checked: Self.later(checked, other.checked) { lhs, rhs in
                lhs.stamp != rhs.stamp ? lhs.stamp < rhs.stamp : (!lhs.value && rhs.value)
            },
            removed: Self.later(removed, other.removed, by: <)
        )
    }

    var isLive: Bool { added != nil && removed == nil }

    /// The newest stamp on any register; local edits are stamped after it so
    /// they win even when this device's clock runs behind the last writer's.
    var latestStamp: GroupListStamp? {
        [added?.stamp, checked?.stamp, removed].compactMap { $0 }.max()
    }

    private static func later<T>(_ lhs: T?, _ rhs: T?, by isOrderedBefore: (T, T) -> Bool) -> T? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return isOrderedBefore(lhs, rhs) ? rhs : lhs
    }
}

/// Row state keyed by 16-byte item ID: the unit of both edits and snapshots.
typealias GroupListDelta = [Data: GroupListItemState]

struct GroupList: Codable, Equatable {
    static let itemIDLength = 16
    static let maxTextBytes = 200
    /// Rows shown and accepted for new local adds.
    static let maxVisibleItems = 64
    /// Rows retained including removal tombstones, so a stale add replayed
    /// from gossip can't resurrect a recently removed row.
    static let maxRecords = 256

    struct Item: Equatable, Identifiable {
        let id: Data
        let text: String
        let isChecked: Bool
        let addedAt: GroupListStamp
    }

    private(set) var records: GroupListDelta = [:]

    /// Live rows in the order they were added. Past the visible cap the
    /// newest adds are hidden, which every device agrees on.
    var items: [Item] {
        let live = records.compactMap { id, state -> Item? in
            guard state.isLive, let added = state.added else { return nil }
            return Item(id: id, text: added.text, isChecked: state.checked?.value ?? false, addedAt: added.stamp)
        }
        let ordered = live.sorted { lhs, rhs in
            lhs.addedAt != rhs.addedAt ? lhs.addedAt < rhs.addedAt : lhs.id.lexicographicallyPrecedes(rhs.id)
        }
        return Array(ordered.prefix(Self.maxVisibleItems))
    }

    /// Every record, for a full resend. A removed row only needs its removal
    /// (it outranks any add or check), so tombstones travel without their
    /// text and a full list stays well inside one group message.
    var snapshot: GroupListDelta {
        records.mapValues { state in
            guard let removed = state.removed else { return state }
            return GroupListItemState(removed: removed)
        }
    }

    /// Joins `delta` into the list and reports whether any row changed.
    @discardableResult
    mutating func merge(_ delta: GroupListDelta) -> Bool {
        var changed = false
        for (id, incoming) in delta where id.count == Self.itemIDLength {
            let current = records[id] ?? GroupListItemState()
            let merged = current.merged(with: incoming)
            if merged != current {
                records[id] = merged
                changed = true
            }
        }
        if changed { trimToCap() }
        return changed
    }

    // MARK: Local edits

    /// Adds a row and returns the delta to broadcast, or nil when the text
    /// is empty after cleanup or the list is full.
    mutating func add(text rawText: String, id: Data, author: Data, nowMs: UInt64) -> GroupListDelta? {
        guard id.count == Self.itemIDLength, records[id] == nil,
              let text = Self.sanitizedText(rawText),
              items.count < Self.maxVisibleItems else { return nil }
        let state = GroupListItemState(added: .init(stamp: GroupListStamp(timestampMs: nowMs, author: author), text: text))
        return apply([id: state])
    }

    mutating func setChecked(_ value: Bool, id: Data, author: Data, nowMs: UInt64) -> GroupListDelta? {
        guard let current = records[id], current.isLive else { return nil }
        guard (current.checked?.value ?? false) != value else { return nil }
        var state = current
        state.checked = .init(stamp: nextStamp(after: current, author: author, nowMs: nowMs), value: value)
        return apply([id: state])
    }

    mutating func remove(id: Data, author: Data, nowMs: UInt64) -> GroupListDelta? {
        guard let current = records[id], current.isLive else { return nil }
        var state = current
        state.removed = nextStamp(after: current, author: author, nowMs: nowMs)
        return apply([id: state])
    }

    /// Single-line text within the byte cap, trimmed on a Character boundary.
    static func sanitizedText(_ raw: String) -> String? {
        var text = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.utf8.count > maxTextBytes {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    // MARK: Internals

    private mutating func apply(_ delta: GroupListDelta) -> GroupListDelta {
        merge(delta)
        return delta
    }

    private func nextStamp(after state: GroupListItemState, author: Data, nowMs: UInt64) -> GroupListStamp {
        let floor = state.latestStamp.map { $0.timestampMs &+ 1 } ?? 0
        return GroupListStamp(timestampMs: max(nowMs, floor), author: author)
    }

    /// Drops the least useful records once over the cap: oldest tombstones
    /// first, then check marks for rows whose add never arrived, then the
    /// newest live rows (already hidden past the visible cap).
    private mutating func trimToCap() {
        guard records.count > Self.maxRecords else { return }
        let ranked = records.sorted { lhs, rhs in
            Self.evictionRank(lhs) < Self.evictionRank(rhs)
        }
        for (id, _) in ranked.prefix(records.count - Self.maxRecords) {
            records.removeValue(forKey: id)
        }
    }

    private static func evictionRank(_ entry: (key: Data, value: GroupListItemState)) -> EvictionRank {
        let state = entry.value
        if let removed = state.removed {
            return EvictionRank(tier: 0, stamp: removed, id: entry.key)
        }
        guard let added = state.added else {
            return EvictionRank(tier: 1, stamp: state.latestStamp, id: entry.key)
        }
        // Newest live rows go first, so invert the stamp order.
        return EvictionRank(tier: 2, stamp: GroupListStamp(timestampMs: .max - added.stamp.timestampMs, author: added.stamp.author), id: entry.key)
    }

    private struct EvictionRank: Comparable {
        let tier: Int
        let stamp: GroupListStamp?
        let id: Data

        static func < (lhs: EvictionRank, rhs: EvictionRank) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            switch (lhs.stamp, rhs.stamp) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return true
            case (_?, nil): return false
            default: return lhs.id.lexicographicallyPrecedes(rhs.id)
            }
        }
    }
}
