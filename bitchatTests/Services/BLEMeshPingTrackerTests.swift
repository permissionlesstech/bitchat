import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEMeshPingTrackerTests {
    private func makeProbe(peerID: PeerID) -> BLEMeshPingProbe {
        BLEMeshPingProbe(
            peerID: peerID,
            sentAt: Date(timeIntervalSince1970: 1_000),
            lifecycleGeneration: 1,
            completion: { _ in },
            timeout: DispatchWorkItem {}
        )
    }

    @Test func resolveReturnsProbeOnlyForTheProbedPeer() {
        var tracker = BLEMeshPingTracker()
        let nonce = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let probed = PeerID(str: "aaaaaaaaaaaaaaaa")
        tracker.register(makeProbe(peerID: probed), nonce: nonce)

        // A pong claiming the right nonce from the wrong peer must not
        // consume the probe.
        let wrongPeer = tracker.resolve(nonce: nonce, from: PeerID(str: "bbbbbbbbbbbbbbbb"))
        #expect(wrongPeer == nil)
        let rightPeer = tracker.resolve(nonce: nonce, from: probed)
        #expect(rightPeer != nil)
        // Consumed exactly once.
        let secondResolve = tracker.resolve(nonce: nonce, from: probed)
        #expect(secondResolve == nil)
    }

    @Test func expireConsumesTheProbeSoResolveCannotFireTwice() {
        var tracker = BLEMeshPingTracker()
        let nonce = Data([9, 9, 9, 9, 9, 9, 9, 9])
        let probed = PeerID(str: "aaaaaaaaaaaaaaaa")
        tracker.register(makeProbe(peerID: probed), nonce: nonce)

        let firstExpire = tracker.expire(nonce: nonce)
        #expect(firstExpire != nil)
        let secondExpire = tracker.expire(nonce: nonce)
        #expect(secondExpire == nil)
        let resolveAfterExpire = tracker.resolve(nonce: nonce, from: probed)
        #expect(resolveAfterExpire == nil)
    }

    @Test func inboundBudgetIsPerLinkAndBounded() {
        var tracker = BLEMeshPingTracker()
        let now = Date(timeIntervalSince1970: 2_000)
        let linkA = PeerID(str: "aaaaaaaaaaaaaaaa")
        let linkB = PeerID(str: "bbbbbbbbbbbbbbbb")

        var allowedOnA = 0
        for _ in 0..<(TransportConfig.meshPingInboundMaxPerLink + 5) {
            if tracker.shouldRespond(toLink: linkA, now: now) { allowedOnA += 1 }
        }
        #expect(allowedOnA == TransportConfig.meshPingInboundMaxPerLink)
        // One saturated link must not consume another link's budget.
        let allowedOnB = tracker.shouldRespond(toLink: linkB, now: now)
        #expect(allowedOnB)
    }

    @Test func resetDropsProbesRestoresBudgetAndHandsBackTimeouts() {
        var tracker = BLEMeshPingTracker()
        let now = Date(timeIntervalSince1970: 3_000)
        let link = PeerID(str: "aaaaaaaaaaaaaaaa")
        let nonce = Data([4, 4, 4, 4, 4, 4, 4, 4])
        tracker.register(makeProbe(peerID: link), nonce: nonce)
        for _ in 0..<TransportConfig.meshPingInboundMaxPerLink {
            _ = tracker.shouldRespond(toLink: link, now: now)
        }
        let saturated = tracker.shouldRespond(toLink: link, now: now)
        #expect(!saturated)

        let timeouts = tracker.reset()

        #expect(timeouts.count == 1)
        let resolveAfterReset = tracker.resolve(nonce: nonce, from: link)
        #expect(resolveAfterReset == nil)
        let allowedAfterReset = tracker.shouldRespond(toLink: link, now: now)
        #expect(allowedAfterReset)
    }
}
