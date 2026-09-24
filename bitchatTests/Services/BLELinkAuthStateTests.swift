import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLELinkAuthStateTests {
    private let peerID = PeerID(str: "1122334455667788")
    private let link = BLEIngressLinkID.peripheral("periph-a")

    @Test
    func authenticationBindsToTheExactLinkAndOwner() {
        var auth = BLELinkAuthState()
        auth.markAuthenticated(link, owner: peerID)

        #expect(auth.isAuthenticated(link, for: peerID))
        #expect(!auth.isAuthenticated(link, for: PeerID(str: "8899aabbccddeeff")))
        #expect(!auth.isAuthenticated(.peripheral("periph-b"), for: peerID))

        auth.retireLink(link)
        #expect(!auth.isAuthenticated(link, for: peerID))
    }

    @Test
    func retireLinksOwnedByPeerReturnsAndRetiresThemAll() {
        var auth = BLELinkAuthState()
        auth.markAuthenticated(.peripheral("periph-a"), owner: peerID)
        auth.markAuthenticated(.central("central-a"), owner: peerID)
        auth.markAuthenticated(.central("central-b"), owner: PeerID(str: "8899aabbccddeeff"))

        let departed = Set(auth.retireLinks(ownedBy: peerID))

        #expect(departed == [.peripheral("periph-a"), .central("central-a")])
        #expect(auth.links(ownedBy: peerID).isEmpty)
        #expect(auth.isAuthenticated(.central("central-b"), for: PeerID(str: "8899aabbccddeeff")))
    }

    @Test
    func rebindCooldownPermitsOncePerWindowAndAgesOut() {
        var auth = BLELinkAuthState()
        let start = Date(timeIntervalSince1970: 1_000)

        let first = auth.permitRebind(linkUUID: "periph-a", now: start, cooldown: 30)
        #expect(first)
        let withinWindow = auth.permitRebind(linkUUID: "periph-a", now: start.addingTimeInterval(10), cooldown: 30)
        #expect(!withinWindow)
        // A different link has its own allowance.
        let otherLink = auth.permitRebind(linkUUID: "periph-b", now: start.addingTimeInterval(10), cooldown: 30)
        #expect(otherLink)
        // The window ages out.
        let afterWindow = auth.permitRebind(linkUUID: "periph-a", now: start.addingTimeInterval(31), cooldown: 30)
        #expect(afterWindow)
    }

    @Test
    func containmentCooldownsSurviveASessionReset() {
        var auth = BLELinkAuthState()
        let start = Date(timeIntervalSince1970: 2_000)
        auth.markAuthenticated(link, owner: peerID)
        let rebindBefore = auth.permitRebind(linkUUID: "periph-a", now: start, cooldown: 30)
        let retirementBefore = auth.permitRedundantRetirement(peerID: peerID, now: start, cooldown: 30)
        #expect(rebindBefore)
        #expect(retirementBefore)

        // Panic/emergency resets wipe proofs and epochs — but a stable
        // CoreBluetooth UUID must not earn a fresh rebind or retirement
        // allowance just because the session state around it was wiped.
        auth.removeAll()

        #expect(!auth.isAuthenticated(link, for: peerID))
        let rebindAfterReset = auth.permitRebind(linkUUID: "periph-a", now: start.addingTimeInterval(5), cooldown: 30)
        let retirementAfterReset = auth.permitRedundantRetirement(peerID: peerID, now: start.addingTimeInterval(5), cooldown: 30)
        #expect(!rebindAfterReset)
        #expect(!retirementAfterReset)
    }
}
