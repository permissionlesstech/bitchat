//
// ChatLiveVoiceCoordinatorTests.swift
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
private final class MockChatLiveVoiceContext: ChatLiveVoiceContext {
    var nickname = "me"
    var selectedPrivateChatPeer: PeerID?
    var blockedPeers: Set<PeerID> = []

    private(set) var handledPrivateMessages: [BitchatMessage] = []
    private(set) var upsertedMessages: [(message: BitchatMessage, peerID: PeerID)] = []
    private(set) var removedMessageIDs: [String] = []

    func isPeerBlocked(_ peerID: PeerID) -> Bool { blockedPeers.contains(peerID) }
    func resolveNickname(for peerID: PeerID) -> String { "alice" }
    func handlePrivateMessage(_ message: BitchatMessage) { handledPrivateMessages.append(message) }
    func upsertPrivateMessage(_ message: BitchatMessage, in peerID: PeerID) {
        upsertedMessages.append((message, peerID))
    }
    @discardableResult
    func removePrivateMessage(withID messageID: String) -> BitchatMessage? {
        removedMessageIDs.append(messageID)
        return nil
    }
    func notifyUIChanged() {}
}

@MainActor
struct ChatLiveVoiceCoordinatorTests {
    private let peer = PeerID(str: "aaaabbbbcccc0001")

    private func makeBurstID(_ fill: UInt8) -> Data {
        Data(repeating: fill, count: VoiceBurstPacket.burstIDSize)
    }

    private func send(_ packet: VoiceBurstPacket, to coordinator: ChatLiveVoiceCoordinator, from peerID: PeerID) {
        coordinator.handleVoiceFramePayload(from: peerID, payload: packet.encode(), timestamp: Date())
    }

