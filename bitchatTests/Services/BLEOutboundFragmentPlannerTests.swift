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
