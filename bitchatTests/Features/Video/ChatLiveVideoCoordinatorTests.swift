//
// ChatLiveVideoCoordinatorTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

@MainActor
private final class MockLiveVideoContext: ChatLiveVoiceContext {
    var nickname = "me"
    var myPeerID = PeerID(str: "0102030405060708")
    var selectedPrivateChatPeer: PeerID?
    var isViewingPublicMeshTimeline = false
    var blockedPeers: Set<PeerID> = []

    private(set) var handledPrivateMessages: [BitchatMessage] = []
    private(set) var appendedPublicMessages: [BitchatMessage] = []
    private(set) var upsertedMessages: [(message: BitchatMessage, peerID: PeerID)] = []
    private(set) var upsertedPublicMessages: [BitchatMessage] = []
    private(set) var removedMessageIDs: [String] = []
    private(set) var sentReadReceipts: [(receipt: ReadReceipt, peerID: PeerID)] = []
    private var readReceiptMessageIDs: Set<String> = []

    func isPeerBlocked(_ peerID: PeerID) -> Bool { blockedPeers.contains(peerID) }
    func resolveNickname(for peerID: PeerID) -> String { "alice" }
    func handlePrivateMessage(_ message: BitchatMessage) { handledPrivateMessages.append(message) }
    func appendPublicMeshMessage(_ message: BitchatMessage) { appendedPublicMessages.append(message) }
    func upsertPrivateMessage(_ message: BitchatMessage, in peerID: PeerID) { upsertedMessages.append((message, peerID)) }
    func upsertPublicMeshMessage(_ message: BitchatMessage) { upsertedPublicMessages.append(message) }
    @discardableResult
    func removePrivateMessage(withID messageID: String) -> BitchatMessage? {
        removedMessageIDs.append(messageID)
        return nil
    }
    func hasSentReadReceipt(_ messageID: String) -> Bool { readReceiptMessageIDs.contains(messageID) }
    func markReadReceiptSent(_ messageID: String) -> Bool { readReceiptMessageIDs.insert(messageID).inserted }
    func sendMeshReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) { sentReadReceipts.append((receipt, peerID)) }
    func removeMessage(withID messageID: String, cleanupFile: Bool) { removedMessageIDs.append(messageID) }
    func setActivePublicVoiceTalker(_ nickname: String?) {}
    func notifyUIChanged() {}
}

private final class LockedPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []

    func append(_ packet: Data) { lock.withLock { packets.append(packet) } }

    func take() -> [Data] {
        lock.withLock {
            defer { packets.removeAll() }
            return packets
        }
    }
}

/// Encodes a short synthetic clip once and keeps its access units, so the
/// coordinator tests feed real H.264 through the full receive path.
private enum SyntheticH264 {
    static let units: [LiveVideoEncodedFrame] = {
        let source = LiveVideoSyntheticSource(width: 144, height: 192, fps: 8, audioEnabled: false)
        guard let encoder = try? LiveVideoH264Encoder(width: 144, height: 192, fps: 8, bitrate: 60_000, keyframeIntervalSeconds: 1) else {
            return []
        }
        let lock = NSLock()
        var frames: [LiveVideoEncodedFrame] = []
        encoder.onFrame = { frame in lock.withLock { frames.append(frame) } }
        for index in 0..<16 {
            if let buffer = source.makeFrame(index: index) {
                encoder.encode(buffer, ptsUs: Int64(index) * 125_000)
            }
        }
        encoder.finish()
        Thread.sleep(forTimeInterval: 0.2)
        encoder.invalidate()
        return lock.withLock { frames }.sorted { $0.ptsUs < $1.ptsUs }
    }()
}

@MainActor
struct ChatLiveVideoCoordinatorTests {
    private let peer = PeerID(str: "aaaabbbbcccc0001")
    private let otherPeer = PeerID(str: "aaaabbbbcccc0002")
    private let config = LiveVideoConfig(videoCodec: .h264AnnexB, width: 144, height: 192, fps: 8, bitrateKbps: 18, audioCodec: .none)

    private func makeStore() throws -> (store: BLEIncomingFileStore, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-store-\(UUID().uuidString)", isDirectory: true)
        return (BLEIncomingFileStore(baseDirectory: base), { try? FileManager.default.removeItem(at: base) })
    }

