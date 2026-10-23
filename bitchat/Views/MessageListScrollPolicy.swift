//
// MessageListScrollPolicy.swift
// bitchat
//
// The pure rules behind MessageListView's scroll position: how many messages
// arrived since the list last looked, how wide the window must be to keep a
// scrolled-up reader's rows in place, and when the top row may expand the
// window. Kept free of SwiftUI so the rules are unit-testable.
//

import BitFoundation
import Foundation

enum MessageListScrollPolicy {
    /// What the list saw at its last look at a timeline.
    struct TimelineMark: Equatable {
        /// Conversation the mark belongs to; a mark never carries across.
        let contextKey: String
        /// Newest message at the time (nil: the timeline was empty), and its
        /// timestamp to fall back on if that message is gone by the next look.
        let newestMessageID: String?
        let newestTimestamp: Date?
        /// First message of the window at the time, and the window size it
        /// was taken at: a window resized since then voids it.
        let windowFirstMessageID: String?
        let windowCount: Int
    }

    /// Messages that landed after a mark's newest message.
    struct Appended: Equatable {
        /// Every such message: rows the window has to make room for.
        var total = 0
        /// Those the jump-to-latest pill counts.
        var unseen = 0
    }

    /// Messages the unseen counters may book as "new": rows that render as
    /// human messages. System lines render as narration and whitespace-only
    /// content never renders at all, so neither belongs in the pill count.
    static func isUnseenEligible(_ message: BitchatMessage) -> Bool {
        message.sender != "system" && !message.content.trimmed.isEmpty
    }

    /// Messages after `mark`'s newest one. Located by ID, not by count: at
    /// the store cap every append evicts the oldest message, so the count
    /// stops moving. If that message is gone (evicted by a burst larger than
    /// the cap, or removed), everything newer than its timestamp counts.
    static func appended(since mark: TimelineMark, in messages: [BitchatMessage]) -> Appended {
        let start: Int
        if let newestID = mark.newestMessageID, let newestTimestamp = mark.newestTimestamp {
            if let index = messages.lastIndex(where: { $0.id == newestID }) {
                start = index + 1
            } else {
                // The timeline is timestamp-ordered.
                start = (messages.lastIndex(where: { $0.timestamp <= newestTimestamp }) ?? -1) + 1
            }
        } else {
            start = 0
        }

        var appended = Appended()
        for message in messages[start...] {
            appended.total += 1
            if isUnseenEligible(message) {
                appended.unseen += 1
            }
        }
        return appended
    }

    /// Window size that keeps a scrolled-up reader's rows in place. The
    /// window is a suffix of the timeline, so every message landing below its
    /// first row (appended, or a late one inserted mid-timeline) would push
    /// that row out of the top and shift everything on screen up a row.
    /// While `mark` still describes the window, its first message stays
    /// first; otherwise the window grows by `appendedCount`. Never shrinks,
    /// never grows past the timeline.
    static func windowCountKeepingFirstRow(
        current: Int,
        mark: TimelineMark?,
        appendedCount: Int,
        in messages: [BitchatMessage]
    ) -> Int {
        let needed: Int
        if let mark,
           mark.windowCount == current,
           let firstID = mark.windowFirstMessageID,
           let index = messages.lastIndex(where: { $0.id == firstID }) {
            needed = messages.count - index
        } else {
            needed = current + appendedCount
        }
        return max(current, min(messages.count, needed))
    }

    /// Whether the window's first row coming on screen may grow the window.
    /// Not while an earlier expansion's position restore is still queued: the
    /// rows it inserted put a new first row on screen at once, and expanding
    /// again cascades straight to the oldest message. And not before the list
    /// has settled at the bottom of this context: the initial scroll down to
    /// the newest row starts with the top rows on screen.
    static func canExpandWindow(
        isRestoringExpansion: Bool,
        bottomSettledContextKey: String?,
        contextKey: String
    ) -> Bool {
        !isRestoringExpansion && bottomSettledContextKey == contextKey
    }

    /// The settled marker to keep when the list switches to `contextKey`.
    /// Row callbacks can land before the switch handler runs, so a marker
    /// already set by the new context's newest row stays; anything else is
    /// left over from another visit and must not let expansion run early.
    static func bottomSettledKey(_ settledKey: String?, afterSwitchingTo contextKey: String) -> String? {
        settledKey == contextKey ? settledKey : nil
    }

    /// Whether a throttled follow-scroll should still run when its timer
    /// fires. The timer is held back while a drag is tracking, so by then the
    /// reader may have scrolled away from the bottom or switched timelines.
    static func shouldRunDeferredFollowScroll(
        isAtBottom: Bool,
        scheduledContextKey: String,
        currentContextKey: String
    ) -> Bool {
        isAtBottom && scheduledContextKey == currentContextKey
    }
}

extension MessageListScrollPolicy.TimelineMark {
    /// Marks `messages` as seen, with the window taken at `windowCount`.
    init(contextKey: String, messages: [BitchatMessage], windowCount: Int) {
        self.init(
            contextKey: contextKey,
            newestMessageID: messages.last?.id,
            newestTimestamp: messages.last?.timestamp,
            windowFirstMessageID: messages.suffix(windowCount).first?.id,
            windowCount: windowCount
        )
    }

    /// The same mark with the window re-taken at `windowCount` (after the
    /// window grew without anything new being seen).
    func withWindowCount(_ windowCount: Int, in messages: [BitchatMessage]) -> Self {
        Self(
            contextKey: contextKey,
            newestMessageID: newestMessageID,
            newestTimestamp: newestTimestamp,
            windowFirstMessageID: messages.suffix(windowCount).first?.id,
            windowCount: windowCount
        )
    }
}
