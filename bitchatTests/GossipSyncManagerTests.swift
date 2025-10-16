import Foundation
import Testing
@testable import bitchat

struct GossipSyncManagerTests {

    private let myPeerID = PeerID(str: "0102030405060708")
    
    @Test func concurrentPacketIntakeAndSyncRequest() async throws {
        let manager = GossipSyncManager(myPeerID: myPeerID)
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        try await confirmation("sync request sent") { sent in
            delegate.onSend = {
                sent()
            }

            let iterations = 200
            let senderID = try #require(Data(hexString: "1122334455667788"))
            
            for i in 0..<iterations {
                let packet = BitchatPacket(
                    type: MessageType.message.rawValue,
                    senderID: senderID,
                    recipientID: nil,
                    timestamp: 1_000_000 + UInt64(i),
                    payload: Data([UInt8(truncatingIfNeeded: i)]),
                    signature: nil,
                    ttl: 1
                )
                manager.onPublicPacketSeen(packet)
                try await sleep(0.001)
            }

            manager.scheduleInitialSyncToPeer(PeerID(str: "FFFFFFFFFFFFFFFF"), delaySeconds: 0.0)
            try await sleep(0.002)
        }

        let lastPacket = try #require(delegate.lastPacket, "Expected sync packet to be sent")
        #expect(lastPacket.type == MessageType.requestSync.rawValue)
        #expect(RequestSyncPacket.decode(from: lastPacket.payload) != nil)
    }

    @Test func staleAnnouncementsArePurgedWithMessages() throws {
        var config = GossipSyncManager.Config()
        config.stalePeerCleanupIntervalSeconds = 0
        config.stalePeerTimeoutSeconds = 5

        let manager = GossipSyncManager(myPeerID: myPeerID, config: config)
        let peerHex = "0011223344556677"
        let senderData = try #require(Data(hexString: peerHex))
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
        #expect(manager._hasAnnouncement(for: PeerID(str: peerHex)))
        #expect(manager._messageCount(for: PeerID(str: peerHex)) == 1)
        
        // Run cleanup past the timeout
        let future = Date().addingTimeInterval(config.stalePeerTimeoutSeconds + 1)
        manager._performMaintenanceSynchronously(now: future)
        #expect(manager._hasAnnouncement(for: PeerID(str: peerHex)) == false)
        #expect(manager._messageCount(for: PeerID(str: peerHex)) == 0)
    }

    @Test func ignoresAnnounceOlderThanStaleTimeout() throws {
        var config = GossipSyncManager.Config()
        config.stalePeerTimeoutSeconds = 5
        config.maxMessageAgeSeconds = 100

        let manager = GossipSyncManager(myPeerID: myPeerID, config: config)
        let peerHex = "8899aabbccddeeff"
        let senderData = try #require(Data(hexString: peerHex))
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

        #expect(manager._hasAnnouncement(for: PeerID(str: peerHex)) == false)
        #expect(manager._messageCount(for: PeerID(str: peerHex)) == 0)
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
