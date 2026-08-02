//
//  ThreadMessageSearch.swift
//  bitchat
//
//  Filters the visible timeline for in-thread search.
//

import BitFoundation
import Foundation

enum ThreadMessageSearch {
    /// Returns messages whose body or sender name contains `query`
    /// (case-insensitive). An empty or whitespace-only query returns the
    /// original list unchanged.
    static func matchingMessages(
        in messages: [BitchatMessage],
        query: String
    ) -> [BitchatMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return messages }

        let needle = trimmed.lowercased()
        return messages.filter { message in
            guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            if message.content.lowercased().contains(needle) { return true }
            if message.sender.lowercased().contains(needle) { return true }
            return false
        }
    }
}
