import Foundation
import Testing
@testable import bitchat

struct BoundedCacheTests {
    @Test func repeatedSingleKeyRefreshesKeepHistoryBounded() {
        var cache = BoundedCache<String, Int>(capacity: 64)
        for index in 0..<10_000 {
            cache.set("hot", value: index)
        }
        #expect(cache.count == 1)
        #expect(cache.value(for: "hot") == 9_999)
        #expect(cache.historyCountForTesting <= 128)
    }

    @Test func repeatedHotKeyRefreshWithColdFrontEntryCompactsHistory() {
        var cache = BoundedCache<String, Int>(capacity: 64)
        cache.set("cold", value: 0)
        for index in 1...10_000 {
            cache.set("hot", value: index)
        }
        #expect(cache.count == 2)
        #expect(cache.value(for: "cold") == 0)
        #expect(cache.value(for: "hot") == 10_000)
        #expect(cache.historyCountForTesting <= 128)
    }
}
