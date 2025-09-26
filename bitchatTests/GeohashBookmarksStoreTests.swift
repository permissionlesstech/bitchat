import XCTest
@testable import bitchat

final class GeohashBookmarksStoreTests: XCTestCase {
    let storeKey = "locationChannel.bookmarks"

    private var storage: UserDefaultsStorageMock!
    private var sut: GeohashBookmarksStore!
    
    override func setUp() {
        super.setUp()
        storage = UserDefaultsStorageMock()
        sut = GeohashBookmarksStore(
            storage: storage
        )
    }
    
    override func tearDown() {
        super.tearDown()
        storage = nil
        sut = nil
    }

    func testToggleAndNormalize() {
        // Start clean
        XCTAssertTrue(sut.bookmarks.isEmpty)

        // Add with mixed case and hash prefix
        sut.toggle("#U4PRUY")
        XCTAssertTrue(sut.isBookmarked("u4pruy"))
        XCTAssertEqual(sut.bookmarks.first, "u4pruy")

        // Toggling again removes
        sut.toggle("u4pruy")
        XCTAssertFalse(sut.isBookmarked("u4pruy"))
        XCTAssertTrue(sut.bookmarks.isEmpty)
    }
    
    func testPersistenceWritten() throws {
        sut.toggle("ezs42")
        sut.toggle("u4pruy")
        
        // Verify persisted JSON contains both (order not enforced here)
        guard let data: Data = storage.get(storeKey) else {
            XCTFail("No persisted data found")
            return
        }
        let arr = try JSONDecoder().decode([String].self, from: data)
        XCTAssertTrue(arr.contains("ezs42"))
        XCTAssertTrue(arr.contains("u4pruy"))
    }
}
