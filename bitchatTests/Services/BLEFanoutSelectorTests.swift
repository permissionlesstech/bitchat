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
