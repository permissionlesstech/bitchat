import Foundation
import Testing
@testable import bitchat

/// The deduplicator promises a bounded working set: at most `maxCount` live
/// IDs, evicting oldest-first. Both entry points have to honour that, since a
/// node that mostly sends (self-broadcasts, announce-backs) adds IDs through
/// `markProcessed` and may never call `isDuplicate` at all.
struct MessageDeduplicatorTests {
    private static let maxCount = 1_000
    private static let load = 10 * maxCount

    @Test
    func markProcessedStaysUnderTheCap() {
        let dedup = MessageDeduplicator(maxAge: 300, maxCount: Self.maxCount)
        for i in 0..<Self.load {
            dedup.markProcessed("marked-\(i)")
        }

        // The most recent ID is still known, the oldest have been evicted.
        #expect(dedup.contains("marked-\(Self.load - 1)"))
        #expect(!dedup.contains("marked-0"))
    }

    @Test
    func isDuplicateStaysUnderTheCap() {
        let dedup = MessageDeduplicator(maxAge: 300, maxCount: Self.maxCount)
        for i in 0..<Self.load {
            #expect(!dedup.isDuplicate("checked-\(i)"))
        }

        #expect(dedup.isDuplicate("checked-\(Self.load - 1)"))
        #expect(!dedup.isDuplicate("checked-0"))
    }

    @Test
    func markProcessedKeepsTheMostRecentIDsAfterEviction() {
        let dedup = MessageDeduplicator(maxAge: 300, maxCount: Self.maxCount)
        for i in 0..<Self.load {
            dedup.markProcessed("marked-\(i)")
        }

        // Eviction trims to 75% of the cap, so the last 750 IDs must survive.
        let keptWindow = (Self.load - (Self.maxCount * 3) / 4)..<Self.load
        for i in keptWindow {
            #expect(dedup.contains("marked-\(i)"), "evicted a recent ID: marked-\(i)")
        }
    }

    @Test
    func markProcessedDoesNotResurrectAnEvictedID() {
        let dedup = MessageDeduplicator(maxAge: 300, maxCount: Self.maxCount)
        for i in 0..<Self.load {
            dedup.markProcessed("marked-\(i)")
        }

        // An evicted ID is unknown again, so a late relay of it is not filtered.
        #expect(!dedup.isDuplicate("marked-0"))
    }
}
