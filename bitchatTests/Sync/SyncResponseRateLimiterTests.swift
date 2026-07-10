import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct SyncResponseRateLimiterTests {

    private let peer = PeerID(str: "1122334455667788")
    private let otherPeer = PeerID(str: "8899aabbccddeeff")

    @Test func allowsResponsesUpToBudgetThenBlocks() {
        var limiter = SyncResponseRateLimiter(maxResponses: 2, window: 30)
        let now = Date()

        let first = limiter.shouldRespond(to: peer, now: now)
        let second = limiter.shouldRespond(to: peer, now: now.addingTimeInterval(1))
        let third = limiter.shouldRespond(to: peer, now: now.addingTimeInterval(2))

        #expect(first)
        #expect(second)
        #expect(!third)
    }

    @Test func budgetIsPerPeer() {
        var limiter = SyncResponseRateLimiter(maxResponses: 1, window: 30)
        let now = Date()

        let first = limiter.shouldRespond(to: peer, now: now)
        let repeated = limiter.shouldRespond(to: peer, now: now)
        let other = limiter.shouldRespond(to: otherPeer, now: now)

        #expect(first)
        #expect(!repeated)
        #expect(other)
    }

    @Test func allowsAgainAfterWindowSlides() {
        var limiter = SyncResponseRateLimiter(maxResponses: 1, window: 30)
        let now = Date()

        let first = limiter.shouldRespond(to: peer, now: now)
        let insideWindow = limiter.shouldRespond(to: peer, now: now.addingTimeInterval(29))
        let afterWindow = limiter.shouldRespond(to: peer, now: now.addingTimeInterval(31))

        #expect(first)
        #expect(!insideWindow)
        #expect(afterWindow)
    }

    @Test func pruneDropsExpiredHistory() {
        var limiter = SyncResponseRateLimiter(maxResponses: 1, window: 30)
        let now = Date()

        let first = limiter.shouldRespond(to: peer, now: now)
        limiter.prune(now: now.addingTimeInterval(31))
        let afterPrune = limiter.shouldRespond(to: peer, now: now.addingTimeInterval(32))

        #expect(first)
        #expect(afterPrune)
    }
}
