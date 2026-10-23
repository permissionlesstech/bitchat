//
// MessageListScrollPolicyTests.swift
// bitchatTests
//
// The pure rules behind MessageListView's scroll position: appended-message
// counting (including at the store cap, where the count stops moving), the
// window size that keeps a scrolled-up reader's first row in place, and the
// gates on window expansion and deferred follow-scrolls.
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

private typealias Policy = MessageListScrollPolicy

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

private func message(_ index: Int, sender: String = "alice", content: String? = nil, at timestamp: Double? = nil) -> BitchatMessage {
    BitchatMessage(
        id: "m\(index)",
        sender: sender,
        content: content ?? "message \(index)",
        timestamp: baseDate.addingTimeInterval(timestamp ?? Double(index)),
        isRelay: false
    )
}

private func timeline(_ range: Range<Int>) -> [BitchatMessage] {
    range.map { message($0) }
}

/// Inserts a late message (older timestamp) just before `index`.
private func inserting(_ late: BitchatMessage, before index: Int, in messages: [BitchatMessage]) -> [BitchatMessage] {
    var copy = messages
    copy.insert(late, at: index)
    return copy
}

struct MessageListScrollPolicyTests {

    // MARK: - Timeline marks

    @Test
    func timelineMark_recordsTheNewestMessageAndTheWindowsFirstRow() {
        let messages = timeline(0..<10)
        let mark = Policy.TimelineMark(contextKey: "mesh", messages: messages, windowCount: 4)

        #expect(mark.newestMessageID == "m9")
        #expect(mark.newestTimestamp == messages[9].timestamp)
        #expect(mark.windowFirstMessageID == "m6")
        #expect(mark.windowCount == 4)

        // A window wider than the timeline starts at its oldest message.
        #expect(Policy.TimelineMark(contextKey: "mesh", messages: messages, windowCount: 300).windowFirstMessageID == "m0")
        // An empty timeline marks nothing.
        let empty = Policy.TimelineMark(contextKey: "mesh", messages: [], windowCount: 300)
        #expect(empty.newestMessageID == nil)
        #expect(empty.windowFirstMessageID == nil)
    }

    @Test
    func timelineMark_withWindowCountRetakesOnlyTheWindow() {
        let messages = timeline(0..<10)
        let mark = Policy.TimelineMark(contextKey: "geo:u4pruy", messages: Array(messages.prefix(8)), windowCount: 4)

        let expanded = mark.withWindowCount(7, in: messages)

        #expect(expanded.contextKey == "geo:u4pruy")
        // What was seen stays as it was; the window is re-taken.
        #expect(expanded.newestMessageID == "m7")
        #expect(expanded.windowFirstMessageID == "m3")
        #expect(expanded.windowCount == 7)
    }

    // MARK: - Appended messages

    @Test
    func appended_countsOnlyMessagesAfterTheMarkedNewest() {
        let mark = Policy.TimelineMark(contextKey: "mesh", messages: timeline(0..<6), windowCount: 300)
        var messages = timeline(0..<9)
        messages.append(message(9, sender: "system"))
        messages.append(message(10, content: "   "))

        let appended = Policy.appended(since: mark, in: messages)

        // m6, m7, m8, a system line and a whitespace-only message landed; the
        // pill counts only the three human messages.
        #expect(appended == Policy.Appended(total: 5, unseen: 3))
    }

    @Test
    func appended_countsEverythingWhenTheTimelineWasEmpty() {
        let mark = Policy.TimelineMark(contextKey: "mesh", messages: [], windowCount: 300)

        #expect(Policy.appended(since: mark, in: timeline(0..<3)) == Policy.Appended(total: 3, unseen: 3))
        #expect(Policy.appended(since: mark, in: []) == Policy.Appended())
    }

