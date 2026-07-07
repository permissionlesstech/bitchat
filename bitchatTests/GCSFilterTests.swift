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

    @Test func decodeRejectsOutOfRangeParameters() {
        let junk = Data(repeating: 0xFF, count: 64)
        #expect(GCSFilter.decodeToSortedSet(p: 0, m: 1000, data: junk).isEmpty)
        #expect(GCSFilter.decodeToSortedSet(p: -1, m: 1000, data: junk).isEmpty)
        #expect(GCSFilter.decodeToSortedSet(p: GCSFilter.maxP + 1, m: 1000, data: junk).isEmpty)
        #expect(GCSFilter.decodeToSortedSet(p: 255, m: UInt32.max, data: junk).isEmpty)
        #expect(GCSFilter.decodeToSortedSet(p: 8, m: 0, data: junk).isEmpty)
        #expect(GCSFilter.decodeToSortedSet(p: 8, m: 1, data: junk).isEmpty)
    }

    @Test func decodeOfTruncatedDataReturnsOnlyCompleteValues() {
        let ids = (0..<32).map { i in Data(repeating: UInt8(i), count: 16) }
        let params = GCSFilter.buildFilter(ids: ids, maxBytes: 128, targetFpr: 0.01)
        let full = GCSFilter.decodeToSortedSet(p: params.p, m: params.m, data: params.data)
        let truncated = GCSFilter.decodeToSortedSet(p: params.p, m: params.m, data: params.data.prefix(params.data.count / 2))
        #expect(truncated.count <= full.count)
        // Truncation must not invent values that were not in the full set.
        #expect(truncated.allSatisfy { full.contains($0) })
    }

    @Test func buildFilterReportsFullCoverageWhenBudgetFits() {
        let ids = (0..<8).map { i in Data(repeating: UInt8(i), count: 16) }
        let params = GCSFilter.buildFilter(ids: ids, maxBytes: 1024, targetFpr: 0.01)
        #expect(params.includedCount == ids.count)
    }

    @Test func buildFilterTrimsTailWhenBudgetExceeded() {
        // A tight byte budget can't hold every ID, so the encoder trims from
        // the input tail and reports how many it actually covered.
        let ids = (0..<200).map { i in
            Data((0..<16).map { UInt8((i &* 31 &+ $0) & 0xFF) })
        }
        let params = GCSFilter.buildFilter(ids: ids, maxBytes: 32, targetFpr: 0.01)
        #expect(params.includedCount > 0)
        #expect(params.includedCount < ids.count)
        #expect(params.data.count <= 32)
    }

    @Test func requestSyncPacketDecodeRejectsOversizedP() {
        let valid = RequestSyncPacket(p: 8, m: 4096, data: Data([0x01, 0x02]))
        #expect(RequestSyncPacket.decode(from: valid.encode()) != nil)

        let oversized = RequestSyncPacket(p: 200, m: 4096, data: Data([0x01, 0x02]))
        #expect(RequestSyncPacket.decode(from: oversized.encode()) == nil)
    }
}
