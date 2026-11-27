import Testing
import Foundation
@testable import bitchat

struct GeohashBookmarksStoreTests {
    private let storeKey = "locationChannel.bookmarks"
    private let storage = UserDefaults(suiteName: UUID().uuidString)!
    private let store: GeohashBookmarksStore

    init() {
        store = GeohashBookmarksStore(storage: storage)
    }

    @Test func toggleAndNormalize() {
        // Start clean
        #expect(store.bookmarks.isEmpty)

        // Add with mixed case and hash prefix
        store.toggleBookmark("#U4PRUY")
        #expect(store.isBookmarked("u4pruy"))
        #expect(store.bookmarks.first == "u4pruy")

        // Toggling again removes
        store.toggleBookmark("u4pruy")
        #expect(!store.isBookmarked("u4pruy"))
        #expect(store.bookmarks.isEmpty)
    }

    @Test func persistenceWritten() throws {
        store.toggleBookmark("ezs42")
        store.toggleBookmark("u4pruy")
        // Verify persisted JSON contains both (order not enforced here)
        let data = try #require(storage.data(forKey: storeKey), "No persisted data found")
        let arr = try JSONDecoder().decode([String].self, from: data)
        #expect(arr.contains("ezs42"))
        #expect(arr.contains("u4pruy"))
    }
}
