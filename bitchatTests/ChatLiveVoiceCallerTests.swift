import Testing
import Foundation
import BitFoundation
@testable import bitchat

@Suite(.serialized)
@MainActor
struct ChatLiveVoiceCallerTests {
    @Test(arguments: [VoiceBurstScope.publicMesh, .directMessage], [false, true])
    func finalizedNoteUsesConversationPipelineWithoutLateReopening(scope: VoiceBurstScope, hasFrames: Bool) throws {
        let keychain = MockKeychain()
        let transport = MockTransport()
        let peer = PeerID(str: "aaaabbbbcccc0001")
        transport.peerNicknames[peer] = "sender"
        let model = ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            transport: transport
        )
        // Keep autoplay inactive while exercising the real conversation stores.
        model.selectedPrivateChatPeer = PeerID(str: "ddddeeeeffff0002")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        model.liveVoiceCoordinator = ChatLiveVoiceCoordinator(
            context: model, fileStore: BLEIncomingFileStore(baseDirectory: root), sweepsOnInit: false
        )
        let enabled = UserDefaults.standard.object(forKey: "ptt.liveVoiceEnabled")
        PTTSettings.liveVoiceEnabled = true
        defer {
            model.liveVoiceCoordinator.resetForPanic()
            try? FileManager.default.removeItem(at: root)
            if let enabled { UserDefaults.standard.set(enabled, forKey: "ptt.liveVoiceEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "ptt.liveVoiceEnabled") }
        }
        let burst = Data([1, 0, 0, 0, 0, 0, 0, 0])
        func send(_ kind: VoiceBurstPacket.Kind, sequence: UInt16) throws {
            let packet = try #require(VoiceBurstPacket(burstID: burst, seq: sequence, kind: kind))
            if scope == .publicMesh {
                model.liveVoiceCoordinator.handlePublicVoiceFramePayload(
                    from: peer, nickname: "sender", payload: packet.encode(), timestamp: Date()
                )
            } else {
                model.liveVoiceCoordinator.handleVoiceFramePayload(from: peer, payload: packet.encode(), timestamp: Date())
            }
        }
        func rows() -> [BitchatMessage] {
            scope == .publicMesh ? model.messages.filter { $0.senderPeerID == peer } : model.privateChats[peer] ?? []
        }
        try send(.start(codec: .aacLC16kMono), sequence: 0)
        if hasFrames { try send(.frames([Data([1, 2, 3])]), sequence: 1) }
        let live = try #require(rows().first)
        #expect(model.liveVoiceCoordinator.isLiveVoiceMessage(live))
        let note = BitchatMessage(
            id: "synthetic-final-note", sender: "sender",
            content: "[voice] voice_0100000000000000.m4a", timestamp: Date(),
            isRelay: false, isPrivate: scope == .directMessage, senderPeerID: peer
        )
        if scope == .publicMesh {
            model.handlePublicMessage(note)
            model.publicMessagePipeline.flushIfNeeded()
        } else {
            model.handlePrivateMessage(note)
        }
        let stored = try #require(rows().first)
        #expect(rows().count == 1)
        #expect(stored.content == note.content)
        #expect(!model.liveVoiceCoordinator.isLiveVoiceMessage(stored))
        if scope == .directMessage || !hasFrames { #expect(stored.id == note.id) }
        // Snapshot the value: BitchatMessage is a reference type with mutable delivery status.
        let finalizedDeliveryStatus = stored.deliveryStatus
        let expectedTimestamp = hasFrames ? live.timestamp : note.timestamp
        if scope == .directMessage {
            // A delayed packet must not make a conversation unread again after it was read.
            model.markPrivateChatRead(peer)
        }
        func expectFinalizedState() throws {
            let current = try #require(rows().first)
            #expect(rows().map(\.id) == [stored.id])
            #expect(current.content == note.content)
            #expect(current.sender == note.sender)
            #expect(current.senderPeerID == peer)
            #expect(current.isPrivate == (scope == .directMessage))
            #expect(current.timestamp == expectedTimestamp)
            #expect(current.deliveryStatus == finalizedDeliveryStatus)
            #expect(!model.liveVoiceCoordinator.isLiveVoiceMessage(current))
            #expect(!model.liveVoiceCoordinator.isLiveVoiceMessage(live))
            if scope == .publicMesh {
                #expect(model.activePublicVoiceTalker == nil)
            } else {
                #expect(!model.unreadPrivateMessages.contains(peer))
            }
        }
        try expectFinalizedState()
        try send(.frames([Data([4, 5, 6])]), sequence: 2)
        model.publicMessagePipeline.flushIfNeeded()
        try expectFinalizedState()
        try send(.start(codec: .aacLC16kMono), sequence: 0)
        model.publicMessagePipeline.flushIfNeeded()
        try expectFinalizedState()
    }
}