    private func incomingFileURL(burstID: Data) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return base
            .appendingPathComponent("files/voicenotes/incoming", isDirectory: true)
            .appendingPathComponent("voice_live_\(burstID.hexEncodedString()).aac")
    }

    @Test func burstCreatesBubbleAndPersistsFramesInOrder() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context)
        let burstID = makeBurstID(0xA1)
        defer { incomingFileURL(burstID: burstID).map { try? FileManager.default.removeItem(at: $0) } }

        let frame1 = Data(repeating: 0x01, count: 60)
        let frame2 = Data(repeating: 0x02, count: 60)

        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)
        #expect(context.handledPrivateMessages.count == 1)
        let bubble = try #require(context.handledPrivateMessages.first)
        #expect(bubble.isPrivate)
        #expect(bubble.senderPeerID == peer)
        #expect(bubble.content == "[voice] voice_live_\(burstID.hexEncodedString()).aac")
        #expect(coordinator.isLiveVoiceMessage(bubble))

        // Deliver out of order: seq 2 buffers behind the seq-1 hole, then
        // seq 1 releases both in order.
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .frames([frame2]))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([frame1]))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 3, kind: .end(totalDataPackets: 2, durationMs: 128))), to: coordinator, from: peer)

        let url = try #require(incomingFileURL(burstID: burstID))
        let written = try Data(contentsOf: url)
        var expected = ADTSFramer.frame(frame1)
        expected.append(ADTSFramer.frame(frame2))
        #expect(written == expected)

        // Burst ended: no longer live, bubble republished for re-render.
        #expect(!coordinator.isLiveVoiceMessage(bubble))
        #expect(context.upsertedMessages.contains { $0.message.id == bubble.id })
        #expect(context.removedMessageIDs.isEmpty)
    }

    @Test func absorbsFinalizedNoteIntoLiveBubble() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context)
        let burstID = makeBurstID(0xB2)
        let hex = burstID.hexEncodedString()

        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data(repeating: 7, count: 50)]))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .end(totalDataPackets: 1, durationMs: 64))), to: coordinator, from: peer)
        let bubble = try #require(context.handledPrivateMessages.first)

        let note = BitchatMessage(
            sender: "alice",
            content: "[voice] voice_\(hex).m4a",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "me",
            senderPeerID: peer
        )
        #expect(coordinator.absorbFinalizedVoiceNote(note))

        // The note replaced the live bubble in place: same message ID, new
        // content, partial capture deleted.
        let replacement = try #require(context.upsertedMessages.last)
        #expect(replacement.message.id == bubble.id)
        #expect(replacement.message.content == note.content)
        #expect(replacement.peerID == peer)
        let url = try #require(incomingFileURL(burstID: burstID))
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // Absorption is one-shot.
        #expect(!coordinator.absorbFinalizedVoiceNote(note))
    }

    @Test func absorbIgnoresUnrelatedVoiceNotes() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context)

        // A classic voice note (date-stamped name) and a live-capture name
        // must both pass through untouched.
        let classic = BitchatMessage(
            sender: "alice", content: "[voice] voice_20260708_1201.m4a", timestamp: Date(),
            isRelay: false, isPrivate: true, recipientNickname: "me", senderPeerID: peer
        )
        #expect(!coordinator.absorbFinalizedVoiceNote(classic))
        let liveCapture = BitchatMessage(
            sender: "alice", content: "[voice] voice_live_aabbccdd00112233.aac", timestamp: Date(),
            isRelay: false, isPrivate: true, recipientNickname: "me", senderPeerID: peer
        )
        #expect(!coordinator.absorbFinalizedVoiceNote(liveCapture))
        // Unknown burst ID.
        let unknown = BitchatMessage(
            sender: "alice", content: "[voice] voice_ffffffffffffffff.m4a", timestamp: Date(),
            isRelay: false, isPrivate: true, recipientNickname: "me", senderPeerID: peer
        )
        #expect(!coordinator.absorbFinalizedVoiceNote(unknown))
    }

    @Test func canceledBurstRemovesBubbleAndFile() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context)
        let burstID = makeBurstID(0xC3)

        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data(repeating: 9, count: 40)]))), to: coordinator, from: peer)
        let bubble = try #require(context.handledPrivateMessages.first)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .canceled)), to: coordinator, from: peer)

        #expect(context.removedMessageIDs == [bubble.id])
        let url = try #require(incomingFileURL(burstID: burstID))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!coordinator.isLiveVoiceMessage(bubble))
    }

    @Test func emptyBurstLeavesNoBubble() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context)
        let burstID = makeBurstID(0xD4)

        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)
        let bubble = try #require(context.handledPrivateMessages.first)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .end(totalDataPackets: 0, durationMs: 0))), to: coordinator, from: peer)

        // Nothing audible arrived: the placeholder bubble is withdrawn.
        #expect(context.removedMessageIDs == [bubble.id])
    }

    @Test func ignoresBlockedPeersAndUnknownControlPackets() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context)

        context.blockedPeers = [peer]
        send(try #require(VoiceBurstPacket(burstID: makeBurstID(0xE5), seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)
        #expect(context.handledPrivateMessages.isEmpty)

        context.blockedPeers = []
        // END/CANCELED for a burst that never started must not create state.
        send(try #require(VoiceBurstPacket(burstID: makeBurstID(0xE6), seq: 5, kind: .end(totalDataPackets: 4, durationMs: 256))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: makeBurstID(0xE7), seq: 5, kind: .canceled)), to: coordinator, from: peer)
        #expect(context.handledPrivateMessages.isEmpty)
    }

    @Test func concurrentAssemblyCapDropsExtraBursts() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context)

        var cleanup: [Data] = []
        defer {
            for burstID in cleanup {
                incomingFileURL(burstID: burstID).map { try? FileManager.default.removeItem(at: $0) }
            }
        }
        for i in 0..<TransportConfig.pttMaxConcurrentAssemblies {
            let burstID = makeBurstID(UInt8(0x10 + i))
            cleanup.append(burstID)
            send(try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)
        }
        #expect(context.handledPrivateMessages.count == TransportConfig.pttMaxConcurrentAssemblies)

        send(try #require(VoiceBurstPacket(burstID: makeBurstID(0xFF), seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)
        #expect(context.handledPrivateMessages.count == TransportConfig.pttMaxConcurrentAssemblies)
    }

    @Test func burstIDParsingFromFileNames() {
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "voice_00112233445566ff.m4a") == Data(hexString: "00112233445566ff"))
        // Uniquified copies keep the leading hex run.
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "voice_00112233445566ff (1).m4a") == Data(hexString: "00112233445566ff"))
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "voice_20260708_120000.m4a") == nil)
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "voice_live_00112233445566ff.aac") == nil)
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "other.m4a") == nil)
    }
}
