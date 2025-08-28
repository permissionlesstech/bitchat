import XCTest
@testable import bitchat

final class GeohashBookmarksStoreTests: XCTestCase {
    let storeKey = "locationChannel.bookmarks"

    override func setUp() {
        super.setUp()
        // Clear persisted state before each test
        UserDefaults.standard.removeObject(forKey: storeKey)
        GeohashBookmarksStore.shared._resetForTesting()
    }

    override func tearDown() {
        // Clean after each test
        UserDefaults.standard.removeObject(forKey: storeKey)
        GeohashBookmarksStore.shared._resetForTesting()
        super.tearDown()
    }

    func testToggleAndNormalize() {
        let store = GeohashBookmarksStore.shared
        // Start clean
        XCTAssertTrue(store.bookmarks.isEmpty)

        // Add with mixed case and hash prefix
        store.toggle("#U4PRUY")
        XCTAssertTrue(store.isBookmarked("u4pruy"))
        XCTAssertEqual(store.bookmarks.first, "u4pruy")

        // Toggling again removes
        store.toggle("u4pruy")
        XCTAssertFalse(store.isBookmarked("u4pruy"))
        XCTAssertTrue(store.bookmarks.isEmpty)
    }

    func testPersistenceWritten() throws {
        let store = GeohashBookmarksStore.shared
        store.toggle("ezs42")
        store.toggle("u4pruy")

        // Verify persisted JSON contains both (order not enforced here)
        guard let data = UserDefaults.standard.data(forKey: storeKey) else {
            XCTFail("No persisted data found")
            return
        }
        let arr = try JSONDecoder().decode([String].self, from: data)
        XCTAssertTrue(arr.contains("ezs42"))
        XCTAssertTrue(arr.contains("u4pruy"))
    }
}