    @Test
    func appended_keepsCountingAtTheStoreCap() {
        // At the cap every append evicts the oldest message: the count never
        // moves, but the appended messages are still found after the newest.
        let capped = timeline(0..<10)
        let mark = Policy.TimelineMark(contextKey: "mesh", messages: capped, windowCount: 300)
        let afterThreeAppends = timeline(3..<13)
        #expect(afterThreeAppends.count == capped.count)

        #expect(Policy.appended(since: mark, in: afterThreeAppends) == Policy.Appended(total: 3, unseen: 3))
    }

    @Test
    func appended_doesNotCountLateMessagesLandingAboveTheNewest() {
        let messages = timeline(0..<10)
        let mark = Policy.TimelineMark(contextKey: "mesh", messages: messages, windowCount: 300)
        let late = message(100, at: 7.5)

        let withLate = inserting(late, before: 8, in: messages)

        #expect(Policy.appended(since: mark, in: withLate) == Policy.Appended())
    }

    @Test
    func appended_fallsBackToTimestampsWhenTheNewestIsGone() {
        let mark = Policy.TimelineMark(contextKey: "mesh", messages: timeline(0..<10), windowCount: 300)

        // The newest seen message was removed (e.g. a block purge); two
        // newer ones landed since.
        let removedNewest = timeline(0..<9) + timeline(10..<12)
        #expect(Policy.appended(since: mark, in: removedNewest) == Policy.Appended(total: 2, unseen: 2))

        // A burst larger than the cap evicted it: everything left is newer.
        let evictedNewest = timeline(20..<30)
        #expect(Policy.appended(since: mark, in: evictedNewest) == Policy.Appended(total: 10, unseen: 10))
    }

    // MARK: - Window growth

    @Test
    func windowCountKeepingFirstRow_growsOverMessagesAppendedBelowIt() {
        let messages = timeline(0..<20)
        let mark = Policy.TimelineMark(contextKey: "mesh", messages: messages, windowCount: 10)

        let grown = Policy.windowCountKeepingFirstRow(
            current: 10,
            mark: mark,
            appendedCount: 0,
            in: messages + timeline(20..<23)
        )

        #expect(grown == 13)
        #expect((messages + timeline(20..<23)).suffix(grown).first?.id == "m10")
    }

    @Test
    func windowCountKeepingFirstRow_absorbsLateMessagesInsertedBelowIt() {
        let messages = timeline(0..<20)
        let mark = Policy.TimelineMark(contextKey: "mesh", messages: messages, windowCount: 10)

        // Below the first row: the window grows to keep it.
        let lateInside = inserting(message(100, at: 15.5), before: 16, in: messages)
        #expect(Policy.windowCountKeepingFirstRow(current: 10, mark: mark, appendedCount: 0, in: lateInside) == 11)

        // Above the first row: the suffix already keeps it.
        let lateAbove = inserting(message(101, at: 4.5), before: 5, in: messages)
        #expect(Policy.windowCountKeepingFirstRow(current: 10, mark: mark, appendedCount: 0, in: lateAbove) == 10)
    }

    @Test
    func windowCountKeepingFirstRow_keepsTheFirstRowAtTheStoreCap() {
        let capped = timeline(0..<20)
        let mark = Policy.TimelineMark(contextKey: "mesh", messages: capped, windowCount: 10)
        // Two appends, two head evictions: same count, first row two places up.
        let afterTwoAppends = timeline(2..<22)

        let grown = Policy.windowCountKeepingFirstRow(current: 10, mark: mark, appendedCount: 2, in: afterTwoAppends)

        #expect(grown == 12)
        #expect(afterTwoAppends.suffix(grown).first?.id == "m10")
    }

