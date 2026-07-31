import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLENoiseSessionQueuesTests {
    @Test
    func privateMessagesDrainInPeerOrderAndClearOnlyThatPeer() {
        let firstPeer = PeerID(str: "aaaaaaaaaaaaaaaa")
        let secondPeer = PeerID(str: "bbbbbbbbbbbbbbbb")
        var queues = BLENoiseSessionQueues()

        queues.appendPrivateMessage(content: "first", messageID: "m1", for: firstPeer)
        queues.appendPrivateMessage(content: "second", messageID: "m2", for: firstPeer)
        queues.appendPrivateMessage(content: "other", messageID: "m3", for: secondPeer)

        let drained = queues.takePrivateMessages(for: firstPeer)

        #expect(drained == [
            BLEPendingPrivateMessage(content: "first", messageID: "m1"),
            BLEPendingPrivateMessage(content: "second", messageID: "m2")
        ])
        #expect(queues.takePrivateMessages(for: firstPeer).isEmpty)
        #expect(queues.takePrivateMessages(for: secondPeer) == [
            BLEPendingPrivateMessage(content: "other", messageID: "m3")
        ])
    }

    @Test
    func prependPrivateMessagesRestoresFailedMessagesAheadOfNewerOnes() {
        let peerID = PeerID(str: "aaaaaaaaaaaaaaaa")
        var queues = BLENoiseSessionQueues()

        queues.appendPrivateMessage(content: "new", messageID: "m2", for: peerID)
        queues.prependPrivateMessages([
            BLEPendingPrivateMessage(content: "retry", messageID: "m1")
        ], for: peerID)

        #expect(queues.takePrivateMessages(for: peerID).map(\.messageID) == ["m1", "m2"])
    }

    @Test
    func typedPayloadsDrainIndependentlyFromPrivateMessages() {
        let peerID = PeerID(str: "aaaaaaaaaaaaaaaa")
        var queues = BLENoiseSessionQueues()

        queues.appendPrivateMessage(content: "queued", messageID: "m1", for: peerID)
        queues.appendTypedPayload(Data([0x01]), for: peerID)
        queues.appendTypedPayload(Data([0x02]), for: peerID)

        #expect(queues.takeTypedPayloads(for: peerID).map(\.payload) == [Data([0x01]), Data([0x02])])
        #expect(queues.takeTypedPayloads(for: peerID).isEmpty)
        #expect(queues.takePrivateMessages(for: peerID).map(\.messageID) == ["m1"])
    }

    @Test
    func typedPayloadsPreserveFragmentTrainMetadata() {
        let peerID = PeerID(str: "aaaaaaaaaaaaaaaa")
        var queues = BLENoiseSessionQueues()

        queues.appendTypedPayload(
            Data([0x09]),
            for: peerID,
            fragmentTrainId: "image-transfer#noise-chunk-0",
            reportsTransferProgress: false
        )

        let drained = queues.takeTypedPayloads(for: peerID)

        #expect(drained == [
            BLEPendingTypedPayload(
                payload: Data([0x09]),
                fragmentTrainId: "image-transfer#noise-chunk-0",
                reportsTransferProgress: false
            )
        ])
    }

    @Test
    func removeAllClearsBothQueueTypes() {
        let peerID = PeerID(str: "aaaaaaaaaaaaaaaa")
        var queues = BLENoiseSessionQueues()

        queues.appendPrivateMessage(content: "queued", messageID: "m1", for: peerID)
        queues.appendTypedPayload(Data([0x01]), for: peerID)
        queues.removeAll()

        #expect(queues.isEmpty)
    }
}
