//
// GossipSyncBoardTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Board posts ride gossip sync through a provider that queries the board
/// store, so retention (expiry, tombstones, caps) has a single owner.
struct GossipSyncBoardTests {

    private let myPeerID = PeerID(str: "0102030405060708")

    private func makeBoardPacket(timestamp: UInt64) throws -> BitchatPacket {
        BitchatPacket(
            type: MessageType.boardPost.rawValue,
            senderID: try #require(Data(hexString: "aabbccddeeff0011")),
            recipientID: nil,
            timestamp: timestamp,
            payload: Data([0x42]),
            signature: nil,
            ttl: 7
        )
    }

    private func quietConfig() -> GossipSyncManager.Config {
        var config = GossipSyncManager.Config()
        config.messageSyncIntervalSeconds = 0
        config.fragmentSyncIntervalSeconds = 0
        config.fileTransferSyncIntervalSeconds = 0
        config.prekeyBundleSyncIntervalSeconds = 0
        return config
    }

    @Test func boardRequestIsServedFromProvider() async throws {
        let manager = GossipSyncManager(myPeerID: myPeerID, config: quietConfig(), requestSyncManager: RequestSyncManager())
        let delegate = RecordingBoardDelegate()
        manager.delegate = delegate
        let boardPacket = try makeBoardPacket(timestamp: UInt64(Date().timeIntervalSince1970 * 1000))
        manager.boardPacketsProvider = { return [boardPacket] }

        let request = RequestSyncPacket(p: 4, m: 1, data: Data(), types: .board)
        manager.handleRequestSync(from: PeerID(str: "FFFFFFFFFFFFFFFF"), request: request)

        try await TestHelpers.waitFor({ delegate.packets.count == 1 }, timeout: TestConstants.shortTimeout)
        let sent = try #require(delegate.packets.first)
        #expect(sent.type == MessageType.boardPost.rawValue)
        #expect(sent.isRSR)
    }

    @Test func nonBoardRequestDoesNotServeBoardPackets() async throws {
        let manager = GossipSyncManager(myPeerID: myPeerID, config: quietConfig(), requestSyncManager: RequestSyncManager())
        let delegate = RecordingBoardDelegate()
        manager.delegate = delegate
        let boardPacket = try makeBoardPacket(timestamp: UInt64(Date().timeIntervalSince1970 * 1000))
        manager.boardPacketsProvider = { return [boardPacket] }

        let request = RequestSyncPacket(p: 4, m: 1, data: Data(), types: .publicMessages)
        manager.handleRequestSync(from: PeerID(str: "FFFFFFFFFFFFFFFF"), request: request)

        // Follow with a board request; only its response should arrive, which
        // also proves the first request produced nothing.
        let boardRequest = RequestSyncPacket(p: 4, m: 1, data: Data(), types: .board)
        manager.handleRequestSync(from: PeerID(str: "FFFFFFFFFFFFFFFF"), request: boardRequest)

        try await TestHelpers.waitFor({ delegate.packets.count == 1 }, timeout: TestConstants.shortTimeout)
        #expect(delegate.packets.count == 1)
        #expect(delegate.packets.first?.type == MessageType.boardPost.rawValue)
    }

    @Test func maintenanceEmitsBoardRoundOnlyWithProvider() throws {
        var config = quietConfig()
        config.boardSyncIntervalSeconds = 1

        // Without a provider the board schedule stays silent.
        let unwired = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: RequestSyncManager())
        let unwiredDelegate = RecordingBoardDelegate()
        unwired.delegate = unwiredDelegate
        unwired._performMaintenanceSynchronously(now: Date())
        #expect(unwiredDelegate.packets.isEmpty)

        // With a provider, maintenance sends a board-typed request.
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: RequestSyncManager())
        let delegate = RecordingBoardDelegate()
        manager.delegate = delegate
        manager.boardPacketsProvider = { return [] }
        manager._performMaintenanceSynchronously(now: Date())

        #expect(delegate.packets.count == 1)
        let payload = try #require(delegate.packets.first?.payload)
        let request = try #require(RequestSyncPacket.decode(from: payload))
        #expect(request.types == .board)
    }
}

private final class RecordingBoardDelegate: GossipSyncManager.Delegate {
    private let lock = NSLock()
    private var _packets: [BitchatPacket] = []

    var packets: [BitchatPacket] {
        lock.lock()
        defer { lock.unlock() }
        return _packets
    }

    func sendPacket(_ packet: BitchatPacket) {
        lock.lock()
        _packets.append(packet)
        lock.unlock()
    }

    func sendPacket(to peerID: PeerID, packet: BitchatPacket) {
        lock.lock()
        _packets.append(packet)
        lock.unlock()
    }

    func signPacketForBroadcast(_ packet: BitchatPacket) -> BitchatPacket {
        packet
    }

    func getConnectedPeers() -> [PeerID] {
        []
    }
}