    private func packets(streamID: Data, units: [LiveVideoEncodedFrame], end: Bool) -> [Data] {
        let packetizer = VideoStreamPacketizer(streamID: streamID, config: config, fec: LiveVideoQuality.low.fec)
        var packets = packetizer.start()
        for unit in units {
            let ms = unit.ptsUs / 1_000
            packets += packetizer.add(LiveMediaUnit(track: .video, ptsMs: ms, keyframe: unit.keyframe, data: unit.annexB), nowMs: ms)
        }
        if end {
            packets += packetizer.finish(durationMs: 2_000, nowMs: 2_000)
        }
        return packets
    }

    private func deliver(_ packets: [Data], to coordinator: ChatLiveVideoCoordinator, from peerID: PeerID, publicMesh: Bool = false) {
        for packet in packets {
            if publicMesh {
                coordinator.handlePublicVideoFramePayload(from: peerID, nickname: "alice", payload: packet, timestamp: Date())
            } else {
                coordinator.handleVideoFramePayload(from: peerID, payload: packet, timestamp: Date())
            }
        }
    }

    @Test func streamOpensOneLiveBubbleAndBoostsTheLink() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let context = MockLiveVideoContext()
        var boosts = 0
        let coordinator = ChatLiveVideoCoordinator(context: context, fileStore: store, linkBoost: { boosts += $0 ? 1 : -1 }, sweepsOnInit: false)
        let streamID = Data(repeating: 0x11, count: 8)

        deliver(packets(streamID: streamID, units: Array(SyntheticH264.units.prefix(4)), end: false), to: coordinator, from: peer)

