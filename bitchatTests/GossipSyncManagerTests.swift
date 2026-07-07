import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct GossipSyncManagerTests {

    private let myPeerID = PeerID(str: "0102030405060708")
    
    @Test func concurrentPacketIntakeAndSyncRequest() async throws {
        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, requestSyncManager: requestSyncManager)
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        try await confirmation("sync request sent") { sent in
            delegate.onSend = {
                delegate.onSend = nil
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
            try await TestHelpers.waitFor({ delegate.lastPacket != nil }, timeout: TestConstants.shortTimeout)
        }

        let lastPacket = try #require(delegate.lastPacket, "Expected sync packet to be sent")
        #expect(lastPacket.type == MessageType.requestSync.rawValue)
        #expect(RequestSyncPacket.decode(from: lastPacket.payload) != nil)
    }

    @Test func staleAnnouncementsArePurgedWithMessages() throws {
        var config = GossipSyncManager.Config()
        config.stalePeerCleanupIntervalSeconds = 0
        config.stalePeerTimeoutSeconds = 5

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
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

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
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

    @Test func maintenanceEmitsTypedSyncRequests() throws {
        var config = GossipSyncManager.Config()
        config.seenCapacity = 10
        config.fragmentCapacity = 5
        config.fileTransferCapacity = 4
        config.messageSyncIntervalSeconds = 1
        config.fragmentSyncIntervalSeconds = 1
        config.fileTransferSyncIntervalSeconds = 1
        config.maintenanceIntervalSeconds = 0

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let sender = try #require(Data(hexString: "1122334455667788"))
        let now = UInt64(Date().timeIntervalSince1970 * 1000)

        let announcePacket = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: now,
            payload: Data(),
            signature: nil,
            ttl: 1
        )
        let messagePacket = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: now,
            payload: Data([0x01]),
            signature: nil,
            ttl: 1
        )
        let fragmentPacket = BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: now,
            payload: Data([0xAA]),
            signature: nil,
            ttl: 1
        )
        let filePacket = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: now,
            payload: Data([0xBB]),
            signature: nil,
            ttl: 1,
            version: 2
        )

        manager.onPublicPacketSeen(announcePacket)
        manager.onPublicPacketSeen(messagePacket)
        manager.onPublicPacketSeen(fragmentPacket)
        manager.onPublicPacketSeen(filePacket)

        manager._performMaintenanceSynchronously(now: Date())

        // One request per due schedule so each type group gets the full
        // filter capacity: publicMessages, fragment, and fileTransfer.
        let sentPackets = delegate.packets
        #expect(sentPackets.count == 3)
        let decoded = sentPackets.compactMap { RequestSyncPacket.decode(from: $0.payload) }
        #expect(decoded.count == 3)
        let allTypes = decoded.compactMap(\.types).reduce(SyncTypeFlags(rawValue: 0)) { $0.union($1) }
        #expect(allTypes.contains(.announce))
        #expect(allTypes.contains(.message))
        #expect(allTypes.contains(.fragment))
        #expect(allTypes.contains(.fileTransfer))
        #expect(decoded.contains { $0.types == .publicMessages })
        #expect(decoded.contains { $0.types == .fragment })
        #expect(decoded.contains { $0.types == .fileTransfer })
    }

    @Test func truncatedFilterCarriesSinceCursor() throws {
        var config = GossipSyncManager.Config()
        config.seenCapacity = 100
        config.gcsMaxBytes = 32 // caps the filter at 28 IDs (256 bits / 9 bits per element)
        config.messageSyncIntervalSeconds = 1
        config.fragmentSyncIntervalSeconds = 0
        config.fileTransferSyncIntervalSeconds = 0
        config.maintenanceIntervalSeconds = 0

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let sender = try #require(Data(hexString: "1122334455667788"))
        let baseTimestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let totalMessages = 40
        for i in 0..<totalMessages {
            let packet = BitchatPacket(
                type: MessageType.message.rawValue,
                senderID: sender,
                recipientID: nil,
                timestamp: baseTimestamp + UInt64(i),
                payload: Data([UInt8(truncatingIfNeeded: i)]),
                signature: nil,
                ttl: 1
            )
            manager.onPublicPacketSeen(packet)
        }

        manager._performMaintenanceSynchronously(now: Date())

        let packet = try #require(delegate.packets.first)
        let request = try #require(RequestSyncPacket.decode(from: packet.payload))
        // The store (40) exceeds what the tiny filter can cover, so a cursor
        // must be present. It points at the oldest timestamp the filter
        // actually encodes: the filter covers the newest ~28, and byte-budget
        // trimming can only shrink that further, so the cursor sits at or
        // above baseTimestamp + 12 (= 40 - 28) and below the newest message.
        let since = try #require(request.sinceTimestamp)
        #expect(since >= baseTimestamp + 12)
        #expect(since < baseTimestamp + UInt64(totalMessages))
    }

    @Test func fullCoverageFilterOmitsSinceCursor() throws {
        var config = GossipSyncManager.Config()
        config.seenCapacity = 100
        config.messageSyncIntervalSeconds = 1
        config.fragmentSyncIntervalSeconds = 0
        config.fileTransferSyncIntervalSeconds = 0
        config.maintenanceIntervalSeconds = 0

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let sender = try #require(Data(hexString: "1122334455667788"))
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data([0x01]),
            signature: nil,
            ttl: 1
        )
        manager.onPublicPacketSeen(packet)

        manager._performMaintenanceSynchronously(now: Date())

        let sent = try #require(delegate.packets.first)
        let request = try #require(RequestSyncPacket.decode(from: sent.payload))
        #expect(request.sinceTimestamp == nil)
    }

    @Test func handleRequestSyncHonorsSinceCursorButAlwaysSendsAnnounces() async throws {
        var config = GossipSyncManager.Config()
        config.seenCapacity = 5
        config.messageSyncIntervalSeconds = 0
        config.fragmentSyncIntervalSeconds = 0
        config.fileTransferSyncIntervalSeconds = 0

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let sender = try #require(Data(hexString: "aabbccddeeff0011"))
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        // Announce older than the cursor: must still be sent (identity is
        // needed to verify everything else).
        let announcePacket = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: nowMs - 50_000,
            payload: Data(),
            signature: nil,
            ttl: 1
        )
        let oldMessage = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: nowMs - 60_000,
            payload: Data([0x01]),
            signature: nil,
            ttl: 1
        )
        let newMessage = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: nowMs,
            payload: Data([0x02]),
            signature: nil,
            ttl: 1
        )

        manager.onPublicPacketSeen(announcePacket)
        manager.onPublicPacketSeen(oldMessage)
        manager.onPublicPacketSeen(newMessage)

        let peer = PeerID(str: "FFFFFFFFFFFFFFFF")
        let request = RequestSyncPacket(
            p: 7,
            m: 1,
            data: Data(),
            types: .publicMessages,
            sinceTimestamp: nowMs - 30_000
        )
        manager.handleRequestSync(from: peer, request: request)

        try await TestHelpers.waitFor({ delegate.packets.count == 2 }, timeout: TestConstants.shortTimeout)
        // Barrier: flush the sync queue so a late third packet would be visible.
        manager._performMaintenanceSynchronously(now: Date())
        let sentPackets = delegate.packets
        #expect(sentPackets.count == 2)
        #expect(sentPackets.contains { $0.type == MessageType.announce.rawValue })
        let sentMessages = sentPackets.filter { $0.type == MessageType.message.rawValue }
        #expect(sentMessages.count == 1)
        #expect(sentMessages.first?.payload == Data([0x02]))
        #expect(sentPackets.allSatisfy { $0.isRSR })
    }

    @Test func handleRequestSyncSkipsAnnounceAlreadyInFilter() async throws {
        var config = GossipSyncManager.Config()
        config.messageSyncIntervalSeconds = 0
        config.fragmentSyncIntervalSeconds = 0
        config.fileTransferSyncIntervalSeconds = 0

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let sender = try #require(Data(hexString: "aabbccddeeff0011"))
        let announcePacket = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(),
            signature: nil,
            ttl: 1
        )
        manager.onPublicPacketSeen(announcePacket)

        // A filter that already contains the announce's canonical ID must
        // suppress the response — this only holds if the responder recomputes
        // the ID the same way the filter was built (the dual-path bug would
        // diff a stored hex string instead).
        let announceID = PacketIdUtil.computeId(announcePacket)
        let params = GCSFilter.buildFilter(ids: [announceID], maxBytes: 256, targetFpr: 0.01)
        let request = RequestSyncPacket(p: params.p, m: params.m, data: params.data, types: .announce)

        let peer = PeerID(str: "FFFFFFFFFFFFFFFF")
        manager.handleRequestSync(from: peer, request: request)
        // Barrier: the async handler is enqueued, so this sync flush runs after it.
        manager._performMaintenanceSynchronously(now: Date())
        #expect(delegate.packets.isEmpty)
    }

    @Test func handleRequestSyncIsRateLimitedPerPeer() async throws {
        var config = GossipSyncManager.Config()
        config.seenCapacity = 5
        config.messageSyncIntervalSeconds = 0
        config.fragmentSyncIntervalSeconds = 0
        config.fileTransferSyncIntervalSeconds = 0
        config.responseRateLimitMaxResponses = 1
        config.responseRateLimitWindowSeconds = 60

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let sender = try #require(Data(hexString: "aabbccddeeff0011"))
        let messagePacket = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data([0x10]),
            signature: nil,
            ttl: 1
        )
        manager.onPublicPacketSeen(messagePacket)

        let peer = PeerID(str: "FFFFFFFFFFFFFFFF")
        let request = RequestSyncPacket(p: 7, m: 1, data: Data(), types: .message)
        manager.handleRequestSync(from: peer, request: request)
        manager.handleRequestSync(from: peer, request: request)

        try await TestHelpers.waitFor({ delegate.packets.count >= 1 }, timeout: TestConstants.shortTimeout)
        // Barrier: both requests have been processed once this returns.
        manager._performMaintenanceSynchronously(now: Date())
        #expect(delegate.packets.count == 1)
    }

    @Test func initialSyncCoalescesEnabledTypes() async throws {
        var config = GossipSyncManager.Config()
        config.seenCapacity = 10
        config.fragmentCapacity = 5
        config.fileTransferCapacity = 4
        config.fragmentSyncIntervalSeconds = 1
        config.fileTransferSyncIntervalSeconds = 1

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        manager.scheduleInitialSyncToPeer(PeerID(str: "FFFFFFFFFFFFFFFF"), delaySeconds: 0.0)

        try await TestHelpers.waitFor({ delegate.packets.count == 1 }, timeout: TestConstants.shortTimeout)
        let packet = try #require(delegate.packets.first)
        let request = try #require(RequestSyncPacket.decode(from: packet.payload))
        let types = try #require(request.types)
        #expect(types.contains(.announce))
        #expect(types.contains(.message))
        #expect(types.contains(.fragment))
        #expect(types.contains(.fileTransfer))
    }

    @Test func handleRequestSyncHonorsTypeFilter() async throws {
        var config = GossipSyncManager.Config()
        config.seenCapacity = 5
        config.fragmentCapacity = 5
        config.fileTransferCapacity = 0
        config.messageSyncIntervalSeconds = 0
        config.fragmentSyncIntervalSeconds = 0
        config.fileTransferSyncIntervalSeconds = 0

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let sender = try #require(Data(hexString: "aabbccddeeff0011"))
        let now = UInt64(Date().timeIntervalSince1970 * 1000)

        let messagePacket = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: now,
            payload: Data([0x10]),
            signature: nil,
            ttl: 1
        )

        let fragmentPacket = BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: now,
            payload: Data([0x20]),
            signature: nil,
            ttl: 1
        )

        manager.onPublicPacketSeen(messagePacket)
        manager.onPublicPacketSeen(fragmentPacket)

        let peer = PeerID(str: "FFFFFFFFFFFFFFFF")
        let request = RequestSyncPacket(p: 4, m: 1, data: Data(), types: .fragment)
        manager.handleRequestSync(from: peer, request: request)

        try await TestHelpers.waitFor({ delegate.packets.count == 1 }, timeout: TestConstants.shortTimeout)
        let sentPackets = delegate.packets
        #expect(sentPackets.count == 1)
        #expect(sentPackets[0].type == MessageType.fragment.rawValue)
    }

    // MARK: - Fragment-ID filter (targeted resync)

    private func makeFragmentPacket(sender: Data, fragmentID: Data, index: UInt16, timestamp: UInt64) -> BitchatPacket {
        // Fragment payload: 8-byte stream ID + index + total + original type.
        var payload = fragmentID
        payload.append(contentsOf: withUnsafeBytes(of: index.bigEndian) { Data($0) })
        payload.append(contentsOf: withUnsafeBytes(of: UInt16(4).bigEndian) { Data($0) })
        payload.append(MessageType.fileTransfer.rawValue)
        payload.append(Data([0xEE]))
        return BitchatPacket(
            type: MessageType.fragment.rawValue,
            senderID: sender,
            recipientID: nil,
            timestamp: timestamp,
            payload: payload,
            signature: nil,
            ttl: 1
        )
    }

    @Test func handleRequestSyncHonorsFragmentIdFilter() async throws {
        var config = GossipSyncManager.Config()
        config.fragmentCapacity = 10
        config.messageSyncIntervalSeconds = 0
        config.fragmentSyncIntervalSeconds = 0
        config.fileTransferSyncIntervalSeconds = 0

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let sender = try #require(Data(hexString: "aabbccddeeff0011"))
        let wantedID = try #require(Data(hexString: "0102030405060708"))
        let otherID = try #require(Data(hexString: "1112131415161718"))
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        let wanted = makeFragmentPacket(sender: sender, fragmentID: wantedID, index: 1, timestamp: nowMs - 60_000)
        let other = makeFragmentPacket(sender: sender, fragmentID: otherID, index: 2, timestamp: nowMs)
        manager.onPublicPacketSeen(wanted)
        manager.onPublicPacketSeen(other)

        // The since-cursor sits after both fragments; without the filter the
        // responder would send nothing for `wanted`. The filter both bypasses
        // the cursor and restricts the diff to exactly the named stream.
        let request = RequestSyncPacket(
            p: 7,
            m: 1,
            data: Data(),
            types: .fragment,
            sinceTimestamp: nowMs + 1,
            fragmentIdFilter: RequestSyncPacket.encodeFragmentIdFilter([wantedID])
        )
        manager.handleRequestSync(from: PeerID(str: "FFFFFFFFFFFFFFFF"), request: request)

        try await TestHelpers.waitFor({ delegate.packets.count == 1 }, timeout: TestConstants.shortTimeout)
        // Barrier: flush the sync queue so a late second packet would be visible.
        manager._performMaintenanceSynchronously(now: Date())
        let sentPackets = delegate.packets
        #expect(sentPackets.count == 1)
        let sent = try #require(sentPackets.first)
        #expect(sent.type == MessageType.fragment.rawValue)
        #expect(sent.payload.prefix(8) == wantedID)
        #expect(sent.ttl == 0)
        #expect(sent.isRSR)
    }

    @Test func requestMissingFragmentsSendsFilteredRequestToConnectedPeers() async throws {
        var config = GossipSyncManager.Config()
        config.messageSyncIntervalSeconds = 0
        config.fragmentSyncIntervalSeconds = 0
        config.fileTransferSyncIntervalSeconds = 0

        let requestSyncManager = RequestSyncManager()
        let manager = GossipSyncManager(myPeerID: myPeerID, config: config, requestSyncManager: requestSyncManager)
        let delegate = RecordingDelegate()
        delegate.connectedPeers = [PeerID(str: "FFFFFFFFFFFFFFFF")]
        manager.delegate = delegate

        let stalledID = try #require(Data(hexString: "0102030405060708"))
        manager.requestMissingFragments(fragmentIDs: [stalledID])

        try await TestHelpers.waitFor({ delegate.packets.count == 1 }, timeout: TestConstants.shortTimeout)
        let sent = try #require(delegate.packets.first)
        #expect(sent.type == MessageType.requestSync.rawValue)
        #expect(sent.ttl == 0)
        let request = try #require(RequestSyncPacket.decode(from: sent.payload))
        #expect(request.types == .fragment)
        let ids = try #require(RequestSyncPacket.decodeFragmentIdFilter(request.fragmentIdFilter))
        #expect(ids == Set([stalledID]))
    }

    // MARK: - Archive persistence

    @Test func publicMessagesRestoreFromArchiveAcrossRestart() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gossip-archive-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let senderID = try #require(Data(hexString: "1122334455667788"))
        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: senderID,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data([0x01, 0x02]),
            signature: nil,
            ttl: 1
        )

        let first = GossipSyncManager(
            myPeerID: myPeerID,
            requestSyncManager: RequestSyncManager(),
            archive: GossipMessageArchive(fileURL: fileURL)
        )
        first.onPublicPacketSeen(packet)
        // Maintenance persists the dirty store to disk.
        first._performMaintenanceSynchronously(now: Date())
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        // "App restart": a fresh manager over the same archive re-serves it.
        let second = GossipSyncManager(
            myPeerID: myPeerID,
            requestSyncManager: RequestSyncManager(),
            archive: GossipMessageArchive(fileURL: fileURL)
        )
        let restored = await TestHelpers.waitUntil(
            { second._messageCount(for: PeerID(hexData: senderID)) == 1 },
            timeout: TestConstants.shortTimeout
        )
        #expect(restored)
    }

    @Test func archiveDropsMessagesOlderThanPublicWindow() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gossip-archive-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var config = GossipSyncManager.Config()
        config.publicMessageMaxAgeSeconds = 60

        let senderID = try #require(Data(hexString: "1122334455667788"))
        let stale = BitchatPacket(
            type: MessageType.message.rawValue,
            senderID: senderID,
            recipientID: nil,
            timestamp: UInt64((Date().timeIntervalSince1970 - 120) * 1000),
            payload: Data([0x01]),
            signature: nil,
            ttl: 1
        )
        let archive = GossipMessageArchive(fileURL: fileURL)
        archive.save([stale.toBinaryData(padding: false)!])

        let manager = GossipSyncManager(
            myPeerID: myPeerID,
            config: config,
            requestSyncManager: RequestSyncManager(),
            archive: archive
        )
        manager._performMaintenanceSynchronously(now: Date())
        #expect(manager._messageCount(for: PeerID(hexData: senderID)) == 0)
    }

}

private final class RecordingDelegate: GossipSyncManager.Delegate {
    var onSend: (() -> Void)?
    var connectedPeers: [PeerID] = []
    private(set) var lastPacket: BitchatPacket?
    private(set) var packets: [BitchatPacket] = []
    private let lock = NSLock()

    func sendPacket(_ packet: BitchatPacket) {
        lock.lock()
        lastPacket = packet
        packets.append(packet)
        lock.unlock()
        onSend?()
    }

    func sendPacket(to peerID: PeerID, packet: BitchatPacket) {
        sendPacket(packet)
    }

    func signPacketForBroadcast(_ packet: BitchatPacket) -> BitchatPacket {
        packet
    }
    
    func getConnectedPeers() -> [PeerID] {
        return connectedPeers
    }
}
