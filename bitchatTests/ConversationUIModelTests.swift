//
// ConversationUIModelTests.swift
// bitchatTests
//
// "Is this row mine?" drives the message list: the context-menu actions,
// the jump to the bottom on my own send, DM delivery status, the verified
// seal and which media directory a row loads from. The answer must come from
// the sender ID a row carries, never from its display name, which namesakes
// share by design (geochat shows everyone as nick#<pubkey suffix>).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// A chat stack with a known mesh peer ID and an isolated location manager,
/// so no other test's channel selection leaks in.
@MainActor
private func makeChatViewModel(nickname: String) -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let transport = MockTransport()
    transport.myPeerID = ConversationUIModelTests.myPeerID
    let suiteName = "ConversationUIModelTests.\(UUID().uuidString)"
    let storage = UserDefaults(suiteName: suiteName) ?? .standard
    storage.removePersistentDomain(forName: suiteName)
    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
        identityManager: MockIdentityManager(keychain),
        transport: transport,
        locationManager: LocationChannelManager(storage: storage)
    )
    viewModel.nickname = nickname
    return (viewModel, transport)
}

/// The UI model mirrors the nickname a runloop turn late, so a test that
/// renames builds a fresh one; that keeps the rename test meaningful against
/// a helper that compares names.
@MainActor
private func makeUIModel(for viewModel: ChatViewModel) -> ConversationUIModel {
    let privateConversationModel = PrivateConversationModel(
        chatViewModel: viewModel,
        conversations: viewModel.conversations,
        locationChannelsModel: LocationChannelsModel(manager: viewModel.locationManager)
    )
    return ConversationUIModel(
        chatViewModel: viewModel,
        privateConversationModel: privateConversationModel,
        conversations: viewModel.conversations
    )
}

private func row(
    _ sender: String,
    _ senderPeerID: PeerID?,
    content: String = "hi",
    isPrivate: Bool = false,
    deliveryStatus: DeliveryStatus? = nil,
    isBridged: Bool = false
) -> BitchatMessage {
    BitchatMessage(
        sender: sender,
        content: content,
        timestamp: Date(),
        isRelay: false,
        isPrivate: isPrivate,
        senderPeerID: senderPeerID,
        deliveryStatus: deliveryStatus,
        isBridged: isBridged
    )
}

/// `hex` with its first `count` characters changed. Changing the first 8
/// gives a different geochat sender ID (`nostr:` + 8 hex) while the last 4,
/// the display suffix, stay the same.
private func altered(_ hex: String, first count: Int) -> String {
    String(hex.prefix(count).map { $0 == "0" ? "1" : "0" }) + hex.dropFirst(count)
}

struct ConversationUIModelTests {
    static let myPeerID = PeerID(str: "a1b2c3d4e5f60718")
    static let peerID = PeerID(str: "0f1e2d3c4b5a6978")
    static let geohash = "u4pruy"
    static let locationChannel = ChannelID.location(GeohashChannel(level: .city, geohash: geohash))

    @MainActor
    private static func show(geohash: String, in viewModel: ChatViewModel) {
        viewModel.activeChannel = .location(GeohashChannel(level: .city, geohash: geohash))
    }

    /// Switches channels the way the channel picker does: through the
    /// location manager, which the view model follows a few hops later.
    /// Tests that await must switch this way, since the view model re-applies
    /// the manager's selection on a later turn and would undo a direct
    /// `activeChannel` write. Returns once the UI model has mirrored the
    /// switch (media is off in location channels), so no channel update
    /// queued before it can still reach the memo.
    @MainActor
    private static func switchAndSettle(to channel: ChannelID, in viewModel: ChatViewModel, uiModel: ConversationUIModel) async -> Bool {
        viewModel.locationManager.select(channel)
        let mediaAllowed = channel == .mesh
        return await TestHelpers.waitUntil({
            viewModel.activeChannel == channel && uiModel.canSendMediaInCurrentContext == mediaAllowed
        }, timeout: TestConstants.settleTimeout)
    }

    @MainActor
    private static func myGeoHex(_ viewModel: ChatViewModel, geohash: String = ConversationUIModelTests.geohash) throws -> String {
        try viewModel.idBridge.deriveIdentity(forGeohash: geohash).publicKeyHex
    }

