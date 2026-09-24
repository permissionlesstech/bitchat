import BitFoundation
import Testing
@testable import bitchat

struct BLELinkBindingsTests {
    private let peerID = PeerID(str: "1122334455667788")
    private let otherPeerID = PeerID(str: "8899aabbccddeeff")

    @Test
    func centralBindingExposesBoundPeerAndLinks() {
        var bindings = BLELinkBindings()

        bindings.bindCentral("central-a", to: peerID)

        #expect(bindings.peer(forCentralUUID: "central-a") == peerID)
        #expect(bindings.hasCentral(boundTo: peerID))
        #expect(bindings.boundPeer(for: .central("central-a")) == peerID)
        #expect(bindings.links(to: peerID) == [.central("central-a")])
    }

    @Test
    func linksReturnsAllBindingsForPeerAcrossRoles() {
        var bindings = BLELinkBindings()

        bindings.bindCentral("central-a", to: peerID)
        bindings.bindCentral("central-b", to: peerID)
        bindings.bindCentral("central-c", to: otherPeerID)
        bindings.bindPeripheral("periph-a", to: peerID)

        #expect(bindings.links(to: peerID) == [.central("central-a"), .central("central-b"), .peripheral("periph-a")])
    }

    @Test
    func clearCentralsReturnsPreviouslyBoundPeerIDsAndClearsLookups() {
        var bindings = BLELinkBindings()

        bindings.bindCentral("central-a", to: peerID)
        bindings.bindCentral("central-b", to: otherPeerID)

        let removedPeerIDs = Set(bindings.clearCentrals())

        #expect(removedPeerIDs == Set([peerID, otherPeerID]))
        #expect(bindings.peer(forCentralUUID: "central-a") == nil)
        #expect(bindings.links(to: peerID).isEmpty)
    }

    @Test
    func rotationRebindDropsTheRetiredIdentitysReverseMapping() {
        var bindings = BLELinkBindings()
        bindings.bindPeripheral("periph-a", to: peerID)
        #expect(bindings.preferredPeripheralUUID(for: peerID) == "periph-a")

        // The link's owner rotates: the old identity must no longer claim
        // this link as its preferred peripheral.
        bindings.bindPeripheral("periph-a", to: otherPeerID)

        #expect(bindings.preferredPeripheralUUID(for: peerID) == nil)
        #expect(bindings.preferredPeripheralUUID(for: otherPeerID) == "periph-a")
        #expect(bindings.peer(forPeripheralID: "periph-a") == otherPeerID)
    }

    @Test
    func removingThePreferredLinkRepairsOntoTheChosenSurvivor() {
        var bindings = BLELinkBindings()
        bindings.bindPeripheral("periph-a", to: peerID)
        bindings.bindPeripheral("periph-b", to: peerID)
        // periph-b bound last: it is the preferred link.
        #expect(bindings.preferredPeripheralUUID(for: peerID) == "periph-b")

        let removed = bindings.peripheralRemoved("periph-b") { remaining in
            #expect(remaining == ["periph-a"])
            return remaining.first
        }

        #expect(removed == peerID)
        #expect(bindings.preferredPeripheralUUID(for: peerID) == "periph-a")
        #expect(bindings.links(to: peerID) == [.peripheral("periph-a")])
    }

    @Test
    func removingADuplicateLinkDoesNotStrandThePreferredOne() {
        var bindings = BLELinkBindings()
        bindings.bindPeripheral("periph-a", to: peerID)
        bindings.bindPeripheral("periph-b", to: peerID)

        // Removing the non-preferred duplicate must leave the reverse map
        // untouched (no repair callback consulted for a non-preferred link).
        let removed = bindings.peripheralRemoved("periph-a") { _ in
            Issue.record("survivor choice must not run for a non-preferred link")
            return nil
        }

        #expect(removed == peerID)
        #expect(bindings.preferredPeripheralUUID(for: peerID) == "periph-b")
    }

    @Test
    func removingTheLastLinkClearsThePreferredMapping() {
        var bindings = BLELinkBindings()
        bindings.bindPeripheral("periph-a", to: peerID)

        let removed = bindings.peripheralRemoved("periph-a") { remaining in
            #expect(remaining.isEmpty)
            return nil
        }

        #expect(removed == peerID)
        #expect(bindings.preferredPeripheralUUID(for: peerID) == nil)
        #expect(bindings.links(to: peerID).isEmpty)
    }
}
