import Foundation
import XCTest
@testable import bitchat

final class GossipSyncManagerTests: XCTestCase {
    func testConcurrentPacketIntakeAndSyncRequest() {
        let manager = GossipSyncManager(myPeerID: PeerID(str: "0102030405060708"))
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
            manager.scheduleInitialSyncToPeer(PeerID(str: "FFFFFFFFFFFFFFFF"), delaySeconds: 0.0)
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

    func testStaleAnnouncementsArePurgedWithMessages() {
        var config = GossipSyncManager.Config()
        config.stalePeerCleanupIntervalSeconds = 0
        config.stalePeerTimeoutSeconds = 5

        let manager = GossipSyncManager(myPeerID: "0102030405060708", config: config)
        let peerHex = "0011223344556677"
        let senderData = Data(hexString: peerHex) ?? Data()
        let initialTimestampMs = UInt64(Date().timeIntervalSince1970 * 1000)

        let announcePacket = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: senderData,
            recipientID: nil,
            timestamp: initialTimestampMs,
            payload: Data(),
            signature: nil,
            ttl: 1
        )

        let messagePacket = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: senderData,
            recipientID: nil,
            timestamp: initialTimestampMs,
            payload: Data([0x01]),
            signature: nil,
            ttl: 1
        )

        manager.onPublicPacketSeen(announcePacket)
        manager.onPublicPacketSeen(messagePacket)

        // Flush queue without triggering stale cleanup yet
        manager._performMaintenanceSynchronously(now: Date())
        XCTAssertTrue(manager._hasAnnouncement(for: PeerID(str: peerHex)))
        XCTAssertEqual(manager._messageCount(for: PeerID(str: peerHex)), 1)

        // Run cleanup past the timeout
        let future = Date().addingTimeInterval(config.stalePeerTimeoutSeconds + 1)
        manager._performMaintenanceSynchronously(now: future)
        XCTAssertFalse(manager._hasAnnouncement(for: PeerID(str: peerHex)))
        XCTAssertEqual(manager._messageCount(for: PeerID(str: peerHex)), 0)
    }

    func testIgnoresAnnounceOlderThanStaleTimeout() {
        var config = GossipSyncManager.Config()
        config.stalePeerTimeoutSeconds = 5
        config.maxMessageAgeSeconds = 100

        let manager = GossipSyncManager(myPeerID: "0102030405060708", config: config)
        let peerHex = "8899aabbccddeeff"
        let senderData = Data(hexString: peerHex) ?? Data()
        let staleTimestampMs = UInt64(Date().addingTimeInterval(-(config.stalePeerTimeoutSeconds + 1)).timeIntervalSince1970 * 1000)

        let freshMessage = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: senderData,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data([0xAA]),
            signature: nil,
            ttl: 1
        )
        manager.onPublicPacketSeen(freshMessage)

        let announcePacket = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: senderData,
            recipientID: nil,
            timestamp: staleTimestampMs,
            payload: Data(),
            signature: nil,
            ttl: 1
        )

        manager.onPublicPacketSeen(announcePacket)

        manager._performMaintenanceSynchronously()

        XCTAssertFalse(manager._hasAnnouncement(for: PeerID(str: peerHex)))
        XCTAssertEqual(manager._messageCount(for: PeerID(str: peerHex)), 0)
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