        #expect(context.handledPrivateMessages.count == 1)
        let bubble = try #require(context.handledPrivateMessages.first)
        #expect(bubble.content.hasPrefix("[video] video_live_1111111111111111_"))
        #expect(coordinator.isLiveVideoMessage(bubble))
        #expect(coordinator.streamModel(forMessageID: bubble.id) != nil)
        #expect(boosts == 1)
        coordinator.resetForPanic()
        #expect(boosts == 0)
    }

    @Test func canceledStreamRemovesItsBubbleAndNeverReopens() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let context = MockLiveVideoContext()
        let coordinator = ChatLiveVideoCoordinator(context: context, fileStore: store, sweepsOnInit: false)
        let streamID = Data(repeating: 0x22, count: 8)
        let packetizer = VideoStreamPacketizer(streamID: streamID, config: config, fec: LiveVideoQuality.low.fec)

        deliver(packetizer.start(), to: coordinator, from: peer, publicMesh: true)
        let bubble = try #require(context.appendedPublicMessages.first)
        deliver([try #require(packetizer.cancel())], to: coordinator, from: peer, publicMesh: true)

        #expect(context.removedMessageIDs == [bubble.id])
        #expect(!coordinator.isLiveVideoMessage(bubble))
        deliver(packetizer.start(), to: coordinator, from: peer, publicMesh: true)
        #expect(context.appendedPublicMessages.count == 1)
    }

    @Test func blockedPeersAndForgedPacketsAreIgnored() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let context = MockLiveVideoContext()
        context.blockedPeers = [peer]
        let coordinator = ChatLiveVideoCoordinator(context: context, fileStore: store, sweepsOnInit: false)

        deliver(packets(streamID: Data(repeating: 0x33, count: 8), units: [], end: false), to: coordinator, from: peer)
        deliver([Data(repeating: 0xFF, count: 40)], to: coordinator, from: otherPeer)

        #expect(context.handledPrivateMessages.isEmpty)
    }

    @Test func sameStreamIDFromAnotherPeerOpensItsOwnBubble() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let context = MockLiveVideoContext()
        let coordinator = ChatLiveVideoCoordinator(context: context, fileStore: store, sweepsOnInit: false)
        let streamID = Data(repeating: 0x44, count: 8)

        deliver(packets(streamID: streamID, units: [], end: false), to: coordinator, from: peer)
        deliver(packets(streamID: streamID, units: [], end: false), to: coordinator, from: otherPeer)

        #expect(context.handledPrivateMessages.count == 2)
        coordinator.resetForPanic()
    }

    @Test func endedStreamKeepsItsReconstructionAndAbsorbsTheFinalFile() throws {
        let units = SyntheticH264.units
        try #require(units.count >= 8 && units.first?.keyframe == true)
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let context = MockLiveVideoContext()
        let coordinator = ChatLiveVideoCoordinator(context: context, fileStore: store, sweepsOnInit: false)
        let streamID = Data([0x0A, 0x0B, 0x0C, 0x0D, 0x01, 0x02, 0x03, 0x04])

        deliver(packets(streamID: streamID, units: units, end: true), to: coordinator, from: peer)

        let bubble = try #require(context.handledPrivateMessages.first)
        #expect(!coordinator.isLiveVideoMessage(bubble))
        let republished = try #require(context.upsertedMessages.last?.message)
        #expect(republished.id == bubble.id)
        #expect(republished.content.hasPrefix("[video] video_rx_0a0b0c0d01020304_"))
        let fileName = String(republished.content.dropFirst("[video] ".count))
        let reconstruction = try store.incomingDirectory(subdirectory: "videos/incoming").appendingPathComponent(fileName)
        #expect(FileManager.default.fileExists(atPath: reconstruction.path))

        // The sender's finalized file replaces the reconstruction in place,
        // adopting the sender's deterministic DM message ID.
        let finalized = BitchatMessage(
            id: "FINAL-ID",
            sender: "alice",
            content: "[video] video_0a0b0c0d01020304.mp4",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "me",
            senderPeerID: peer
        )
        #expect(coordinator.absorbFinalizedVideo(finalized))
        #expect(context.upsertedMessages.last?.message.id == "FINAL-ID")
        #expect(context.removedMessageIDs.contains(bubble.id))
        #expect(!FileManager.default.fileExists(atPath: reconstruction.path))
        // A second copy is an ordinary message again.
        #expect(!coordinator.absorbFinalizedVideo(finalized))
    }

    /// Sender session → paced packets → receiving coordinator: the whole
    /// live path except the radio, with video and audio.
    @Test func sendSessionLoopsBackIntoAPlayableReconstruction() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("video-out-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outbox) }
        let context = MockLiveVideoContext()
        let coordinator = ChatLiveVideoCoordinator(context: context, fileStore: store, sweepsOnInit: false)
        let sent = LockedPackets()
        let target = LiveVideoTarget(send: { sent.append($0) }, backlog: { 0 }, packetBudgetPerSecond: 300, linkBoost: { _ in })
        let session = LiveVideoSendSession(outputDirectory: outbox, target: target, quality: .low, audioEnabled: true)
        try await session.start()

        let source = LiveVideoSyntheticSource(width: 144, height: 192, fps: 8, audioEnabled: true)
        let encoder = try #require(PTTFrameEncoder())
        for index in 0..<20 {
            if let frame = source.makeFrame(index: index) { session.offerVideo(frame) }
            if let tone = source.makeToneBuffer(startSample: Int64(index) * 2_000, frameCount: 2_000) {
                session.offerAudio(encoder.encode(tone))
            }
            try await Task.sleep(nanoseconds: 125_000_000)
            for packet in sent.take() {
                coordinator.handleVideoFramePayload(from: peer, payload: packet, timestamp: Date())
            }
        }
        let recording = try #require(await session.stop(canceled: false))
        for packet in sent.take() {
            coordinator.handleVideoFramePayload(from: peer, payload: packet, timestamp: Date())
        }

        #expect(recording.lastPathComponent == LiveVideoSendSession.fileName(for: session.streamID))
        let stats = session.currentStats()
        #expect(stats.framesEncoded >= 15)
        #expect(stats.staleDropped == 0)
        let bubble = try #require(context.handledPrivateMessages.first)
        #expect(!coordinator.isLiveVideoMessage(bubble), "END should have finished the stream")
        let republished = try #require(context.upsertedMessages.last?.message)
        let fileName = String(republished.content.dropFirst("[video] ".count))
        let reconstruction = try store.incomingDirectory(subdirectory: "videos/incoming").appendingPathComponent(fileName)
        let loaded = await VideoPosterLoader.load(url: reconstruction)
        #expect(loaded.poster != nil)
        #expect(loaded.durationSeconds > 1.5)
    }

    @Test func finalizedFileFromAnotherSenderIsNotAbsorbed() throws {
        #expect(ChatLiveVideoCoordinator.streamID(fromVideoFileName: "video_0a0b0c0d01020304.mp4") == "0a0b0c0d01020304")
        #expect(ChatLiveVideoCoordinator.streamID(fromVideoFileName: "video_live_0a0b0c0d01020304.mp4") == nil)
        #expect(ChatLiveVideoCoordinator.streamID(fromVideoFileName: "video_rx_0a0b0c0d01020304_x.mp4") == nil)
        #expect(ChatLiveVideoCoordinator.streamID(fromVideoFileName: "clip_abcd.mp4") == nil)

        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let context = MockLiveVideoContext()
        let coordinator = ChatLiveVideoCoordinator(context: context, fileStore: store, sweepsOnInit: false)
        let foreign = BitchatMessage(
            sender: "mallory",
            content: "[video] video_0a0b0c0d01020304.mp4",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "me",
            senderPeerID: otherPeer
        )
        #expect(!coordinator.absorbFinalizedVideo(foreign))
    }
}
