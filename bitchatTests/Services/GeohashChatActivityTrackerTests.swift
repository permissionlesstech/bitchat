//
// GeohashChatActivityTrackerTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import bitchat

@MainActor
struct GeohashChatActivityTrackerTests {

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTracker(window: TimeInterval = 900, now: Date? = nil) -> (GeohashChatActivityTracker, (Date) -> Void) {
        var currentNow = now ?? baseDate
        let tracker = GeohashChatActivityTracker(window: window, now: { currentNow })
        return (tracker, { currentNow = $0 })
    }

    private func channel(_ geohash: String, _ level: GeohashChannelLevel) -> GeohashChannel {
        GeohashChannel(level: level, geohash: geohash)
    }

    @Test
    func recordsAndCountsMessagesInWindow() {
        let (tracker, _) = makeTracker()
        tracker.recordChatMessage(geohash: "9Q8YY", senderName: "alice#ab12", content: "hi", timestamp: baseDate)
        tracker.recordChatMessage(geohash: "9q8yy", senderName: "bob#cd34", content: "yo", timestamp: baseDate)

        #expect(tracker.messageCount(for: "9q8yy") == 2)
        #expect(tracker.lastMessage(for: "9q8YY")?.senderName == "bob#cd34")
    }

    @Test
    func dropsMessagesOlderThanWindow() {
        let (tracker, advance) = makeTracker(window: 900)
        tracker.recordChatMessage(geohash: "9q8yy", senderName: "alice#ab12", content: "hi", timestamp: baseDate)

        advance(baseDate.addingTimeInterval(901))

        #expect(tracker.messageCount(for: "9q8yy") == 0)
        #expect(tracker.lastMessage(for: "9q8yy") == nil)
    }

    @Test
    func ignoresMessagesAlreadyOutsideWindow() {
        let (tracker, _) = makeTracker(window: 900)
        tracker.recordChatMessage(
            geohash: "9q8yy",
            senderName: "alice#ab12",
            content: "old",
            timestamp: baseDate.addingTimeInterval(-1000)
        )

        #expect(tracker.messageCount(for: "9q8yy") == 0)
    }

    @Test
    func keepsNewestPreview() {
        let (tracker, _) = makeTracker()
        tracker.recordChatMessage(geohash: "9q8yy", senderName: "a#1111", content: "newer", timestamp: baseDate)
        tracker.recordChatMessage(geohash: "9q8yy", senderName: "b#2222", content: "older", timestamp: baseDate.addingTimeInterval(-60))

        #expect(tracker.lastMessage(for: "9q8yy")?.content == "newer")
        #expect(tracker.messageCount(for: "9q8yy") == 2)
    }

    @Test
    func mostActivePicksBusiestChannel() {
        let (tracker, _) = makeTracker()
        tracker.recordChatMessage(geohash: "9q8yy", senderName: "a#1111", content: "one", timestamp: baseDate)
        tracker.recordChatMessage(geohash: "9q8", senderName: "b#2222", content: "two", timestamp: baseDate)
        tracker.recordChatMessage(geohash: "9q8", senderName: "c#3333", content: "three", timestamp: baseDate)

        let channels = [channel("9q8yy", .city), channel("9q8", .province)]
        let best = tracker.mostActiveConversation(among: channels)

        #expect(best?.channel.geohash == "9q8")
        #expect(best?.messageCount == 2)
    }

    @Test
    func mostActiveTieGoesToMoreLocalChannel() {
        let (tracker, _) = makeTracker()
        tracker.recordChatMessage(geohash: "9q8yyzz1", senderName: "a#1111", content: "local", timestamp: baseDate)
        tracker.recordChatMessage(geohash: "9q", senderName: "b#2222", content: "regional", timestamp: baseDate)

        let channels = [channel("9q", .region), channel("9q8yyzz1", .building)]
        let best = tracker.mostActiveConversation(among: channels)

        #expect(best?.channel.geohash == "9q8yyzz1")
    }

    @Test
    func mostActiveIsNilWithoutMessages() {
        let (tracker, _) = makeTracker()
        #expect(tracker.mostActiveConversation(among: [channel("9q8yy", .city)]) == nil)
    }

    @Test
    func clearRemovesEverything() {
        let (tracker, _) = makeTracker()
        tracker.recordChatMessage(geohash: "9q8yy", senderName: "a#1111", content: "hi", timestamp: baseDate)
        tracker.clear()

        #expect(tracker.messageCount(for: "9q8yy") == 0)
        #expect(tracker.mostActiveConversation(among: [channel("9q8yy", .city)]) == nil)
    }
}
