import Testing
import struct Foundation.Data
@testable import bitchat

struct GCSFilterTests {
    @Test func buildFilterWithDuplicateIdsProducesStableEncoding() {
        let id = Data(repeating: 0xAB, count: 16)
        let ids = Array(repeating: id, count: 64)

        let params = GCSFilter.buildFilter(ids: ids, maxBytes: 128, targetFpr: 0.01)
        #expect(params.m >= 1)

        let decoded = GCSFilter.decodeToSortedSet(p: params.p, m: params.m, data: params.data)
        #expect(decoded.count <= 1)
    }

    @Test func bucketAvoidsZeroCandidate() {
        let id = Data(repeating: 0x01, count: 16)
        let bucket = GCSFilter.bucket(for: id, modulus: 2)
        #expect(bucket != 0)
        #expect(bucket < 2)
    }
}
