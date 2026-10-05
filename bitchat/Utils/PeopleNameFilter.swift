//
//  PeopleNameFilter.swift
//  bitchat
//
//  This is free and unencumbered software released into the public domain.
//  For more information, see <https://unlicense.org>
//

import Foundation

/// Case-insensitive nickname / display-name match for the people sheet search field.
///
/// Filtering is display-only: callers never mutate `PeerListModel` row order.
/// Clearing the query restores the full list with existing sticky ordering.
enum PeopleNameFilter {
    /// Empty / whitespace-only queries match everything (no filter active).
    static func matches(_ displayName: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return displayName.localizedCaseInsensitiveContains(trimmed)
    }
}
