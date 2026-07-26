import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Two radio-layer metadata leaks that need no cross-platform agreement to
/// close: the neighbour list in announces, and the fixed origin TTL.
struct RadioMetadataTests {

    // MARK: - Origin TTL

    @Test func originTTLStaysInsideTheConfiguredRange() {
        let range = TransportConfig.broadcastOriginTTLRange
        for _ in 0..<200 {
            let ttl = BLEOriginTTLPolicy.originTTL()
            #expect(range.contains(ttl))
        }
    }

    /// The point of the change: a message must not always leave at the maximum,
    /// because a direct listener reads `ttl == max` as "this device wrote it".
    @Test func originTTLDoesNotAlwaysUseTheMaximum() {
        var seen = Set<UInt8>()
        for _ in 0..<500 {
            seen.insert(BLEOriginTTLPolicy.originTTL())
        }
        #expect(seen.count > 1)
        #expect(seen.contains { $0 < TransportConfig.messageTTLDefault })
    }

    @Test func originTTLUsesTheInjectedRandomizer() {
        let ttl = BLEOriginTTLPolicy.originTTL(range: 5...7, randomTTL: { _ in 6 })
        #expect(ttl == 6)
    }

    /// A send path must never trap on a bad range.
    @Test func degenerateRangesFallBackToTheDefault() {
        #expect(BLEOriginTTLPolicy.originTTL(range: 0...0) == TransportConfig.messageTTLDefault)
        // Single-value range is legitimate and must be honoured.
        #expect(BLEOriginTTLPolicy.originTTL(range: 4...4) == 4)
    }

    /// The floor must not drop below the dense-graph relay clamp: going lower
    /// costs reach without buying ambiguity the clamp does not already provide.
    @Test func rangeSitsBetweenTheDenseClampAndTheDefault() {
        let range = TransportConfig.broadcastOriginTTLRange
        #expect(range.upperBound == TransportConfig.messageTTLDefault)
        #expect(range.lowerBound >= TransportConfig.bleFragmentRelayTtlCapDense)
        #expect(range.lowerBound >= 2, "TTL 1 is dropped by RelayController")
    }

    // MARK: - Neighbour list

    @Test func neighborAdvertisingIsOffByDefault() {
        #expect(!TransportConfig.announceIncludesDirectNeighbors)
    }

    /// The mechanism that makes this backward compatible: an empty list omits
    /// the TLV entirely rather than emitting a zero-length one, and the decoder
    /// treats its absence as "no topology offered".
    @Test func emptyNeighborListOmitsTheTLV() throws {
        let announcement = AnnouncementPacket(
            nickname: "alice",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            directNeighbors: [],
            capabilities: [.bridge]
        )
        let encoded = try #require(announcement.encode())

        // TLV type 0x04 is the neighbour list; it must not appear at all.
        var offset = encoded.startIndex
        var types: [UInt8] = []
        while offset < encoded.endIndex {
            guard encoded.distance(from: offset, to: encoded.endIndex) >= 2 else { break }
            let type = encoded[offset]
            let length = Int(encoded[encoded.index(after: offset)])
            types.append(type)
            offset = encoded.index(offset, offsetBy: 2 + length)
        }
        #expect(!types.contains(0x04))

        let decoded = try #require(AnnouncementPacket.decode(from: encoded))
        #expect(decoded.directNeighbors == nil)
        // Everything else still round-trips, so old peers lose nothing but the
        // topology hint.
        #expect(decoded.nickname == "alice")
        #expect(decoded.capabilities == [.bridge])
    }

    /// Receiving a neighbour list must keep working: peers on older builds still
    /// send one, and a mixed mesh has to behave sensibly.
    @Test func receivedNeighborListsAreStillParsed() throws {
        let neighbors = [Data(repeating: 0xA1, count: 8), Data(repeating: 0xB2, count: 8)]
        let announcement = AnnouncementPacket(
            nickname: "bob",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            directNeighbors: neighbors
        )
        let encoded = try #require(announcement.encode())
        let decoded = try #require(AnnouncementPacket.decode(from: encoded))
        #expect(decoded.directNeighbors == neighbors)
    }
}
