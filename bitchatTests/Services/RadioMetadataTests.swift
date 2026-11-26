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

    // MARK: - Voice burst TTL

    /// Per-frame drawing would be worse than useless: at ~15 frames a second an
    /// observer collects the range maximum almost immediately, so the sender is
    /// marked within a fraction of a second while every low draw still costs
    /// reach. One draw per burst makes a burst a single sample.
    @Test func voiceFramesInOneBurstShareOneTTL() {
        let start = Date(timeIntervalSince1970: 1_784_000_000)
        let first = BLEOriginTTLPolicy.voiceBurstTTL(
            now: start, lastFrameAt: nil, currentBurstTTL: nil, randomTTL: { _ in 6 }
        )
        // Subsequent frames inside the burst must reuse it even though the
        // randomizer would now return something else.
        var last = start
        var current = first
        for step in 1...20 {
            let now = start.addingTimeInterval(Double(step) * 0.066)
            current = BLEOriginTTLPolicy.voiceBurstTTL(
                now: now, lastFrameAt: last, currentBurstTTL: current, randomTTL: { _ in 7 }
            )
            last = now
            #expect(current == first)
        }
    }

    @Test func aNewBurstRedrawsTheTTL() {
        let start = Date(timeIntervalSince1970: 1_784_000_000)
        let first = BLEOriginTTLPolicy.voiceBurstTTL(
            now: start, lastFrameAt: nil, currentBurstTTL: nil, randomTTL: { _ in 5 }
        )
        #expect(first == 5)

        // A gap longer than the burst window means a new talk burst.
        let later = start.addingTimeInterval(BLEOriginTTLPolicy.voiceBurstGap + 0.5)
        let second = BLEOriginTTLPolicy.voiceBurstTTL(
            now: later, lastFrameAt: start, currentBurstTTL: first, randomTTL: { _ in 7 }
        )
        #expect(second == 7)
    }

    @Test func voiceBurstTTLStaysInRange() {
        var last: Date?
        var current: UInt8?
        let start = Date(timeIntervalSince1970: 1_784_000_000)
        for step in 0..<200 {
            // Gaps long enough to force a fresh draw each time.
            let now = start.addingTimeInterval(Double(step) * 5)
            let ttl = BLEOriginTTLPolicy.voiceBurstTTL(
                now: now, lastFrameAt: last, currentBurstTTL: current
            )
            #expect(TransportConfig.broadcastOriginTTLRange.contains(ttl))
            last = now
            current = ttl
        }
    }

    // MARK: - Wiring

    /// The first version of this change defined the policy and used it in
    /// exactly one place, leaving voice, files, group messages and board posts
    /// originating at a fixed maximum — i.e. still perfectly marked, while the
    /// docs claimed otherwise. A policy that exists but is not wired is worse
    /// than none, because it reads as solved.
    ///
    /// This asserts against the source rather than behaviour because the send
    /// paths need a live radio; it is a cheap guard against the specific
    /// regression of adding a broadcast origination site and forgetting it.
    @Test func everyAuthoredBroadcastOriginatesWithADrawnTTL() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // bitchatTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("bitchat/Services/BLE/BLEService.swift")
        let lines = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: .newlines)

        // Packet constructions that still pin the fixed maximum.
        let fixed = lines.enumerated().filter {
            $0.element.contains("ttl: messageTTL") || $0.element.contains("ttl: self.messageTTL")
        }

        // Each remaining one must be a deliberate exclusion. Announces keep the
        // fixed TTL for link binding; the rest are directed, diagnostics, or
        // re-broadcasts. Identify by the packet type named just above.
        let allowedTypes = [
            "announce",        // link binding depends on ttl == max
            "ping", "pong",    // diagnostics; payload records origin TTL for hops
            "noiseEncrypted", "noiseHandshake", "courierEnvelope",  // directed
            "fileTransfer",    // the directed variant; the broadcast one is drawn
            "prekeyBundle",    // payload already names its owner
            "nostrCarrier"     // re-broadcast, not authorship
        ]

        var unexplained: [String] = []
        for (index, line) in fixed {
            let window = lines[max(0, index - 14)...index].joined(separator: "\n")
            guard !allowedTypes.contains(where: { window.contains("MessageType.\($0)") }) else { continue }
            unexplained.append("BLEService.swift:\(index + 1) — \(line.trimmingCharacters(in: .whitespaces))")
        }

        #expect(
            unexplained.isEmpty,
            """
            These broadcast origination sites still use the fixed maximum TTL, \
            which marks this device as the author to any direct listener. Use \
            BLEOriginTTLPolicy.originTTL(), or add the type to allowedTypes here \
            with the reason.

            \(unexplained.joined(separator: "\n"))
            """
        )
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