    @Test
    func windowCountKeepingFirstRow_growsByTheAppendedCountWithoutAUsableMark() {
        let messages = timeline(0..<30)

        // No mark (fresh context): grow by what was appended.
        #expect(Policy.windowCountKeepingFirstRow(current: 10, mark: nil, appendedCount: 3, in: messages) == 13)

        // A mark taken at another window size (the window was expanded since).
        let stale = Policy.TimelineMark(contextKey: "mesh", messages: timeline(0..<27), windowCount: 8)
        #expect(Policy.windowCountKeepingFirstRow(current: 10, mark: stale, appendedCount: 3, in: messages) == 13)

        // The first row itself is gone (removed or evicted).
        let mark = Policy.TimelineMark(contextKey: "mesh", messages: timeline(0..<27), windowCount: 10)
        let withoutFirstRow = messages.filter { $0.id != "m17" }
        #expect(Policy.windowCountKeepingFirstRow(current: 10, mark: mark, appendedCount: 3, in: withoutFirstRow) == 13)

        // Nothing appended and nothing to hold: the window stays.
        #expect(Policy.windowCountKeepingFirstRow(current: 10, mark: nil, appendedCount: 0, in: messages) == 10)
    }

    @Test
    func windowCountKeepingFirstRow_neverShrinksNorOutgrowsTheTimeline() {
        // A timeline shorter than the window keeps the window size.
        let short = timeline(0..<5)
        let shortMark = Policy.TimelineMark(contextKey: "mesh", messages: short, windowCount: 300)
        #expect(Policy.windowCountKeepingFirstRow(current: 300, mark: shortMark, appendedCount: 2, in: short + timeline(5..<7)) == 300)

        // Growth stops at the timeline's length.
        let messages = timeline(0..<12)
        #expect(Policy.windowCountKeepingFirstRow(current: 10, mark: nil, appendedCount: 50, in: messages) == 12)

        // Removals below the first row never shrink the window.
        let mark = Policy.TimelineMark(contextKey: "mesh", messages: messages, windowCount: 10)
        let removedBelow = messages.filter { $0.id != "m9" && $0.id != "m10" }
        #expect(Policy.windowCountKeepingFirstRow(current: 10, mark: mark, appendedCount: 0, in: removedBelow) == 10)
    }

    // MARK: - Gates

    @Test
    func canExpandWindow_waitsForTheRestoreAndForTheBottomOfThisContext() {
        #expect(Policy.canExpandWindow(isRestoringExpansion: false, bottomSettledContextKey: "mesh", contextKey: "mesh"))
        // A previous expansion's position restore is still queued.
        #expect(!Policy.canExpandWindow(isRestoringExpansion: true, bottomSettledContextKey: "mesh", contextKey: "mesh"))
        // The initial scroll to the bottom has not landed yet.
        #expect(!Policy.canExpandWindow(isRestoringExpansion: false, bottomSettledContextKey: nil, contextKey: "mesh"))
        // It landed in another conversation.
        #expect(!Policy.canExpandWindow(isRestoringExpansion: false, bottomSettledContextKey: "geo:u4pruy", contextKey: "mesh"))
    }

    @Test
    func bottomSettledKey_survivesASwitchOnlyForTheNewContext() {
        // The new context's newest row already appeared before the switch
        // handler ran: keep it.
        #expect(Policy.bottomSettledKey("dm:peer-b", afterSwitchingTo: "dm:peer-b") == "dm:peer-b")
        // Left over from the previous conversation: drop it.
        #expect(Policy.bottomSettledKey("dm:peer-a", afterSwitchingTo: "dm:peer-b") == nil)
        #expect(Policy.bottomSettledKey(nil, afterSwitchingTo: "mesh") == nil)
    }

    @Test
    func shouldRunDeferredFollowScroll_requiresTheBottomOfTheSameTimeline() {
        #expect(Policy.shouldRunDeferredFollowScroll(isAtBottom: true, scheduledContextKey: "mesh", currentContextKey: "mesh"))
        // The reader dragged away while the timer was held back.
        #expect(!Policy.shouldRunDeferredFollowScroll(isAtBottom: false, scheduledContextKey: "mesh", currentContextKey: "mesh"))
        // The timeline was switched before the timer fired.
        #expect(!Policy.shouldRunDeferredFollowScroll(isAtBottom: true, scheduledContextKey: "mesh", currentContextKey: "geo:u4pruy"))
    }
}
