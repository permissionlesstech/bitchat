import Foundation
import XCTest
@testable import bitchat

final class GossipSyncManagerTests: XCTestCase {
    func testConcurrentPacketIntakeAndSyncRequest() {
        let manager = GossipSyncManager(myPeerID: "0102030405060708")
        let delegate = RecordingDelegate()
        let sendExpectation = expectation(description: "sync request sent")
        delegate.onSend = { sendExpectation.fulfill() }
        manager.delegate = delegate

        let iterations = 200
        let group = DispatchGroup()

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let packet = BitchatPacket(
                    type: MessageType.message.rawValue,
                    senderID: Data(hexString: "1122334455667788") ?? Data(),
                    recipientID: nil,
                    timestamp: 1_000_000 + UInt64(i),
                    payload: Data([UInt8(truncatingIfNeeded: i)]),
                    signature: nil,
                    ttl: 1
                )
                manager.onPublicPacketSeen(packet)
                Thread.sleep(forTimeInterval: 0.001)
                group.leave()
            }
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.002) {
            manager.scheduleInitialSyncToPeer("FFFFFFFFFFFFFFFF", delaySeconds: 0.0)
        }

        group.wait()
        wait(for: [sendExpectation], timeout: 2.0)

        guard let lastPacket = delegate.lastPacket else {
            XCTFail("Expected sync packet to be sent")
            return
        }

        XCTAssertEqual(lastPacket.type, MessageType.requestSync.rawValue)
        XCTAssertNotNil(RequestSyncPacket.decode(from: lastPacket.payload))
    }
}

private final class RecordingDelegate: GossipSyncManager.Delegate {
    var onSend: (() -> Void)?
    private(set) var lastPacket: BitchatPacket?
    private let lock = NSLock()

    func sendPacket(_ packet: BitchatPacket) {
        lock.lock()
        lastPacket = packet
        lock.unlock()
        onSend?()
    }

    func sendPacket(to peerID: PeerID, packet: BitchatPacket) {
        sendPacket(packet)
    }

    func signPacketForBroadcast(_ packet: BitchatPacket) -> BitchatPacket {
        packet
    }
}
