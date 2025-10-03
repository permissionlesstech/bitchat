import XCTest
@testable import bitchat

final class GeohashBookmarksStoreTests: XCTestCase {
    let storeKey = "locationChannel.bookmarks"
    var storage: UserDefaults!
    var store: GeohashBookmarksStore!

    override func setUp() {
        super.setUp()
        // Unique instance for each test to avoid race condition
        storage = UserDefaults(suiteName: UUID().uuidString)
        store = GeohashBookmarksStore(storage: storage!)
    }

    override func tearDown() {
        storage.removeObject(forKey: storeKey)
        store._resetForTesting()
        store = nil
        storage = nil
        super.tearDown()
    }

    func testToggleAndNormalize() {
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
        store.toggle("ezs42")
        store.toggle("u4pruy")

        // Verify persisted JSON contains both (order not enforced here)
        guard let data = storage.data(forKey: storeKey) else {
            XCTFail("No persisted data found")
            return
        }
        let arr = try JSONDecoder().decode([String].self, from: data)
        XCTAssertTrue(arr.contains("ezs42"))
        XCTAssertTrue(arr.contains("u4pruy"))
    }
}
