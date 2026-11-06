//
// MessageBubbleGroupingTests.swift
// bitchatTests
//
// Which bubbles continue their author's run (and so drop the sender label):
// same sender by ID (falling back to the display name), same privacy, within
// the five-minute window, and never across a system line.
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

private func message(
    _ id: String,
    sender: String = "alice",
    peerID: PeerID? = PeerID(str: "00000000000000a1"),
    at seconds: TimeInterval = 0,
    isPrivate: Bool = false
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: sender,
        content: "message \(id)",
        timestamp: baseDate.addingTimeInterval(seconds),
        isRelay: false,
        isPrivate: isPrivate,
        senderPeerID: peerID
    )
}

struct MessageBubbleGroupingTests {
    @Test func firstMessageStartsARun() {
        #expect(!MessageBubbleGrouping.continuesRun(message("1"), after: nil))
    }

    @Test func sameSenderWithinTheWindowContinues() {
        let previous = message("1")
        #expect(MessageBubbleGrouping.continuesRun(message("2", at: 60), after: previous))
        #expect(MessageBubbleGrouping.continuesRun(message("3", at: MessageBubbleGrouping.window), after: previous))
    }

    @Test func aLongPauseStartsANewRun() {
        let previous = message("1")
        #expect(!MessageBubbleGrouping.continuesRun(message("2", at: MessageBubbleGrouping.window + 1), after: previous))
    }

    @Test func anOutOfOrderTimestampStartsANewRun() {
        let previous = message("1", at: 60)
        #expect(!MessageBubbleGrouping.continuesRun(message("2", at: 0), after: previous))
    }

    @Test func namesakesWithDifferentIDsAreDifferentSenders() {
        let previous = message("1", sender: "anon", peerID: PeerID(str: "00000000000000a1"))
        let current = message("2", sender: "anon", peerID: PeerID(str: "00000000000000b2"), at: 10)
        #expect(!MessageBubbleGrouping.continuesRun(current, after: previous))
    }

    @Test func sameIDContinuesAcrossARename() {
        let previous = message("1", sender: "alice")
        let current = message("2", sender: "alice2", at: 10)
        #expect(MessageBubbleGrouping.continuesRun(current, after: previous))
    }

    @Test func rowsWithoutIDsFallBackToTheDisplayName() {
        let previous = message("1", sender: "alice#a1b2", peerID: nil)
        #expect(MessageBubbleGrouping.continuesRun(message("2", sender: "alice#a1b2", peerID: nil, at: 10), after: previous))
        #expect(!MessageBubbleGrouping.continuesRun(message("3", sender: "alice#c3d4", peerID: nil, at: 10), after: previous))
    }

    @Test func systemLinesNeverJoinARun() {
        let system = message("s", sender: "system", peerID: nil)
        #expect(!MessageBubbleGrouping.continuesRun(message("1", at: 10), after: system))
        #expect(!MessageBubbleGrouping.continuesRun(message("s2", sender: "system", peerID: nil, at: 10), after: system))
    }

    @Test func thePrivateBoundaryStartsANewRun() {
        let previous = message("1")
        #expect(!MessageBubbleGrouping.continuesRun(message("2", at: 10, isPrivate: true), after: previous))
    }

    /// Spacing follows the author alone: a pause brings the name back but
    /// must not widen the gap, or a run of my own (nameless) bubbles gets
    /// gaps that change for no visible reason.
    @Test func aLongPauseKeepsTheSameAuthor() {
        let previous = message("1")
        let later = message("2", at: MessageBubbleGrouping.window * 10)
        #expect(MessageBubbleGrouping.hasSameAuthor(later, as: previous))
        #expect(!MessageBubbleGrouping.continuesRun(later, after: previous))
    }

    @Test func authorChangesWhereRunsAlwaysBreak() {
        let previous = message("1")
        #expect(!MessageBubbleGrouping.hasSameAuthor(message("2"), as: nil))
        #expect(!MessageBubbleGrouping.hasSameAuthor(message("3", peerID: PeerID(str: "00000000000000b2"), at: 10), as: previous))
        #expect(!MessageBubbleGrouping.hasSameAuthor(message("4", at: 10, isPrivate: true), as: previous))
        #expect(!MessageBubbleGrouping.hasSameAuthor(message("5", sender: "system", peerID: nil, at: 10), as: previous))
    }
}
