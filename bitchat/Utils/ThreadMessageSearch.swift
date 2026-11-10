//
//  ThreadMessageSearch.swift
//  bitchat
//
//  Filters the visible timeline for in-thread search.
//

import BitFoundation
import Foundation

enum ThreadMessageSearch {
    /// Most matches rendered at once.
    ///
    /// Searching bypasses the message window, so without a cap a common term
    /// in a long thread renders every match in full history in one pass —
    /// unbounded work on the main thread. The newest matches are kept, which
    /// is the end of the thread people are usually looking at.
    static let resultLimit = 200

    /// Returns messages whose body or sender name contains `query`
    /// (case-insensitive), newest-biased and capped at `resultLimit`. An empty
    /// or whitespace-only query returns the original list unchanged.
    static func matchingMessages(
        in messages: [BitchatMessage],
        query: String,
        limit: Int = ThreadMessageSearch.resultLimit
    ) -> [BitchatMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return messages }

        let needle = trimmed.lowercased()
        let matches = messages.filter { message in
            guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            if message.content.lowercased().contains(needle) { return true }
            if message.sender.lowercased().contains(needle) { return true }
            return false
        }
        guard limit > 0, matches.count > limit else { return matches }
        // Keep the tail: `messages` is oldest-first, so the newest matches are
        // the ones a reader is most likely to want.
        return Array(matches.suffix(limit))
    }

    /// Whether a result set was truncated, so the UI can say so instead of
    /// quietly showing a partial list.
    static func didTruncate(
        matchCount: Int,
        limit: Int = ThreadMessageSearch.resultLimit
    ) -> Bool {
        limit > 0 && matchCount > limit
    }
}
