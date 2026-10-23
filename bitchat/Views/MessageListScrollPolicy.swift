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
        /// Messages in the timeline at the time.
        let count: Int
    }

    /// Messages that landed after a mark's newest message.
    struct Appended: Equatable {
        /// Every such message: rows the window has to make room for.
        var total = 0
        /// Those the jump-to-latest pill counts.
        var unseen = 0
    }

    /// What the list does about a change to the timeline it shows.
    enum TimelineReaction: Equatable {
        /// A timeline the list was not showing: land at its newest message.
        case land
        /// Scroll to the newest row.
        case follow
        /// Keep a scrolled-up reader's rows in place and count what's new.
        case keepPosition
        /// Leave the scroll alone: the rendered rows did not change.
        case hold
    }

    /// The reaction to a timeline change. `mark` is the mark taken in this
    /// timeline's context, if any; `appendedCount` what `appended(since:in:)`
    /// counted after it; `windowCount` the window size the list renders.
    static func reaction(
        mark: TimelineMark?,
        messages: [BitchatMessage],
        newestIsOwn: Bool,
        appendedCount: Int,
        windowCount: Int,
        isAtBottom: Bool
    ) -> TimelineReaction {
        // No mark here: the list arrives from another timeline (a channel or
        // DM switch), whatever the old timeline's row callbacks did to
        // isAtBottom on the way out.
        guard let mark else { return .land }
        // Emptied (e.g. /clear): nothing to scroll to.
        guard !messages.isEmpty else { return .hold }
        // A new message of mine takes the reader to it from anywhere. New
        // means appended since the mark (the newest message is then the last
        // one counted): an older message of mine that a removal left newest
        // (a retracted bridge alias, a dropped empty voice burst) is not.
        if newestIsOwn && appendedCount > 0 {
            return .follow
        }
        if !isAtBottom {
            return .keepPosition
        }
        // At the bottom, follow any change that can move the rendered rows: a
        // late message landing among the visible rows pushes the newest one
        // off screen. Only provably unchanged rows skip the scroll, which
        // would be a no-op, and a no-op scrollTo stays queued until the next
        // layout pass: the reader's next drag, which it snaps back down.
        let isWindowUnchanged = isRenderedWindowUnchanged(
            since: mark,
            appendedCount: appendedCount,
            windowCount: windowCount,
            in: messages
        )
        return isWindowUnchanged ? .hold : .follow
    }

    /// Whether the window rendered at the bottom (the last `windowCount`
    /// messages) holds exactly the rows it held at `mark`: nothing appended,
    /// the same message count, a full window starting at the same message.
    /// True for a late message landing above the window at the store cap
    /// (it evicts the oldest message, also above the window).
    static func isRenderedWindowUnchanged(
        since mark: TimelineMark,
        appendedCount: Int,
        windowCount: Int,
        in messages: [BitchatMessage]
    ) -> Bool {
        appendedCount == 0
            && mark.count == messages.count
            && mark.windowCount == windowCount
            && messages.count >= windowCount
            && mark.windowFirstMessageID == messages.suffix(windowCount).first?.id
    }

    /// Whether a row ID (`"<context>|<message id>"`) belongs to the timeline
    /// of `contextKey`. Row callbacks lag a switch, so the list checks them
    /// against the context it has landed in.
    static func isRow(_ rowID: String, inContext contextKey: String) -> Bool {
        rowID.hasPrefix(contextKey + "|")
    }

    /// Whether the retry of a scroll to the bottom has anything to do: not
    /// once the newest row is the one confirmed on screen, where the
    /// scrollTo would be a no-op that stays queued until the reader's next
    /// drag.
    static func needsScroll(toNewestRowID newestRowID: String?, bottomRowID: String?) -> Bool {
        guard let newestRowID else { return false }
        return newestRowID != bottomRowID
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
            windowCount: windowCount,
            count: messages.count
        )
    }

    /// The same mark with the window re-taken at `windowCount` (after the
    /// window was resized without anything new being seen).
    func withWindowCount(_ windowCount: Int, in messages: [BitchatMessage]) -> Self {
        Self(
            contextKey: contextKey,
            newestMessageID: newestMessageID,
            newestTimestamp: newestTimestamp,
            windowFirstMessageID: messages.suffix(windowCount).first?.id,
            windowCount: windowCount,
            count: count
        )
    }
}
