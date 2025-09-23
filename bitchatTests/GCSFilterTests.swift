import XCTest
@testable import bitchat

final class GCSFilterTests: XCTestCase {
    func testBuildFilterWithDuplicateIdsProducesStableEncoding() {
        let id = Data(repeating: 0xAB, count: 16)
        let ids = Array(repeating: id, count: 64)

        let params = GCSFilter.buildFilter(ids: ids, maxBytes: 128, targetFpr: 0.01)
        XCTAssertGreaterThanOrEqual(params.m, 1)

        let decoded = GCSFilter.decodeToSortedSet(p: params.p, m: params.m, data: params.data)
        XCTAssertLessThanOrEqual(decoded.count, 1)
    }

    func testBucketAvoidsZeroCandidate() {
        let id = Data(repeating: 0x01, count: 16)
        let bucket = GCSFilter.bucket(for: id, modulus: 2)
        XCTAssertNotEqual(bucket, 0)
        XCTAssertLessThan(bucket, 2)
    }
}
