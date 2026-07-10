import BitFoundation
import Testing
@testable import bitchat

struct BLELinkStateStoreTests {
    @Test
    func centralBindingExposesDirectLinkStateAndLinks() {
        let store = BLELinkStateStore()
        let peerID = PeerID(str: "1122334455667788")

        store.bindCentral("central-a", to: peerID)

        #expect(store.peerID(forCentralUUID: "central-a") == peerID)
        #expect(store.directLinkState(for: peerID) == BLEDirectLinkState(hasPeripheral: false, hasCentral: true))
        #expect(store.links(to: peerID) == [.central("central-a")])
    }

    @Test
    func linksReturnsAllCentralBindingsForPeer() {
        let store = BLELinkStateStore()
        let peerID = PeerID(str: "1122334455667788")
        let otherPeerID = PeerID(str: "8899aabbccddeeff")

        store.bindCentral("central-a", to: peerID)
        store.bindCentral("central-b", to: peerID)
        store.bindCentral("central-c", to: otherPeerID)

        #expect(store.links(to: peerID) == [.central("central-a"), .central("central-b")])
    }

    @Test
    func clearCentralsReturnsPreviouslyBoundPeerIDsAndClearsLookups() {
        let store = BLELinkStateStore()
        let firstPeerID = PeerID(str: "1122334455667788")
        let secondPeerID = PeerID(str: "8899aabbccddeeff")

        store.bindCentral("central-a", to: firstPeerID)
        store.bindCentral("central-b", to: secondPeerID)

        let removedPeerIDs = Set(store.clearCentrals())

        #expect(removedPeerIDs == Set([firstPeerID, secondPeerID]))
        #expect(store.peerID(forCentralUUID: "central-a") == nil)
        #expect(store.links(to: firstPeerID).isEmpty)
    }
}
