import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("BLE outbound fragment planner tests")
struct BLEOutboundFragmentPlannerTests {
    @Test("planner splits packets and preserves reassembled payload")
    func plannerSplitsAndReassemblesPacket() throws {
        let packet = makePacket(payload: makePayload(count: 384))
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: false,
            maxChunk: 128,
            directedPeer: nil,
            transferId: nil
        )

        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xA1, count: 8)
        ))
        let headers = try plan.fragmentPackets.map { try #require(BLEFragmentHeader(packet: $0)) }
        let reassembled = headers.reduce(into: Data()) { data, header in
            data.append(header.fragmentData)
        }
        let decoded = try #require(BinaryProtocol.decode(reassembled))

        #expect(plan.fragmentVersion == 1)
        #expect(plan.chunkSize == 128)
        #expect(plan.spacingMs == TransportConfig.bleFragmentSpacingMs)
        #expect(headers.map(\.index) == Array(0..<headers.count))
        #expect(decoded.type == packet.type)
        #expect(decoded.payload == packet.payload)
        #expect(plan.fragmentPackets.allSatisfy { $0.recipientID == nil })
    }

    @Test("directed fragments target the directed peer and use directed pacing")
    func directedFragmentsUseDirectedRecipientAndSpacing() throws {
        let directedPeer = PeerID(str: "8877665544332211")
        let packet = makePacket(payload: makePayload(count: 256))
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: false,
            maxChunk: 96,
            directedPeer: directedPeer,
            transferId: nil
        )

        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xB2, count: 8)
        ))

        #expect(plan.spacingMs == TransportConfig.bleFragmentSpacingDirectedMs)
        #expect(plan.fragmentPackets.allSatisfy { $0.recipientID == Data(hexString: directedPeer.id) })
    }

    @Test("route-aware fragments use version two and route-sized chunking")
    func routeAwareFragmentsUseVersionTwoAndRouteSizedChunking() throws {
        let route = [
            Data([0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17]),
            Data([0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27])
        ]
        let packet = makePacket(payload: makePayload(count: 192), route: route, isRSR: true)
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: false,
            maxChunk: nil,
            directedPeer: nil,
            transferId: nil
        )

        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: 256,
            bleMaxMTU: 128,
            fragmentID: Data(repeating: 0xC3, count: 8)
        ))
        let firstHeader = try #require(BLEFragmentHeader(packet: plan.fragmentPackets[0]))

        #expect(plan.fragmentVersion == 2)
        #expect(plan.chunkSize == 64)
        #expect(firstHeader.fragmentData.count <= 64)
        #expect(plan.fragmentPackets.allSatisfy { $0.route == route && $0.isRSR })
    }

    @Test("source-routed directed re-fragmentation preserves final destination recipientID")
    func routedDirectedRefragmentationPreservesFinalRecipient() throws {
        let nextHop = PeerID(str: "1011121314151617")
        let finalDest = PeerID(str: "9091929394959697")
        let route = [
            Data([0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17]),
            Data([0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27])
        ]
        let routedPacket = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            recipientID: finalDest.routingData,
            timestamp: 1_000,
            payload: makePayload(count: 256),
            signature: nil,
            ttl: 5,
            version: 2,
            route: route
        )
        let request = BLEOutboundFragmentTransferRequest(
            packet: routedPacket,
            pad: false,
            maxChunk: 96,
            directedPeer: nextHop,
            transferId: nil
        )

        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xD4, count: 8)
        ))

        #expect(plan.fragmentPackets.count > 1)
        #expect(plan.fragmentPackets.allSatisfy { $0.recipientID == finalDest.routingData })
        #expect(plan.fragmentPackets.allSatisfy { $0.route == route })

        // A tight 110-byte link yields a 48-byte routed chunk budget; planner
        // must not clamp upward past 48 bytes and every encoded fragment must
        // fit within 110 bytes on the wire.
        let tightBudget = try #require(BLEOutboundPacketPolicy.fragmentChunkSize(for: routedPacket, linkLimit: 110))
        #expect(tightBudget == 48)
        let tightPlan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: BLEOutboundFragmentTransferRequest(
                packet: routedPacket,
                pad: false,
                maxChunk: tightBudget,
                directedPeer: nextHop,
                transferId: nil
            ),
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xD5, count: 8)
        ))
        #expect(tightPlan.chunkSize == 48)
        #expect(tightPlan.fragmentPackets.allSatisfy { ($0.toBinaryData(padding: false)?.count ?? Int.max) <= 110 })
    }

    @Test("routed fragment framing overhead matches encoded byte sizes and enforces 10,000-fragment ceiling")
    func fragmentPlannerAcceptsReceiverLimitAndRejectsLargerTrainsBeforeAllocation() throws {
        let finalDest = PeerID(str: "9091929394959697")
        let nextHop = PeerID(str: "1011121314151617")
        let hops = [
            Data([0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17]),
            Data([0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27]),
            Data([0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37])
        ]

        // Shared overhead formula must match exact encoded wire overhead for 1..3 hops.
        for hopCount in 1...3 {
            let route = Array(hops.prefix(hopCount))
            let packet = BitchatPacket(
                type: MessageType.message.rawValue,
                senderID: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
                recipientID: finalDest.routingData,
                timestamp: 1_000,
                payload: makePayload(count: 160),
                signature: nil,
                ttl: 5,
                version: 2,
                route: route
            )
            let overhead = BLEOutboundPacketPolicy.routedFragmentFrameOverhead(routeHopCount: hopCount)
            let linkLimit = overhead + 24
            let budget = try #require(BLEOutboundPacketPolicy.fragmentChunkSize(for: packet, linkLimit: linkLimit))
            #expect(budget == 24)
            let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
                for: BLEOutboundFragmentTransferRequest(
                    packet: packet,
                    pad: false,
                    maxChunk: budget,
                    directedPeer: nextHop,
                    transferId: nil
                ),
                defaultChunkSize: 256,
                bleMaxMTU: 512,
                fragmentID: Data(repeating: 0xE1, count: 8)
            ))
            let firstEncoded = try #require(plan.fragmentPackets[0].toBinaryData(padding: false))
            #expect(firstEncoded.count == linkLimit)
        }

        // Regression for R5-BUG-01: enforce the 10,000-fragment receiver ceiling
        // before fragment allocation so tiny routed chunks never crash UInt16(total).
        let route = Array(hops.prefix(2))
        let basePacket = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            recipientID: finalDest.routingData,
            timestamp: 1_000,
            payload: Data(),
            signature: nil,
            ttl: 5,
            version: 2,
            route: route
        )
        let emptyEncodedLen = try #require(basePacket.toBinaryData(padding: false)).count
        let atLimitPayload = makePayload(count: BLEOutboundFragmentPlanner.maxSupportedFragments - emptyEncodedLen)
        let atLimitPacket = BitchatPacket(
            type: basePacket.type,
            senderID: basePacket.senderID,
            recipientID: basePacket.recipientID,
            timestamp: basePacket.timestamp,
            payload: atLimitPayload,
            signature: nil,
            ttl: basePacket.ttl,
            version: 2,
            route: route
        )
        let atLimitPlan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: BLEOutboundFragmentTransferRequest(
                packet: atLimitPacket,
                pad: false,
                maxChunk: 1,
                directedPeer: nextHop,
                transferId: nil
            ),
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xE2, count: 8)
        ))
        #expect(atLimitPlan.totalFragments == BLEOutboundFragmentPlanner.maxSupportedFragments)

        let overLimitPacket = BitchatPacket(
            type: basePacket.type,
            senderID: basePacket.senderID,
            recipientID: basePacket.recipientID,
            timestamp: basePacket.timestamp,
            payload: makePayload(count: BLEOutboundFragmentPlanner.maxSupportedFragments - emptyEncodedLen + 1),
            signature: nil,
            ttl: basePacket.ttl,
            version: 2,
            route: route
        )
        #expect(BLEOutboundFragmentPlanner.makePlan(
            for: BLEOutboundFragmentTransferRequest(
                packet: overLimitPacket,
                pad: false,
                maxChunk: 1,
                directedPeer: nextHop,
                transferId: nil
            ),
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xE3, count: 8)
        ) == nil)

        // Even > UInt16.max fragments must return nil cleanly without trapping.
        let hugePacket = BitchatPacket(
            type: basePacket.type,
            senderID: basePacket.senderID,
            recipientID: basePacket.recipientID,
            timestamp: basePacket.timestamp,
            payload: makePayload(count: 70_000),
            signature: nil,
            ttl: basePacket.ttl,
            version: 2,
            route: route
        )
        #expect(BLEOutboundFragmentPlanner.makePlan(
            for: BLEOutboundFragmentTransferRequest(
                packet: hugePacket,
                pad: false,
                maxChunk: 1,
                directedPeer: nextHop,
                transferId: nil
            ),
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xE4, count: 8)
        ) == nil)
    }

    @Test("invalid fragment IDs do not produce a plan")
    func invalidFragmentIDReturnsNil() {
        let packet = makePacket(payload: makePayload(count: 128))
        let request = BLEOutboundFragmentTransferRequest(
            packet: packet,
            pad: false,
            maxChunk: nil,
            directedPeer: nil,
            transferId: nil
        )

        #expect(BLEOutboundFragmentPlanner.makePlan(
            for: request,
            defaultChunkSize: 256,
            bleMaxMTU: 512,
            fragmentID: Data(repeating: 0x00, count: 7)
        ) == nil)
    }

    @Test("private media v1 accepts exactly 256 fragments and rejects 257")
    func privateMediaCrossPlatformFragmentBoundary() throws {
        let maxPayload = makePayload(count: 160 * 1024, seed: 0xFACE_CAFE)

        func plan(payloadCount: Int) throws -> BLEOutboundFragmentPlan {
            let packet = BitchatPacket(
                type: MessageType.noiseEncrypted.rawValue,
                senderID: Data(hexString: "0011223344556677") ?? Data(),
                recipientID: Data(hexString: "8877665544332211"),
                timestamp: 0x0102030405,
                payload: Data(maxPayload.prefix(payloadCount)),
                signature: nil,
                ttl: 3,
                version: 2
            )
            return try #require(BLEOutboundFragmentPlanner.makePlan(
                for: BLEOutboundFragmentTransferRequest(
                    packet: packet,
                    pad: false,
                    maxChunk: nil,
                    directedPeer: PeerID(str: "8877665544332211"),
                    transferId: "boundary"
                ),
                defaultChunkSize: TransportConfig.bleDefaultFragmentSize,
                bleMaxMTU: 512,
                fragmentID: Data(repeating: 0xD4, count: 8)
            ))
        }

        func firstPlan(withAtLeast target: Int) throws -> BLEOutboundFragmentPlan {
            var low = 1
            var high = maxPayload.count
            while low < high {
                let mid = low + (high - low) / 2
                if try plan(payloadCount: mid).totalFragments >= target {
                    high = mid
                } else {
                    low = mid + 1
                }
            }
            return try plan(payloadCount: low)
        }

        let at256 = try firstPlan(withAtLeast: 256)
        let at257 = try firstPlan(withAtLeast: 257)

        #expect(at256.totalFragments == 256)
        #expect(BLEOutboundFragmentPlanner.isPrivateMediaV1Compatible(at256))
        #expect(at257.totalFragments == 257)
        #expect(!BLEOutboundFragmentPlanner.isPrivateMediaV1Compatible(at257))
    }

    private func makePacket(
        payload: Data,
        route: [Data]? = nil,
        isRSR: Bool = false
    ) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
            recipientID: nil,
            timestamp: 0x0102030405,
            payload: payload,
            signature: nil,
            ttl: 3,
            route: route,
            isRSR: isRSR
        )
    }

    private func makePayload(count: Int, seed: UInt64 = 0xABCD_1234) -> Data {
        var state = seed
        return Data((0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 32)
        })
    }
}
