import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEFanoutSelectorTests {
    @Test
    func directedSendUsesAllNonIngressLinks() {
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["p1", "p2"],
            centralIDs: ["c1", "c2"],
            ingressLink: .central("c1"),
            directedPeerHint: PeerID(str: "1122334455667788"),
            packetType: MessageType.noiseEncrypted.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs == Set(["p1", "p2"]))
        #expect(selection.centralIDs == Set(["c2"]))
    }

    @Test
    func directedSendUsesOnlyBoundPeripheralLinkWhenAvailable() {
        let target = PeerID(str: "1122334455667788")
        let bystander = PeerID(str: "8877665544332211")
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["target-p", "bystander-p"],
            centralIDs: ["target-c", "bystander-c"],
            ingressLink: nil,
            peripheralPeerBindings: [
                "target-p": target,
                "bystander-p": bystander
            ],
            centralPeerBindings: [
                "target-c": target,
                "bystander-c": bystander
            ],
            directedPeerHint: target,
            packetType: MessageType.courierEnvelope.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs == Set(["target-p"]))
        #expect(selection.centralIDs.isEmpty)
    }

    @Test
    func directedSendUsesBoundCentralLinkWhenNoPeripheralLinkExists() {
        let target = PeerID(str: "1122334455667788")
        let bystander = PeerID(str: "8877665544332211")
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["bystander-p"],
            centralIDs: ["target-c", "bystander-c"],
            ingressLink: nil,
            peripheralPeerBindings: [
                "bystander-p": bystander
            ],
            centralPeerBindings: [
                "target-c": target,
                "bystander-c": bystander
            ],
            directedPeerHint: target,
            packetType: MessageType.courierEnvelope.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs.isEmpty)
        #expect(selection.centralIDs == Set(["target-c"]))
    }

    @Test
    func directedSendToKnownPeerDoesNotFallBackWhenOnlyDirectLinkIsExcluded() {
        let target = PeerID(str: "1122334455667788")
        let bystander = PeerID(str: "8877665544332211")
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["bystander-p"],
            centralIDs: ["target-c", "bystander-c"],
            ingressLink: .central("target-c"),
            peripheralPeerBindings: [
                "bystander-p": bystander
            ],
            centralPeerBindings: [
                "target-c": target,
                "bystander-c": bystander
            ],
            directedPeerHint: target,
            packetType: MessageType.courierEnvelope.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs.isEmpty)
        #expect(selection.centralIDs.isEmpty)
    }

    @Test
    func directedSendExcludesAllLinksToIngressPeer() {
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["p1", "p2"],
            centralIDs: ["c1", "c2"],
            ingressLink: .central("c1"),
            excludedLinks: [.peripheral("p2"), .central("c2")],
            directedPeerHint: PeerID(str: "1122334455667788"),
            packetType: MessageType.noiseEncrypted.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs == Set(["p1"]))
        #expect(selection.centralIDs.isEmpty)
    }

    @Test
    func controlPacketsUseAllNonIngressLinks() {
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["p1", "p2", "p3"],
            centralIDs: ["c1", "c2", "c3"],
            ingressLink: .peripheral("p2"),
            directedPeerHint: nil,
            packetType: MessageType.requestSync.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs == Set(["p1", "p3"]))
        #expect(selection.centralIDs == Set(["c1", "c2", "c3"]))
    }

    @Test
    func broadcastPacketsUseDeterministicSubsetAfterIngressExclusion() {
        let peripherals = (1...8).map { "p\($0)" }
        let centrals = (1...8).map { "c\($0)" }

        let first = BLEFanoutSelector.selectLinks(
            peripheralIDs: peripherals,
            centralIDs: centrals,
            ingressLink: .peripheral("p4"),
            directedPeerHint: nil,
            packetType: MessageType.message.rawValue,
            messageID: "message-1"
        )
        let second = BLEFanoutSelector.selectLinks(
            peripheralIDs: peripherals,
            centralIDs: centrals,
            ingressLink: .peripheral("p4"),
            directedPeerHint: nil,
            packetType: MessageType.message.rawValue,
            messageID: "message-1"
        )

        #expect(first == second)
        #expect(!first.peripheralIDs.contains("p4"))
        #expect(first.peripheralIDs.count == 4)
        #expect(first.centralIDs.count == 4)
    }

    @Test
    func dualLinkPeerRelaysOnSingleLinkPreferringPeripheral() {
        // A dual-role pair holds two live links to the same peer; relays must
        // not transmit the same packet down both. The peripheral (write) link
        // wins because it has per-link flow control.
        let peer = PeerID(str: "1122334455667788")
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["p1"],
            centralIDs: ["c1"],
            ingressLink: nil,
            peripheralPeerBindings: ["p1": peer],
            centralPeerBindings: ["c1": peer],
            directedPeerHint: nil,
            packetType: MessageType.fragment.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs == Set(["p1"]))
        #expect(selection.centralIDs.isEmpty)
    }

    @Test
    func unboundLinksSurviveDuplicatePeerCollapse() {
        // Links whose peer is not yet known (pre-announce) must keep
        // receiving broadcasts alongside a deduplicated bound pair.
        let peer = PeerID(str: "1122334455667788")
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["p1"],
            centralIDs: ["c-bound", "c-unbound"],
            ingressLink: nil,
            peripheralPeerBindings: ["p1": peer],
            centralPeerBindings: ["c-bound": peer],
            directedPeerHint: nil,
            packetType: MessageType.fragment.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs == Set(["p1"]))
        #expect(selection.centralIDs == Set(["c-unbound"]))
    }

    @Test
    func duplicateBoundLinksToOnePeerCollapseToItsPreferredLink() {
        // After a restore the same phone can hold several live links bound to
        // one peer; broadcasts must go down exactly one — the most recently
        // bound (preferred) one, not dictionary order.
        let peer = PeerID(str: "1122334455667788")
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["p-stale", "p-preferred", "p-stale-2"],
            centralIDs: ["c-bound"],
            ingressLink: nil,
            peripheralPeerBindings: [
                "p-stale": peer,
                "p-preferred": peer,
                "p-stale-2": peer
            ],
            centralPeerBindings: ["c-bound": peer],
            preferredPeripheralPerPeer: [peer: "p-preferred"],
            directedPeerHint: nil,
            packetType: MessageType.fragment.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs == Set(["p-preferred"]))
        #expect(selection.centralIDs.isEmpty)
    }

    @Test
    func directedSendCollapsesDuplicateBoundLinksToPreferred() {
        let peer = PeerID(str: "1122334455667788")
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["p-stale", "p-preferred"],
            centralIDs: [],
            ingressLink: nil,
            peripheralPeerBindings: [
                "p-stale": peer,
                "p-preferred": peer
            ],
            preferredPeripheralPerPeer: [peer: "p-preferred"],
            directedPeerHint: peer,
            packetType: MessageType.noiseEncrypted.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs == Set(["p-preferred"]))
        #expect(selection.centralIDs.isEmpty)
    }

    @Test
    func uncollapsedSelectionReachesEveryLinkOfADuplicatelyLinkedPeer() {
        // Announce fanout (collapse bypassed by the planner): the announce is
        // the packet that binds links, so every live link must receive it.
        let peer = PeerID(str: "1122334455667788")
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["p1", "p2"],
            centralIDs: ["c1"],
            ingressLink: nil,
            peripheralPeerBindings: ["p1": peer, "p2": peer],
            centralPeerBindings: ["c1": peer],
            preferredPeripheralPerPeer: [peer: "p1"],
            collapseDuplicatePeerLinks: false,
            directedPeerHint: nil,
            packetType: MessageType.announce.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs == Set(["p1", "p2"]))
        #expect(selection.centralIDs == Set(["c1"]))
    }

    @Test
    func broadcastWithTwoLinksKeepsBothAfterIngressExclusion() {
        let selection = BLEFanoutSelector.selectLinks(
            peripheralIDs: ["p1", "p2"],
            centralIDs: ["c1", "c2"],
            ingressLink: nil,
            directedPeerHint: nil,
            packetType: MessageType.message.rawValue,
            messageID: "message-1"
        )

        #expect(selection.peripheralIDs == Set(["p1", "p2"]))
        #expect(selection.centralIDs == Set(["c1", "c2"]))
    }
}
