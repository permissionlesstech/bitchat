import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEOutboundLinkPlannerTests {
    @Test
    func recipientIDSuppliesDirectedHintAndUsesAllAvailableLinks() throws {
        let recipient = PeerID(str: "1122334455667788")
        let packet = makePacket(type: .noiseEncrypted, recipient: recipient)

        let plan = BLEOutboundLinkPlanner.plan(
            packet: packet,
            dataCount: 32,
            peripheralIDs: ["p1", "p2"],
            peripheralWriteLimits: [128, 128],
            centralIDs: ["c1"],
            centralNotifyLimits: [128],
            ingressRecord: nil,
            excludedLinks: [],
            directedOnlyPeer: nil
        )

        #expect(plan.directedPeerHint == recipient)
        #expect(plan.fragmentChunkSize == nil)
        #expect(plan.selectedLinks.peripheralIDs == Set(["p1", "p2"]))
        #expect(plan.selectedLinks.centralIDs == Set(["c1"]))
        #expect(!plan.shouldSpoolDirectedPacket)
    }

    @Test
    func oversizedNonFragmentPacketPlansFragmentationFromSmallestLinkLimit() {
        let packet = makePacket(type: .message)
        let smallestLimit = 96

        let plan = BLEOutboundLinkPlanner.plan(
            packet: packet,
            dataCount: 160,
            peripheralIDs: ["p1"],
            peripheralWriteLimits: [128],
            centralIDs: ["c1"],
            centralNotifyLimits: [smallestLimit],
            ingressRecord: nil,
            excludedLinks: [],
            directedOnlyPeer: nil
        )

        #expect(plan.fragmentChunkSize == BLEOutboundPacketPolicy.fragmentChunkSize(forLinkLimit: smallestLimit))
        #expect(plan.selectedLinks.peripheralIDs == Set(["p1"]))
        #expect(plan.selectedLinks.centralIDs == Set(["c1"]))
        #expect(!plan.shouldSpoolDirectedPacket)
    }

    @Test
    func oversizedDirectedCourierDoesNotUseUnrelatedPeersMTUAsHandoffSuccess() {
        let recipient = PeerID(str: "1122334455667788")
        let unrelated = PeerID(str: "8877665544332211")
        let packet = makePacket(type: .courierEnvelope, recipient: recipient)

        let plan = BLEOutboundLinkPlanner.plan(
            packet: packet,
            dataCount: 512,
            peripheralIDs: ["unrelated-link"],
            peripheralWriteLimits: [64],
            centralIDs: [],
            centralNotifyLimits: [],
            ingressRecord: nil,
            excludedLinks: [],
            peripheralPeerBindings: ["unrelated-link": unrelated],
            directedOnlyPeer: recipient,
            requireDirectPeerLink: true
        )

        #expect(plan.directedPeerHint == recipient)
        #expect(plan.fragmentChunkSize == nil)
        #expect(plan.selectedLinks.peripheralIDs.isEmpty)
        #expect(plan.selectedLinks.centralIDs.isEmpty)
        #expect(!plan.shouldSpoolDirectedPacket)
    }

    @Test
    func fragmentPacketsBypassFragmentationPlanning() {
        let packet = makePacket(type: .fragment)

        let plan = BLEOutboundLinkPlanner.plan(
            packet: packet,
            dataCount: 512,
            peripheralIDs: ["p1"],
            peripheralWriteLimits: [64],
            centralIDs: ["c1"],
            centralNotifyLimits: [64],
            ingressRecord: nil,
            excludedLinks: [],
            directedOnlyPeer: nil
        )

        #expect(plan.fragmentChunkSize == nil)
        #expect(plan.selectedLinks.peripheralIDs == Set(["p1"]))
        #expect(plan.selectedLinks.centralIDs == Set(["c1"]))
    }

    @Test
    func directedEncryptedPacketSpoolsWhenNoLinksAreAvailable() {
        let recipient = PeerID(str: "1122334455667788")
        let packet = makePacket(type: .noiseEncrypted, recipient: recipient)

        let plan = BLEOutboundLinkPlanner.plan(
            packet: packet,
            dataCount: 32,
            peripheralIDs: [],
            peripheralWriteLimits: [],
            centralIDs: [],
            centralNotifyLimits: [],
            ingressRecord: nil,
            excludedLinks: [],
            directedOnlyPeer: recipient
        )

        #expect(plan.directedPeerHint == recipient)
        #expect(plan.shouldSpoolDirectedPacket)
    }

    @Test
    func bridgeCourierPacketDoesNotTurnProcessLocalSpoolIntoHandoffSuccess() {
        let recipient = PeerID(str: "1122334455667788")
        let packet = makePacket(type: .courierEnvelope, recipient: recipient)

        let plan = BLEOutboundLinkPlanner.plan(
            packet: packet,
            dataCount: 32,
            peripheralIDs: [],
            peripheralWriteLimits: [],
            centralIDs: [],
            centralNotifyLimits: [],
            ingressRecord: nil,
            excludedLinks: [],
            directedOnlyPeer: recipient
        )

        #expect(plan.selectedLinks.peripheralIDs.isEmpty)
        #expect(plan.selectedLinks.centralIDs.isEmpty)
        #expect(!plan.shouldSpoolDirectedPacket)
    }

    @Test
    func publicBroadcastDoesNotSpoolWhenNoLinksAreAvailable() {
        let packet = makePacket(type: .message)

        let plan = BLEOutboundLinkPlanner.plan(
            packet: packet,
            dataCount: 32,
            peripheralIDs: [],
            peripheralWriteLimits: [],
            centralIDs: [],
            centralNotifyLimits: [],
            ingressRecord: nil,
            excludedLinks: [],
            directedOnlyPeer: nil
        )

        #expect(plan.directedPeerHint == nil)
        #expect(!plan.shouldSpoolDirectedPacket)
    }

    @Test
    func directAnnounceBypassesDuplicateLinkCollapseButRelayedAnnounceDoesNot() {
        let peer = PeerID(str: "1122334455667788")
        let bindings: [String: PeerID] = ["p1": peer, "p2": peer]

        let direct = BLEOutboundLinkPlanner.plan(
            packet: makePacket(type: .announce),
            dataCount: 32,
            peripheralIDs: ["p1", "p2"],
            peripheralWriteLimits: [128, 128],
            centralIDs: [],
            centralNotifyLimits: [],
            ingressRecord: nil,
            excludedLinks: [],
            peripheralPeerBindings: bindings,
            preferredPeripheralPerPeer: [peer: "p1"],
            directedOnlyPeer: nil
        )
        // A direct announce is the link-binding packet: it must reach every
        // live link, including a peer's duplicate connections.
        #expect(direct.selectedLinks.peripheralIDs == Set(["p1", "p2"]))

        let relayed = BLEOutboundLinkPlanner.plan(
            packet: makePacket(type: .announce, ttl: TransportConfig.messageTTLDefault - 1),
            dataCount: 32,
            peripheralIDs: ["p1", "p2"],
            peripheralWriteLimits: [128, 128],
            centralIDs: [],
            centralNotifyLimits: [],
            ingressRecord: nil,
            excludedLinks: [],
            peripheralPeerBindings: bindings,
            preferredPeripheralPerPeer: [peer: "p1"],
            directedOnlyPeer: nil
        )
        // Relayed announces keep the per-peer collapse (relay hygiene).
        #expect(relayed.selectedLinks.peripheralIDs == Set(["p1"]))
    }

    @Test
    func minimumLinkLimitUsesTheSmallestPresentRoleLimit() {
        #expect(BLEOutboundLinkPlanner.minimumLinkLimit(peripheralWriteLimits: [80, 120], centralNotifyLimits: []) == 80)
        #expect(BLEOutboundLinkPlanner.minimumLinkLimit(peripheralWriteLimits: [], centralNotifyLimits: [60, 90]) == 60)
        #expect(BLEOutboundLinkPlanner.minimumLinkLimit(peripheralWriteLimits: [], centralNotifyLimits: []) == nil)
    }

    private func makePacket(
        type: MessageType,
        sender: PeerID = PeerID(str: "8877665544332211"),
        recipient: PeerID? = nil,
        ttl: UInt8 = TransportConfig.messageTTLDefault
    ) -> BitchatPacket {
        BitchatPacket(
            type: type.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: recipient.flatMap { Data(hexString: $0.id) },
            timestamp: 1234,
            payload: Data([0x01, 0x02]),
            signature: nil,
            ttl: ttl
        )
    }
}