    @Test @MainActor
    func geochatNamesakesAreNotMine() throws {
        let (viewModel, _) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        Self.show(geohash: Self.geohash, in: viewModel)
        let myHex = try Self.myGeoHex(viewModel)
        let theirHex = altered(myHex, first: 64)
        let twinHex = altered(myHex, first: 8)

        // My own row, as ChatOutgoingCoordinator.sendGeohashPublicMessage stamps it.
        #expect(uiModel.isSentByCurrentUser(row("alice#\(myHex.suffix(4))", PeerID(nostr: myHex))))
        // Another "alice": same name, different key.
        #expect(!uiModel.isSentByCurrentUser(row("alice#\(theirHex.suffix(4))", PeerID(nostr: theirHex))))
        // Even a display string identical to mine, down to the 4-hex suffix.
        #expect(!uiModel.isSentByCurrentUser(row("alice#\(myHex.suffix(4))", PeerID(nostr: twinHex))))
    }

    @Test @MainActor
    func anonReaderDoesNotOwnAnonymousStrangers() throws {
        let (viewModel, _) = makeChatViewModel(nickname: "anon")
        let uiModel = makeUIModel(for: viewModel)
        Self.show(geohash: Self.geohash, in: viewModel)
        let myHex = try Self.myGeoHex(viewModel)
        let strangerHex = altered(myHex, first: 64)
        let strangerName = "anon#\(strangerHex.suffix(4))"

        // Geochat and sampled senders without an n tag
        // (displayNameForNostrPubkey, GeoPresenceTracker.cooldownPerGeohash).
        #expect(!uiModel.isSentByCurrentUser(row(strangerName, PeerID(nostr: strangerHex))))
        // A bridged sender without one (BridgeService.classify).
        #expect(!uiModel.isSentByCurrentUser(row(strangerName, PeerID(bridge: strangerHex), isBridged: true)))
        // A geo DM from an unnamed stranger, delivered to me.
        #expect(!uiModel.isSentByCurrentUser(row(
            strangerName,
            PeerID(nostr_: strangerHex),
            isPrivate: true,
            deliveryStatus: .delivered(to: "anon", at: Date())
        )))
        // My own geochat row is still mine.
        #expect(uiModel.isSentByCurrentUser(row("anon#\(myHex.suffix(4))", PeerID(nostr: myHex))))
    }

    @Test @MainActor
    func meshAndGroupNamesakesAreNotMine() {
        let (viewModel, _) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        let namesakeRows = [
            // Public text, suffixed while the namesake is connected
            // (BLEPeerSenderDisplayName.collisionResolvedName)...
            row("alice#\(Self.peerID.id.prefix(4))", Self.peerID),
            // ...and by its bare signed name otherwise
            // (BLEService.signedSenderDisplayName).
            row("alice", Self.peerID),
            // A DM; received DMs keep the default .sending status.
            row("alice", Self.peerID, isPrivate: true),
            // A courier-opened DM, keyed by the sender's full Noise key.
            row("alice", PeerID(hexData: Data((0..<32).map(UInt8.init))), isPrivate: true),
            // A group member with my name (ChatGroupCoordinator.handleGroupMessagePayload).
            row("alice", PeerID(str: "f00dfacecafebeef"), isPrivate: true)
        ]
        for message in namesakeRows {
            #expect(!uiModel.isSentByCurrentUser(message), "\(message.sender) from \(message.senderPeerID?.id ?? "nil")")
        }
    }

    @Test @MainActor
    func ownRowsOnEveryPathStayMineAcrossARename() throws {
        let (viewModel, _) = makeChatViewModel(nickname: "alice")
        let myHex = try Self.myGeoHex(viewModel)
        let me = Self.myPeerID
        // Each row as its construction site stamps it.
        let ownRows = [
            // Mesh text and the wave (ChatOutgoingCoordinator.sendMeshPublicMessage).
            row("alice", me, content: "mesh text"),
            // Gossip self-replay and the archived echo restored at launch
            // (ChatTransportEventCoordinator.handlePublicMessage,
            // ChatViewModelBootstrapper.loadArchivedEchoes).
            BitchatMessage(id: "echo-0011", sender: "alice", content: "archived echo", timestamp: Date(), isRelay: false, senderPeerID: me),
            // Mesh DM (ChatPrivateConversationCoordinator.sendPrivateMessage).
            row("alice", me, content: "mesh dm", isPrivate: true, deliveryStatus: .delivered(to: "bob", at: Date())),
            // Geo DM: plain nickname, mesh ID (ChatPrivateConversationCoordinator.sendGeohashDM).
            row("alice", me, content: "geo dm", isPrivate: true, deliveryStatus: .sent),
            // Group message (ChatGroupCoordinator.sendGroupMessage).
            row("alice", me, content: "group message", isPrivate: true, deliveryStatus: .sent),
            // Voice note (ChatMediaTransferCoordinator.enqueueMediaMessage).
            row("alice", me, content: "[voice] note.m4a", isPrivate: true, deliveryStatus: .sending),
            // Geochat text and its relay echo
            // (ChatOutgoingCoordinator.sendGeohashPublicMessage, NostrInboundPipeline).
            row("alice#\(myHex.suffix(4))", PeerID(nostr: myHex), content: "geochat text")
        ]

        let uiModel = makeUIModel(for: viewModel)
        Self.show(geohash: Self.geohash, in: viewModel)
        for message in ownRows {
            #expect(uiModel.isSentByCurrentUser(message), "\(message.content) from \(message.senderPeerID?.id ?? "nil")")
        }

        // A rename changes no sender ID: everything I sent stays mine.
        viewModel.nickname = "alicia"
        let renamedUIModel = makeUIModel(for: viewModel)
        for message in ownRows {
            #expect(renamedUIModel.isSentByCurrentUser(message), "\(message.content) from \(message.senderPeerID?.id ?? "nil")")
        }
    }

    @Test @MainActor
    func systemLinesAndRowsWithoutASenderIDAreNeverMine() throws {
        let (viewModel, _) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        Self.show(geohash: Self.geohash, in: viewModel)
        let myHex = try Self.myGeoHex(viewModel)

        // DM command output and the screenshot notice carry my mesh ID
        // (ChatViewModel.addLocalPrivateSystemMessage,
        // ChatLifecycleCoordinator.appendPrivateScreenshotNotice); counting
        // them as mine would pull a scrolled-up reader down.
        #expect(!uiModel.isSentByCurrentUser(row("system", Self.myPeerID, isPrivate: true)))
        // A converted emote keeps its author's ID
        // (ChatPrivateConversationCoordinator.processActionMessage).
        #expect(!uiModel.isSentByCurrentUser(row("system", PeerID(nostr: myHex))))
        // Public system lines carry no sender ID...
        #expect(!uiModel.isSentByCurrentUser(row("system", nil)))
        // ...and a name alone never makes a row mine.
        #expect(!uiModel.isSentByCurrentUser(row("alice", nil)))
    }

    @Test @MainActor
    func mediaRowsLoadFromTheDirectionTheirSenderIDNames() throws {
        let (viewModel, _) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        let namesakeImage = row(
            "alice",
            Self.peerID,
            content: "[image] theirs.jpg",
            isPrivate: true,
            deliveryStatus: .delivered(to: "alice", at: Date())
        )
        // Sent before I renamed myself from "al" to "alice".
        let myImage = row("al", Self.myPeerID, content: "[image] mine.jpg", isPrivate: true, deliveryStatus: .sent)

        // A namesake's image is received media: blurred, deletable, no Cancel.
        #expect(!uiModel.isMediaMessageFromCurrentUser(namesakeImage))
        guard case .image(let theirURL)? = uiModel.mediaAttachment(for: namesakeImage) else {
            Issue.record("Expected the namesake's image to resolve to an image row")
            return
        }
        #expect(theirURL.deletingLastPathComponent().path.hasSuffix("/images/incoming"))

        #expect(uiModel.isMediaMessageFromCurrentUser(myImage))
        guard case .image(let myURL)? = uiModel.mediaAttachment(for: myImage) else {
            Issue.record("Expected my image to resolve to an image row")
            return
        }
        #expect(myURL.deletingLastPathComponent().path.hasSuffix("/images/outgoing"))
    }

    @Test @MainActor
    func verifiedNamesakeKeepsTheSealOnTheirDMs() {
        let (viewModel, transport) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        transport.peerFingerprints[Self.peerID] = "namesake-fingerprint"
        viewModel.peerIdentityStore.setVerified("namesake-fingerprint", verified: true)

        // The seal is what tells a verified "alice" from an impersonator.
        #expect(uiModel.showsVerifiedSeal(for: row("alice", Self.peerID, isPrivate: true)))
        #expect(!uiModel.showsVerifiedSeal(for: row("alice", Self.myPeerID, isPrivate: true)))
    }

    @Test @MainActor
    func geochatOwnershipFollowsTheChannelOnScreen() throws {
        let (viewModel, _) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        let hexA = try Self.myGeoHex(viewModel, geohash: "u4pruy")
        let hexB = try Self.myGeoHex(viewModel, geohash: "9q8yy")
        let fromA = row("alice#\(hexA.suffix(4))", PeerID(nostr: hexA))
        let fromB = row("alice#\(hexB.suffix(4))", PeerID(nostr: hexB))

        Self.show(geohash: "u4pruy", in: viewModel)
        #expect(uiModel.isSentByCurrentUser(fromA))
        #expect(!uiModel.isSentByCurrentUser(fromB))

        // Read from the store right after the switch, with no runloop turn.
        // A row of my geohash-A identity shown in B renders as a stranger
        // (ChatMessageFormatter.formatMessageAsText) and is treated as one.
        Self.show(geohash: "9q8yy", in: viewModel)
        #expect(uiModel.isSentByCurrentUser(fromB))
        #expect(!uiModel.isSentByCurrentUser(fromA))

        viewModel.activeChannel = .mesh
        #expect(!uiModel.isSentByCurrentUser(fromA))
        #expect(!uiModel.isSentByCurrentUser(fromB))
    }

    @Test @MainActor
    func switchingToMeshDropsMyMemoizedGeochatSender() async throws {
        let (viewModel, _) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        #expect(await Self.switchAndSettle(to: Self.locationChannel, in: viewModel, uiModel: uiModel))
        let myHex = try Self.myGeoHex(viewModel)
        #expect(uiModel.isSentByCurrentUser(row("alice#\(myHex.suffix(4))", PeerID(nostr: myHex))))
        #expect(uiModel.ownGeoChatSender?.peerID == PeerID(nostr: myHex))

        // No row on #mesh reads it, so it goes with the switch rather than
        // whenever a geochat row next renders.
        #expect(await Self.switchAndSettle(to: .mesh, in: viewModel, uiModel: uiModel))
        #expect(uiModel.ownGeoChatSender == nil)
    }

    @Test @MainActor
    func panicWipeRetiresTheOldGeochatIdentity() async throws {
        let (viewModel, _) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        #expect(await Self.switchAndSettle(to: Self.locationChannel, in: viewModel, uiModel: uiModel))
        let oldHex = try Self.myGeoHex(viewModel)
        let beforeWipe = row("alice#\(oldHex.suffix(4))", PeerID(nostr: oldHex))
        #expect(uiModel.isSentByCurrentUser(beforeWipe))
        #expect(uiModel.ownGeoChatSender != nil)

        // The wipe reseeds every geohash identity and returns to the mesh,
        // which takes the retired key out of the memo too.
        viewModel.panicClearAllData()
        #expect(await TestHelpers.waitUntil({ uiModel.ownGeoChatSender == nil }, timeout: TestConstants.settleTimeout))
        Self.show(geohash: Self.geohash, in: viewModel)
        let newHex = try Self.myGeoHex(viewModel)
        #expect(newHex != oldHex)

        #expect(uiModel.isSentByCurrentUser(row("\(viewModel.nickname)#\(newHex.suffix(4))", PeerID(nostr: newHex))))
        #expect(!uiModel.isSentByCurrentUser(beforeWipe))
    }

    // MARK: - Rows from the real send paths

    // With no nickname fallback, a send path that forgets to stamp the sender
    // ID turns my own row into a stranger's. Each test below sends the way the
    // composer does, through the UI model's `sendMessage(_:)` and
    // `sendVoiceNote(at:)`, and asks the UI model about the row that send
    // produced.

    @MainActor
    private static func publicRow(_ content: String, in channel: ChannelID, of viewModel: ChatViewModel) -> BitchatMessage? {
        viewModel.conversations.conversationsByID[ConversationID(channelID: channel)]?.messages.first { $0.content == content }
    }

    @MainActor
    private static func privateRow(_ content: String, with peerID: PeerID, of viewModel: ChatViewModel) -> BitchatMessage? {
        viewModel.privateChats[peerID]?.first { $0.content == content }
    }

    /// A voice note to send. Any bytes do: the voice-note path checks only
    /// the file's size.
    private static func makeVoiceNote() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try Data("voice payload".utf8).write(to: url, options: .atomic)
        return url
    }

    @Test @MainActor
    func myMeshPublicSendIsMine() throws {
        let (viewModel, transport) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)

        uiModel.sendMessage("hello mesh")

        #expect(transport.sentMessages.map(\.content) == ["hello mesh"])
        let sent = try #require(Self.publicRow("hello mesh", in: .mesh, of: viewModel))
        #expect(uiModel.isSentByCurrentUser(sent))
    }

    @Test @MainActor
    func myMeshDMIsMine() throws {
        let (viewModel, transport) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        transport.connectedPeers.insert(Self.peerID)
        transport.peerNicknames[Self.peerID] = "bob"

        viewModel.startPrivateChat(with: Self.peerID)
        uiModel.sendMessage("hi bob")

        #expect(transport.sentPrivateMessages.map(\.content) == ["hi bob"])
        let sent = try #require(Self.privateRow("hi bob", with: Self.peerID, of: viewModel))
        #expect(uiModel.isSentByCurrentUser(sent))
    }

    @Test @MainActor
    func myGeoDMIsMine() async throws {
        let (viewModel, _) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        #expect(await Self.switchAndSettle(to: Self.locationChannel, in: viewModel, uiModel: uiModel))
        let stranger = try NostrIdentity.generate()
        let conversation = PeerID(nostr_: stranger.publicKeyHex)
        viewModel.registerNostrKeyMapping(stranger.publicKeyHex, for: conversation)

        viewModel.startPrivateChat(with: conversation)
        uiModel.sendMessage("hi stranger")

        let sent = try #require(Self.privateRow("hi stranger", with: conversation, of: viewModel))
        // Handed to the Nostr transport, not failed on the way there.
        #expect(sent.deliveryStatus == .sent)
        #expect(uiModel.isSentByCurrentUser(sent))
    }

    @Test @MainActor
    func myGeochatPublicSendIsMine() async throws {
        let (viewModel, _) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        #expect(await Self.switchAndSettle(to: Self.locationChannel, in: viewModel, uiModel: uiModel))
        let myHex = try Self.myGeoHex(viewModel)

        uiModel.sendMessage("hello geohash")

        // The echo lands once its NIP-13 nonce is mined off the main actor.
        #expect(await TestHelpers.waitUntil(
            { Self.publicRow("hello geohash", in: Self.locationChannel, of: viewModel) != nil },
            timeout: TestConstants.settleTimeout
        ))
        let sent = try #require(Self.publicRow("hello geohash", in: Self.locationChannel, of: viewModel))
        #expect(sent.senderPeerID == PeerID(nostr: myHex))
        #expect(uiModel.isSentByCurrentUser(sent))
    }

    @Test @MainActor
    func myVoiceNoteOnMeshIsMine() async throws {
        let (viewModel, transport) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        let note = try Self.makeVoiceNote()
        defer { try? FileManager.default.removeItem(at: note) }

        uiModel.sendVoiceNote(at: note)

        // The row is enqueued at once; wait out the detached preparation so
        // the send has finished before the test does.
        #expect(await TestHelpers.waitUntil({ transport.sentBroadcastFiles.count == 1 }, timeout: TestConstants.settleTimeout))
        let sent = try #require(Self.publicRow("[voice] \(note.lastPathComponent)", in: .mesh, of: viewModel))
        #expect(uiModel.isSentByCurrentUser(sent))
    }

    @Test @MainActor
    func myVoiceNoteInADMIsMine() async throws {
        let (viewModel, transport) = makeChatViewModel(nickname: "alice")
        let uiModel = makeUIModel(for: viewModel)
        transport.connectedPeers.insert(Self.peerID)
        transport.peerNicknames[Self.peerID] = "bob"
        let note = try Self.makeVoiceNote()
        defer { try? FileManager.default.removeItem(at: note) }

        viewModel.startPrivateChat(with: Self.peerID)
        uiModel.sendVoiceNote(at: note)

        #expect(await TestHelpers.waitUntil({ transport.sentPrivateFiles.count == 1 }, timeout: TestConstants.settleTimeout))
        let sent = try #require(Self.privateRow("[voice] \(note.lastPathComponent)", with: Self.peerID, of: viewModel))
        #expect(uiModel.isSentByCurrentUser(sent))
    }
}
