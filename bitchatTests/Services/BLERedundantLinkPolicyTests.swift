import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLERedundantLinkPolicyTests {
    private let peer = PeerID(str: "1122334455667788")
    private let otherPeer = PeerID(str: "8877665544332211")

    private func link(_ uuid: String, _ peerID: PeerID?, connected: Bool = true, writable: Bool = true) -> BLERedundantLinkPolicy.PeripheralLink {
        BLERedundantLinkPolicy.PeripheralLink(uuid: uuid, peerID: peerID, isConnected: connected, hasCharacteristic: writable)
    }

    @Test
    func singleBoundLinkNeedsNoConsolidation() {
        let kept = BLERedundantLinkPolicy.keptPeripheralUUID(
            ingressPeripheralUUID: "p1",
            mostRecentlyBoundUUID: "p1",
            links: [link("p1", peer), link("p2", otherPeer)],
            peerID: peer
        )
        #expect(kept == nil)
    }

    @Test
    func ingressLinkOfVerifiedAnnounceWinsOverReverseMap() {
        let kept = BLERedundantLinkPolicy.keptPeripheralUUID(
            ingressPeripheralUUID: "p-ingress",
            mostRecentlyBoundUUID: "p-reverse",
            links: [link("p-ingress", peer), link("p-reverse", peer), link("p-stale", peer)],
            peerID: peer
        )
        #expect(kept == "p-ingress")
    }

    @Test
    func centralIngressFallsBackToMostRecentlyBoundLink() {
        // The announce arrived on the central link (a write), so no ingress
        // peripheral exists; the peer's reverse-mapped link survives.
        let kept = BLERedundantLinkPolicy.keptPeripheralUUID(
            ingressPeripheralUUID: nil,
            mostRecentlyBoundUUID: "p-reverse",
            links: [link("p-reverse", peer), link("p-stale", peer)],
            peerID: peer
        )
        #expect(kept == "p-reverse")
    }

    @Test
    func noLiveCandidateAmongBoundLinksRetiresNothing() {
        let kept = BLERedundantLinkPolicy.keptPeripheralUUID(
            ingressPeripheralUUID: nil,
            mostRecentlyBoundUUID: "p-disconnected",
            links: [link("p-disconnected", peer, connected: false), link("p1", peer), link("p2", peer)],
            peerID: peer
        )
        #expect(kept == nil)
    }

    @Test
    func characteristicLessAnchorLosesToWritableDuplicate() {
        // The ingress link is mid-service-rediscovery (no characteristic):
        // keeping it and cancelling the writable duplicate would strand
        // outbound traffic on the central link, so the writable
        // reverse-mapped link wins.
        let kept = BLERedundantLinkPolicy.keptPeripheralUUID(
            ingressPeripheralUUID: "p-charless",
            mostRecentlyBoundUUID: "p-writable",
            links: [link("p-charless", peer, writable: false), link("p-writable", peer)],
            peerID: peer
        )
        #expect(kept == "p-writable")
    }

    @Test
    func writableDuplicateThatIsNoAnchorDefersConsolidation() {
        // Both anchors are characteristic-less but a writable third link
        // exists: never keep a charless link over it — wait for a later
        // announce instead of guessing which link to keep.
        let kept = BLERedundantLinkPolicy.keptPeripheralUUID(
            ingressPeripheralUUID: "p-charless-1",
            mostRecentlyBoundUUID: "p-charless-2",
            links: [
                link("p-charless-1", peer, writable: false),
                link("p-charless-2", peer, writable: false),
                link("p-writable", peer)
            ],
            peerID: peer
        )
        #expect(kept == nil)
    }

    @Test
    func allCharacteristicLessDuplicatesStillConsolidateOnIngress() {
        // No writable link exists at all (all mid-rediscovery): the ingress
        // anchor still consolidates — no writable duplicate is at risk.
        let kept = BLERedundantLinkPolicy.keptPeripheralUUID(
            ingressPeripheralUUID: "p-ingress",
            mostRecentlyBoundUUID: "p-stale",
            links: [link("p-ingress", peer, writable: false), link("p-stale", peer, writable: false)],
            peerID: peer
        )
        #expect(kept == "p-ingress")
    }

    @Test
    func retirementSparesKeptLinkUnboundLinksAndOtherPeers() {
        let retiring = BLERedundantLinkPolicy.peripheralUUIDsToRetire(
            links: [
                link("p-kept", peer),
                link("p-dup-1", peer),
                link("p-dup-2", peer),
                link("p-gone", peer, connected: false),
                link("p-unbound", nil),
                link("p-other", otherPeer)
            ],
            peerID: peer,
            keeping: "p-kept"
        )
        #expect(Set(retiring) == Set(["p-dup-1", "p-dup-2"]))
    }

    @Test
    func rotationCleanupWithNoSurvivorRetiresEveryBoundLink() {
        // Rotated-away identity: the rebound link now belongs to the new ID,
        // so every link still bound to the old ID is a stale duplicate.
        let retiring = BLERedundantLinkPolicy.peripheralUUIDsToRetire(
            links: [link("p-stale-1", peer), link("p-stale-2", peer)],
            peerID: peer,
            keeping: ""
        )
        #expect(Set(retiring) == Set(["p-stale-1", "p-stale-2"]))
    }
}
