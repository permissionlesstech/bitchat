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
    var isViewingPublicMeshTimeline = false
    var blockedPeers: Set<PeerID> = []

    private(set) var handledPrivateMessages: [BitchatMessage] = []
    private(set) var appendedPublicMessages: [BitchatMessage] = []
    private(set) var upsertedMessages: [(message: BitchatMessage, peerID: PeerID)] = []
    private(set) var upsertedPublicMessages: [BitchatMessage] = []
    private(set) var removedMessageIDs: [String] = []
    private(set) var talkerUpdates: [String?] = []

    func isPeerBlocked(_ peerID: PeerID) -> Bool { blockedPeers.contains(peerID) }
    func resolveNickname(for peerID: PeerID) -> String { "alice" }
    func handlePrivateMessage(_ message: BitchatMessage) { handledPrivateMessages.append(message) }
    func appendPublicMeshMessage(_ message: BitchatMessage) { appendedPublicMessages.append(message) }
    func upsertPrivateMessage(_ message: BitchatMessage, in peerID: PeerID) {
        upsertedMessages.append((message, peerID))
    }
    func upsertPublicMeshMessage(_ message: BitchatMessage) {
        upsertedPublicMessages.append(message)
    }
    @discardableResult
    func removePrivateMessage(withID messageID: String) -> BitchatMessage? {
        removedMessageIDs.append(messageID)
        return nil
    }
    func removeMessage(withID messageID: String, cleanupFile: Bool) {
        removedMessageIDs.append(messageID)
    }
    func setActivePublicVoiceTalker(_ nickname: String?) {
        if talkerUpdates.last ?? nil != nickname {
            talkerUpdates.append(nickname)
        }
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

    private func captureSuffix(burstID: Data, peerID: PeerID, scope: VoiceBurstScope) -> String {
        "\(burstID.hexEncodedString())_\(peerID.id)_\(scope == .directMessage ? "dm" : "mesh").aac"
    }

    /// Name of a capture still streaming in.
    private func liveCaptureName(burstID: Data, peerID: PeerID, scope: VoiceBurstScope = .directMessage) -> String {
        "voice_live_" + captureSuffix(burstID: burstID, peerID: peerID, scope: scope)
    }

    /// Name a finished capture is promoted to when it becomes the bubble's
    /// replayable fallback.
    private func fallbackName(burstID: Data, peerID: PeerID, scope: VoiceBurstScope = .directMessage) -> String {
        "voice_" + captureSuffix(burstID: burstID, peerID: peerID, scope: scope)
    }

    private func incomingFileURL(named name: String) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return base
            .appendingPathComponent("files/voicenotes/incoming", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func incomingFileURL(burstID: Data, peerID: PeerID, scope: VoiceBurstScope = .directMessage) -> URL? {
        incomingFileURL(named: liveCaptureName(burstID: burstID, peerID: peerID, scope: scope))
    }

    private func fallbackFileURL(burstID: Data, peerID: PeerID, scope: VoiceBurstScope = .directMessage) -> URL? {
        incomingFileURL(named: fallbackName(burstID: burstID, peerID: peerID, scope: scope))
    }

    /// Fresh store rooted in its own temp directory so quota/sweep tests
    /// never touch the shared application-support media directories.
    private func makeTempStore() throws -> (store: BLEIncomingFileStore, incoming: URL, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptt-store-\(UUID().uuidString)", isDirectory: true)
        let store = BLEIncomingFileStore(baseDirectory: base)
        let incoming = try store.incomingDirectory(subdirectory: "voicenotes/incoming")
        return (store, incoming, { try? FileManager.default.removeItem(at: base) })
    }

    private func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func burstCreatesBubbleAndPersistsFramesInOrder() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)
        let burstID = makeBurstID(0xA1)
        defer { fallbackFileURL(burstID: burstID, peerID: peer).map { try? FileManager.default.removeItem(at: $0) } }

        let frame1 = Data(repeating: 0x01, count: 60)
        let frame2 = Data(repeating: 0x02, count: 60)

        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)
        #expect(context.handledPrivateMessages.count == 1)
        let bubble = try #require(context.handledPrivateMessages.first)
        #expect(bubble.isPrivate)
        #expect(bubble.senderPeerID == peer)
        #expect(bubble.content == "[voice] voice_live_\(burstID.hexEncodedString())_\(peer.id)_dm.aac")
        #expect(coordinator.isLiveVoiceMessage(bubble))

        // Deliver out of order: seq 2 buffers behind the seq-1 hole, then
        // seq 1 releases both in order.
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .frames([frame2]))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([frame1]))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 3, kind: .end(totalDataPackets: 2, durationMs: 128))), to: coordinator, from: peer)

        // The finished capture is promoted off its voice_live_ name.
        let url = try #require(fallbackFileURL(burstID: burstID, peerID: peer))
        let written = try Data(contentsOf: url)
        var expected = ADTSFramer.frame(frame1)
        expected.append(ADTSFramer.frame(frame2))
        #expect(written == expected)
        let liveURL = try #require(incomingFileURL(burstID: burstID, peerID: peer))
        #expect(!FileManager.default.fileExists(atPath: liveURL.path))

        // Burst ended: no longer live, bubble republished pointing at the
        // promoted file.
        #expect(!coordinator.isLiveVoiceMessage(bubble))
        let republished = try #require(context.upsertedMessages.last { $0.message.id == bubble.id })
        #expect(republished.message.content == "[voice] \(fallbackName(burstID: burstID, peerID: peer))")
        #expect(context.removedMessageIDs.isEmpty)
    }

    @Test func absorbsFinalizedNoteIntoLiveBubble() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)
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
        // The promoted partial capture is deleted in favor of the note.
        let url = try #require(fallbackFileURL(burstID: burstID, peerID: peer))
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // Absorption is one-shot.
        #expect(!coordinator.absorbFinalizedVoiceNote(note))
    }

    @Test func absorbIgnoresUnrelatedVoiceNotes() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)

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
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)
        let burstID = makeBurstID(0xC3)

        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data(repeating: 9, count: 40)]))), to: coordinator, from: peer)
        let bubble = try #require(context.handledPrivateMessages.first)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .canceled)), to: coordinator, from: peer)

        #expect(context.removedMessageIDs == [bubble.id])
        let url = try #require(incomingFileURL(burstID: burstID, peerID: peer))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!coordinator.isLiveVoiceMessage(bubble))
    }

    @Test func emptyBurstLeavesNoBubble() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)
        let burstID = makeBurstID(0xD4)

        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)
        let bubble = try #require(context.handledPrivateMessages.first)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .end(totalDataPackets: 0, durationMs: 0))), to: coordinator, from: peer)

        // Nothing audible arrived: the placeholder bubble is withdrawn.
        #expect(context.removedMessageIDs == [bubble.id])
    }

    @Test func ignoresBlockedPeersAndUnknownControlPackets() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)

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
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)

        var cleanup: [Data] = []
        defer {
            for burstID in cleanup {
                incomingFileURL(burstID: burstID, peerID: peer).map { try? FileManager.default.removeItem(at: $0) }
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

    @Test func liveVoiceToggleOffDropsInboundFrames() throws {
        let previous = PTTSettings.liveVoiceEnabled
        PTTSettings.liveVoiceEnabled = false
        defer { PTTSettings.liveVoiceEnabled = previous }

        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)
        let burstID = makeBurstID(0xE8)

        // Off means classic-notes-only: no live bubble, no partial file.
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data(repeating: 5, count: 40)]))), to: coordinator, from: peer)
        #expect(context.handledPrivateMessages.isEmpty)
        let url = try #require(incomingFileURL(burstID: burstID, peerID: peer))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func publicBurstCreatesMeshBubbleAndTracksTalker() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)
        let burstID = makeBurstID(0x71)
        defer {
            incomingFileURL(burstID: burstID, peerID: peer, scope: .publicMesh).map { try? FileManager.default.removeItem(at: $0) }
            fallbackFileURL(burstID: burstID, peerID: peer, scope: .publicMesh).map { try? FileManager.default.removeItem(at: $0) }
        }

        func sendPublic(_ packet: VoiceBurstPacket) {
            coordinator.handlePublicVoiceFramePayload(from: peer, nickname: "bob", payload: packet.encode(), timestamp: Date())
        }

        sendPublic(try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono))))
        sendPublic(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data(repeating: 3, count: 50)]))))

        // Bubble appends straight to the mesh store with the verified
        // nickname, and the floor-courtesy indicator names the talker.
        #expect(context.handledPrivateMessages.isEmpty)
        let bubble = try #require(context.appendedPublicMessages.first)
        #expect(!bubble.isPrivate)
        #expect(bubble.sender == "bob")
        #expect(context.talkerUpdates.last == "bob")

        sendPublic(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .end(totalDataPackets: 1, durationMs: 64))))
        // Burst over: talker cleared, bubble republished into the mesh store.
        #expect(context.talkerUpdates.last == .some(nil))
        #expect(context.upsertedPublicMessages.contains { $0.id == bubble.id })

        // The broadcast finalized note absorbs into the same bubble.
        let note = BitchatMessage(
            sender: "bob", content: "[voice] voice_\(burstID.hexEncodedString()).m4a", timestamp: Date(),
            isRelay: false, isPrivate: false, senderPeerID: peer
        )
        #expect(coordinator.absorbFinalizedVoiceNote(note))
        let replacement = try #require(context.upsertedPublicMessages.last)
        #expect(replacement.id == bubble.id)
        #expect(replacement.content == note.content)
        #expect(!replacement.isPrivate)
    }

    @Test func absorbEnforcesScopeBinding() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)
        let burstID = makeBurstID(0x72)
        defer { fallbackFileURL(burstID: burstID, peerID: peer).map { try? FileManager.default.removeItem(at: $0) } }

        // A DM burst...
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data(repeating: 4, count: 40)]))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .end(totalDataPackets: 1, durationMs: 64))), to: coordinator, from: peer)

        // ...must not be replaced by a *public* note claiming the same burst.
        let publicNote = BitchatMessage(
            sender: "alice", content: "[voice] voice_\(burstID.hexEncodedString()).m4a", timestamp: Date(),
            isRelay: false, isPrivate: false, senderPeerID: peer
        )
        #expect(!coordinator.absorbFinalizedVoiceNote(publicNote))
    }

    @Test func burstIDParsingFromFileNames() {
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "voice_00112233445566ff.m4a") == Data(hexString: "00112233445566ff"))
        // Uniquified copies keep the leading hex run.
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "voice_00112233445566ff (1).m4a") == Data(hexString: "00112233445566ff"))
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "voice_20260708_120000.m4a") == nil)
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "voice_live_00112233445566ff.aac") == nil)
        // Per-peer, per-scope live capture names must stay unabsorbable too.
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "voice_live_00112233445566ff_aaaabbbbcccc0001.aac") == nil)
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "voice_live_00112233445566ff_aaaabbbbcccc0001_dm.aac") == nil)
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "voice_live_00112233445566ff_aaaabbbbcccc0001_mesh.aac") == nil)
        #expect(ChatLiveVoiceCoordinator.burstID(fromVoiceFileName: "other.m4a") == nil)
    }

    @Test func collidingBurstIDFromAnotherPeerCannotHijackAssembly() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)
        let burstID = makeBurstID(0x73)
        let attacker = PeerID(str: "ddddeeeeffff0002")
        defer {
            fallbackFileURL(burstID: burstID, peerID: peer).map { try? FileManager.default.removeItem(at: $0) }
            incomingFileURL(burstID: burstID, peerID: attacker).map { try? FileManager.default.removeItem(at: $0) }
        }

        // The victim starts a burst; the attacker races a START reusing the
        // observed burst ID from a different peer.
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: attacker)

        // Two distinct bubbles on two distinct files — no capture.
        #expect(context.handledPrivateMessages.count == 2)
        let victimBubble = try #require(context.handledPrivateMessages.first)
        let attackerBubble = try #require(context.handledPrivateMessages.last)
        #expect(victimBubble.id != attackerBubble.id)
        #expect(victimBubble.content != attackerBubble.content)

        // The victim's frames still land in the victim's file, untouched by
        // the attacker's assembly.
        let victimFrame = Data(repeating: 0x0A, count: 60)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([victimFrame]))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .end(totalDataPackets: 1, durationMs: 64))), to: coordinator, from: peer)
        let victimURL = try #require(fallbackFileURL(burstID: burstID, peerID: peer))
        #expect(try Data(contentsOf: victimURL) == ADTSFramer.frame(victimFrame))
        let attackerURL = try #require(incomingFileURL(burstID: burstID, peerID: attacker))
        #expect((try? Data(contentsOf: attackerURL))?.isEmpty == true)
        #expect(!coordinator.isLiveVoiceMessage(victimBubble))
        #expect(coordinator.isLiveVoiceMessage(attackerBubble))
    }

    @Test func sameBurstIDCoexistsAcrossScopes() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)
        let burstID = makeBurstID(0x74)
        defer {
            fallbackFileURL(burstID: burstID, peerID: peer).map { try? FileManager.default.removeItem(at: $0) }
            fallbackFileURL(burstID: burstID, peerID: peer, scope: .publicMesh).map { try? FileManager.default.removeItem(at: $0) }
        }

        // A DM burst and a public burst reusing the same burst ID open
        // independent assemblies instead of colliding.
        let dmFrame = Data(repeating: 6, count: 50)
        let publicFrame = Data(repeating: 7, count: 50)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([dmFrame]))), to: coordinator, from: peer)
        coordinator.handlePublicVoiceFramePayload(
            from: peer,
            nickname: "bob",
            payload: try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([publicFrame]))).encode(),
            timestamp: Date()
        )
        #expect(context.handledPrivateMessages.count == 1)
        #expect(context.appendedPublicMessages.count == 1)
        let dmBubble = try #require(context.handledPrivateMessages.first)
        let publicBubble = try #require(context.appendedPublicMessages.first)

        // Ending the public burst leaves the DM assembly live.
        coordinator.handlePublicVoiceFramePayload(
            from: peer,
            nickname: "bob",
            payload: try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .end(totalDataPackets: 1, durationMs: 64))).encode(),
            timestamp: Date()
        )
        #expect(!coordinator.isLiveVoiceMessage(publicBubble))
        #expect(coordinator.isLiveVoiceMessage(dmBubble))

        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .end(totalDataPackets: 1, durationMs: 64))), to: coordinator, from: peer)
        #expect(!coordinator.isLiveVoiceMessage(dmBubble))

        // The scope in the file name keeps the two captures on distinct
        // paths: both survive with intact contents instead of one truncating
        // or deleting the other (both promoted off their live names by now).
        let dmURL = try #require(fallbackFileURL(burstID: burstID, peerID: peer))
        let publicURL = try #require(fallbackFileURL(burstID: burstID, peerID: peer, scope: .publicMesh))
        #expect(dmURL != publicURL)
        #expect(try Data(contentsOf: dmURL) == ADTSFramer.frame(dmFrame))
        #expect(try Data(contentsOf: publicURL) == ADTSFramer.frame(publicFrame))

        // Absorption still routes each note by its scope.
        let dmNote = BitchatMessage(
            sender: "alice", content: "[voice] voice_\(burstID.hexEncodedString()).m4a", timestamp: Date(),
            isRelay: false, isPrivate: true, recipientNickname: "me", senderPeerID: peer
        )
        #expect(coordinator.absorbFinalizedVoiceNote(dmNote))
        #expect(try #require(context.upsertedMessages.last).message.id == dmBubble.id)
    }

    @Test func finalizedNoteBindsToItsAuthenticatedSender() throws {
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, sweepsOnInit: false)
        let burstID = makeBurstID(0x75)
        let hex = burstID.hexEncodedString()
        let attacker = PeerID(str: "ddddeeeeffff0002")
        defer {
            fallbackFileURL(burstID: burstID, peerID: peer).map { try? FileManager.default.removeItem(at: $0) }
            fallbackFileURL(burstID: burstID, peerID: attacker).map { try? FileManager.default.removeItem(at: $0) }
        }

        // The attacker's colliding burst finishes FIRST, then the victim's.
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data(repeating: 1, count: 40)]))), to: coordinator, from: attacker)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .end(totalDataPackets: 1, durationMs: 64))), to: coordinator, from: attacker)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data(repeating: 2, count: 40)]))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .end(totalDataPackets: 1, durationMs: 64))), to: coordinator, from: peer)
        #expect(context.handledPrivateMessages.count == 2)
        let attackerBubble = try #require(context.handledPrivateMessages.first)
        let victimBubble = try #require(context.handledPrivateMessages.last)

        // The real sender's note absorbs into the real sender's bubble.
        let note = BitchatMessage(
            sender: "alice", content: "[voice] voice_\(hex).m4a", timestamp: Date(),
            isRelay: false, isPrivate: true, recipientNickname: "me", senderPeerID: peer
        )
        #expect(coordinator.absorbFinalizedVoiceNote(note))
        let replacement = try #require(context.upsertedMessages.last)
        #expect(replacement.message.id == victimBubble.id)
        #expect(replacement.peerID == peer)

        // The attacker's note can only ever claim the attacker's own bubble.
        let attackerNote = BitchatMessage(
            sender: "mallory", content: "[voice] voice_\(hex).m4a", timestamp: Date(),
            isRelay: false, isPrivate: true, recipientNickname: "me", senderPeerID: attacker
        )
        #expect(coordinator.absorbFinalizedVoiceNote(attackerNote))
        let attackerReplacement = try #require(context.upsertedMessages.last)
        #expect(attackerReplacement.message.id == attackerBubble.id)
        #expect(attackerReplacement.peerID == attacker)

        // Both registry entries are consumed — nothing left to hijack.
        #expect(!coordinator.absorbFinalizedVoiceNote(note))
    }

    @Test func liveBurstEnforcesIncomingMediaQuota() throws {
        let (store, incoming, cleanup) = try makeTempStore()
        defer { cleanup() }

        // Pre-seed enough finalized media that the burst's reservation pushes
        // usage over the 100 MB quota: the oldest file must be evicted.
        let oldURL = incoming.appendingPathComponent("voice_old.m4a")
        let newURL = incoming.appendingPathComponent("voice_new.m4a")
        try Data(count: 60 * 1024 * 1024).write(to: oldURL)
        try Data(count: 45 * 1024 * 1024).write(to: newURL)
        try setModificationDate(Date(timeIntervalSinceNow: -3600), at: oldURL)
        try setModificationDate(Date(timeIntervalSinceNow: -60), at: newURL)

        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, fileStore: store)
        let burstID = makeBurstID(0x76)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)

        // Oldest evicted, newer survivor + reservation fit under the quota,
        // and the capture file lives under the injected store's base.
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        let liveURL = incoming.appendingPathComponent(liveCaptureName(burstID: burstID, peerID: peer))
        #expect(FileManager.default.fileExists(atPath: liveURL.path))
        let remaining = try FileManager.default.contentsOfDirectory(at: incoming, includingPropertiesForKeys: [.fileSizeKey])
            .compactMap { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
        #expect(remaining + TransportConfig.pttMaxBurstBytes <= 100 * 1024 * 1024)
    }

    @Test func inFlightLiveCaptureIsNeverEvicted() throws {
        let (store, incoming, cleanup) = try makeTempStore()
        defer { cleanup() }

        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, fileStore: store)
        let burstID = makeBurstID(0x77)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data(repeating: 8, count: 60)]))), to: coordinator, from: peer)
        let liveURL = incoming.appendingPathComponent(liveCaptureName(burstID: burstID, peerID: peer))
        #expect(FileManager.default.fileExists(atPath: liveURL.path))

        // Make the streaming partial the LRU-oldest candidate, then blow the
        // quota and open a second burst to trigger eviction.
        try setModificationDate(Date(timeIntervalSinceNow: -7200), at: liveURL)
        let bigURL = incoming.appendingPathComponent("voice_big.m4a")
        try Data(count: 105 * 1024 * 1024).write(to: bigURL)
        send(try #require(VoiceBurstPacket(burstID: makeBurstID(0x78), seq: 0, kind: .start(codec: .aacLC16kMono))), to: coordinator, from: peer)

        // Eviction skipped the in-flight partial and deleted the big file.
        #expect(FileManager.default.fileExists(atPath: liveURL.path))
        #expect(!FileManager.default.fileExists(atPath: bigURL.path))
    }

    @Test func startupSweepRemovesStaleLiveCapturesOnly() throws {
        let (store, incoming, cleanup) = try makeTempStore()
        defer { cleanup() }

        // A partial capture orphaned by a previous session; a finalized note
        // and a promoted fallback capture that must both survive the sweep.
        let stale = incoming.appendingPathComponent("voice_live_00aa00aa00aa00aa_ddddeeeeffff0002_dm.aac")
        let finalized = incoming.appendingPathComponent("voice_00112233445566ff.m4a")
        let promoted = incoming.appendingPathComponent("voice_00bb00bb00bb00bb_ddddeeeeffff0002_dm.aac")
        try Data([0x01]).write(to: stale)
        try Data([0x02]).write(to: finalized)
        try Data([0x03]).write(to: promoted)

        let context = MockChatLiveVoiceContext()
        _ = ChatLiveVoiceCoordinator(context: context, fileStore: store)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: finalized.path))
        #expect(FileManager.default.fileExists(atPath: promoted.path))
    }

    @Test func finalizedFallbackSurvivesNextStartupSweep() throws {
        let (store, incoming, cleanup) = try makeTempStore()
        defer { cleanup() }

        // A burst finishes without its finalized note (live-only burst or
        // sender out of range): the capture is the row's only audio.
        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, fileStore: store)
        let burstID = makeBurstID(0x79)
        let frame = Data(repeating: 0x0B, count: 60)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([frame]))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .end(totalDataPackets: 1, durationMs: 64))), to: coordinator, from: peer)

        // The republished row points at the promoted (non-live) name, and
        // that file holds the burst's audio.
        let republished = try #require(context.upsertedMessages.last)
        #expect(republished.message.content == "[voice] \(fallbackName(burstID: burstID, peerID: peer))")
        let fallbackURL = incoming.appendingPathComponent(fallbackName(burstID: burstID, peerID: peer))
        #expect(try Data(contentsOf: fallbackURL) == ADTSFramer.frame(frame))

        // A later coordinator startup (same store) sweeps in-flight partials
        // only: the row's fallback audio must survive and stay playable.
        _ = ChatLiveVoiceCoordinator(context: MockChatLiveVoiceContext(), fileStore: store)
        #expect(try Data(contentsOf: fallbackURL) == ADTSFramer.frame(frame))
    }

    @Test func promotedFallbackIsQuotaEvictable() throws {
        let (store, incoming, cleanup) = try makeTempStore()
        defer { cleanup() }

        let context = MockChatLiveVoiceContext()
        let coordinator = ChatLiveVoiceCoordinator(context: context, fileStore: store)
        let burstID = makeBurstID(0x7A)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 1, kind: .frames([Data(repeating: 0x0C, count: 60)]))), to: coordinator, from: peer)
        send(try #require(VoiceBurstPacket(burstID: burstID, seq: 2, kind: .end(totalDataPackets: 1, durationMs: 64))), to: coordinator, from: peer)
        let fallbackURL = incoming.appendingPathComponent(fallbackName(burstID: burstID, peerID: peer))
        #expect(FileManager.default.fileExists(atPath: fallbackURL.path))

        // Once promoted, the capture is ordinary finalized media: as the
        // LRU-oldest file it is evicted, not skipped, when quota pressure
        // arrives.
        try setModificationDate(Date(timeIntervalSinceNow: -7200), at: fallbackURL)
        let bigURL = incoming.appendingPathComponent("voice_big.m4a")
        try Data(count: 105 * 1024 * 1024).write(to: bigURL)
        store.enforceQuota(reservingBytes: 0)

        #expect(!FileManager.default.fileExists(atPath: fallbackURL.path))
    }
}
