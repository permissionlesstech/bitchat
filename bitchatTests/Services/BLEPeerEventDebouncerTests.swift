import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLEPeerEventDebouncerTests {
    @Test
    func suppressesRepeatedPeerEventsInsideInterval() {
        let peerID = PeerID(str: "1122334455667788")
        let now = Date(timeIntervalSince1970: 100)
        var debouncer = BLEPeerEventDebouncer()

        let first = debouncer.shouldEmit(peerID: peerID, now: now, minimumInterval: 5)
        let suppressed = debouncer.shouldEmit(peerID: peerID, now: now.addingTimeInterval(4.9), minimumInterval: 5)
        let afterInterval = debouncer.shouldEmit(peerID: peerID, now: now.addingTimeInterval(5), minimumInterval: 5)

        #expect(first)
        #expect(!suppressed)
        #expect(afterInterval)
    }

    @Test
    func tracksPeersIndependently() {
        let first = PeerID(str: "1122334455667788")
        let second = PeerID(str: "8877665544332211")
        let now = Date(timeIntervalSince1970: 100)
        var debouncer = BLEPeerEventDebouncer()

        let firstEmit = debouncer.shouldEmit(peerID: first, now: now, minimumInterval: 5)
        let secondEmit = debouncer.shouldEmit(peerID: second, now: now.addingTimeInterval(1), minimumInterval: 5)
        let firstRepeat = debouncer.shouldEmit(peerID: first, now: now.addingTimeInterval(1), minimumInterval: 5)

        #expect(firstEmit)
        #expect(secondEmit)
        #expect(!firstRepeat)
        #expect(debouncer.count == 2)
    }

    @Test
    func removeAllClearsDebounceState() {
        let peerID = PeerID(str: "1122334455667788")
        let now = Date(timeIntervalSince1970: 100)
        var debouncer = BLEPeerEventDebouncer()

        debouncer.shouldEmit(peerID: peerID, now: now, minimumInterval: 5)
        debouncer.removeAll()

        #expect(debouncer.count == 0)
        let afterClear = debouncer.shouldEmit(peerID: peerID, now: now.addingTimeInterval(1), minimumInterval: 5)
        #expect(afterClear)
    }
}
