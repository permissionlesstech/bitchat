import XCTest
@testable import bitchat

final class GeohashBookmarksStoreTests: XCTestCase {
    let storeKey = "locationChannel.bookmarks"
    var storage: UserDefaults!
    var store: GeohashBookmarksStore!

    private let storage: KeyStorable = UserDefaultsKeyStorable()
    
    override func setUp() {
        super.setUp()
        // Clear persisted state before each test
        storage.remove(storeKey)
        GeohashBookmarksStore.shared._resetForTesting()
    }

    override func tearDown() {
        // Clean after each test
        storage.remove(storeKey)
        GeohashBookmarksStore.shared._resetForTesting()
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
        guard let data = storage.data(storeKey) else {
            XCTFail("No persisted data found")
            return
        }
        let arr = try JSONDecoder().decode([String].self, from: data)
        XCTAssertTrue(arr.contains("ezs42"))
        XCTAssertTrue(arr.contains("u4pruy"))
    }
}
