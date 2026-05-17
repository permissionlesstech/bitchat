import Foundation
import Testing
import BitFoundation
@testable import bitchat

@Suite(.serialized)
struct CommandProcessorTests {

    @MainActor
    @Test func slapNotFoundGrammar() {
        let identityManager = MockIdentityManager(MockKeychain())
        let processor = CommandProcessor(contextProvider: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/slap @system")
        switch result {
        case .error(let message):
            #expect(message == "cannot slap system: not found")
        default:
            Issue.record("Expected error result")
        }
    }

    @MainActor
    @Test func hugNotFoundGrammar() {
        let identityManager = MockIdentityManager(MockKeychain())
        let processor = CommandProcessor(contextProvider: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/hug @system")
        switch result {
        case .error(let message):
            #expect(message == "cannot hug system: not found")
        default:
            Issue.record("Expected error result")
        }
    }
    
    @MainActor
    @Test func slapUsageMessage() {
        let identityManager = MockIdentityManager(MockKeychain())
        let processor = CommandProcessor(contextProvider: nil, meshService: nil, identityManager: identityManager)
        let result = processor.process("/slap")
        switch result {
        case .error(let message):
            #expect(message == "usage: /slap <nickname>")
        default:
            Issue.record("Expected error result for usage message")
        }
    }

    @MainActor
    @Test func msgStartsPrivateChatAndSendsMessage() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let context = MockCommandContextProvider()
        let peerID = PeerID(str: "abcd1234abcd1234")
        context.nicknameToPeerID["alice"] = peerID
        let processor = CommandProcessor(contextProvider: context, meshService: nil, identityManager: identityManager)

        let result = await withSelectedChannel(.mesh) {
            processor.process("/msg @alice hello there")
        }

        switch result {
        case .success(let message):
            #expect(message == "started private chat with alice")
        default:
            Issue.record("Expected success result")
        }
        #expect(context.startedPrivateChats == [peerID])
        #expect(context.sentPrivateMessages.count == 1)
        #expect(context.sentPrivateMessages.first?.content == "hello there")
        #expect(context.sentPrivateMessages.first?.peerID == peerID)
    }

    @MainActor
    @Test func whoInMeshListsSortedPeerNicknames() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let transport = MockTransport()
        transport.peerNicknames = [
            PeerID(str: "b"): "bob",
            PeerID(str: "a"): "alice"
        ]
        let processor = CommandProcessor(contextProvider: MockCommandContextProvider(), meshService: transport, identityManager: identityManager)

        let result = await withSelectedChannel(.mesh) {
            processor.process("/who")
        }

        switch result {
        case .success(let message):
            #expect(message == "online: alice, bob")
        default:
            Issue.record("Expected success result")
        }
    }

    @MainActor
    @Test func whoInGeohashListsVisibleParticipantsExcludingSelf() async throws {
        let bridge = NostrIdentityBridge(keychain: MockKeychain())
        let identityManager = MockIdentityManager(MockKeychain())
        let context = MockCommandContextProvider(idBridge: bridge)
        let geohash = "u4pruy"
        let selfPubkey = try bridge.deriveIdentity(forGeohash: geohash).publicKeyHex.lowercased()
        context.visibleGeoParticipants = [
            CommandGeoParticipant(id: selfPubkey, displayName: "me"),
            CommandGeoParticipant(id: String(repeating: "b", count: 64), displayName: "bob")
        ]
        let processor = CommandProcessor(contextProvider: context, meshService: MockTransport(), identityManager: identityManager)
        let channel = ChannelID.location(GeohashChannel(level: .city, geohash: geohash))

        let result = await withSelectedChannel(channel) {
            processor.process("/who")
        }

        switch result {
        case .success(let message):
            #expect(message == "online: bob")
        default:
            Issue.record("Expected success result")
        }
    }

    @MainActor
    @Test func clearInPrivateChatRemovesOnlySelectedConversation() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let context = MockCommandContextProvider()
        let activePeer = PeerID(str: "active")
        let otherPeer = PeerID(str: "other")
        context.selectedPrivateChatPeer = activePeer
        context.privateChats = [
            activePeer: [makeMessage(sender: "alice", content: "secret")],
            otherPeer: [makeMessage(sender: "bob", content: "keep")]
        ]
        let processor = CommandProcessor(contextProvider: context, meshService: nil, identityManager: identityManager)

        let result = await withSelectedChannel(.mesh) {
            processor.process("/clear")
        }

        switch result {
        case .handled:
            break
        default:
            Issue.record("Expected handled result")
        }
        #expect(context.privateChats[activePeer] == [])
        #expect(context.privateChats[otherPeer]?.count == 1)
    }

    @MainActor
    @Test func clearInPublicChatClearsTimeline() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let context = MockCommandContextProvider()
        let processor = CommandProcessor(contextProvider: context, meshService: nil, identityManager: identityManager)

        let result = await withSelectedChannel(.mesh) {
            processor.process("/clear")
        }

        switch result {
        case .handled:
            break
        default:
            Issue.record("Expected handled result")
        }
        #expect(context.clearCurrentPublicTimelineCallCount == 1)
    }

    @MainActor
    @Test func hugInPrivateChatSendsPersonalizedMessageAndLocalEcho() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let context = MockCommandContextProvider(nickname: "me")
        let transport = MockTransport()
        let peerID = PeerID(str: "abcd1234abcd1234")
        context.selectedPrivateChatPeer = peerID
        context.nicknameToPeerID["bob"] = peerID
        transport.peerNicknames[peerID] = "Bob"
        let processor = CommandProcessor(contextProvider: context, meshService: transport, identityManager: identityManager)

        let result = await withSelectedChannel(.mesh) {
            processor.process("/hug @bob")
        }

        switch result {
        case .handled:
            break
        default:
            Issue.record("Expected handled result")
        }
        #expect(transport.sentPrivateMessages.count == 1)
        #expect(transport.sentPrivateMessages.first?.content == "* 🫂 me hugs you *")
        #expect(context.localPrivateSystemMessages.first?.content == "🫂 you hugged bob")
        #expect(context.localPrivateSystemMessages.first?.peerID == peerID)
    }

    @MainActor
    @Test func slapInPublicChatSendsPublicRawAndEcho() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let context = MockCommandContextProvider(nickname: "me")
        let peerID = PeerID(str: "abcd1234abcd1234")
        context.nicknameToPeerID["bob"] = peerID
        let processor = CommandProcessor(contextProvider: context, meshService: MockTransport(), identityManager: identityManager)

        let result = await withSelectedChannel(.mesh) {
            processor.process("/slap @bob")
        }

        switch result {
        case .handled:
            break
        default:
            Issue.record("Expected handled result")
        }
        #expect(context.sentPublicRawMessages == ["* 🐟 me slaps bob around a bit with a large trout *"])
        #expect(context.publicSystemMessages == ["🐟 me slaps bob around a bit with a large trout"])
    }

    @MainActor
    @Test func blockWithoutArgsListsMeshAndGeohashBlocks() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let context = MockCommandContextProvider()
        let transport = MockTransport()
        let peerID = PeerID(str: "abcd1234abcd1234")
        transport.peerNicknames[peerID] = "bob"
        transport.peerFingerprints[peerID] = "fp-bob"
        context.blockedUsers = ["fp-bob"]
        context.visibleGeoParticipants = [
            CommandGeoParticipant(id: String(repeating: "c", count: 64), displayName: "carol")
        ]
        identityManager.setNostrBlocked(String(repeating: "c", count: 64), isBlocked: true)
        let processor = CommandProcessor(contextProvider: context, meshService: transport, identityManager: identityManager)

        let result = await withSelectedChannel(.mesh) {
            processor.process("/block")
        }

        switch result {
        case .success(let message):
            #expect(message == "blocked peers: bob | geohash blocks: carol")
        default:
            Issue.record("Expected success result")
        }
    }

    @MainActor
    @Test func blockAndUnblockMeshPeerUpdateIdentityState() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let context = MockCommandContextProvider()
        let transport = MockTransport()
        let peerID = PeerID(str: "abcd1234abcd1234")
        transport.peerFingerprints[peerID] = "fp-bob"
        context.nicknameToPeerID["bob"] = peerID
        let processor = CommandProcessor(contextProvider: context, meshService: transport, identityManager: identityManager)

        let blockResult = await withSelectedChannel(.mesh) {
            processor.process("/block @bob")
        }
        switch blockResult {
        case .success(let message):
            #expect(message == "blocked bob. you will no longer receive messages from them")
        default:
            Issue.record("Expected success result")
        }
        #expect(identityManager.isBlocked(fingerprint: "fp-bob"))

        let unblockResult = await withSelectedChannel(.mesh) {
            processor.process("/unblock bob")
        }
        switch unblockResult {
        case .success(let message):
            #expect(message == "unblocked bob")
        default:
            Issue.record("Expected success result")
        }
        #expect(!identityManager.isBlocked(fingerprint: "fp-bob"))
    }

    @MainActor
    @Test func blockAndUnblockGeohashPeerUseNostrBlockList() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let context = MockCommandContextProvider()
        context.displayNameToNostrPubkey["carol"] = String(repeating: "d", count: 64)
        let processor = CommandProcessor(contextProvider: context, meshService: MockTransport(), identityManager: identityManager)

        let blockResult = await withSelectedChannel(.mesh) {
            processor.process("/block carol")
        }
        switch blockResult {
        case .success(let message):
            #expect(message == "blocked carol in geohash chats")
        default:
            Issue.record("Expected success result")
        }
        #expect(identityManager.isNostrBlocked(pubkeyHexLowercased: String(repeating: "d", count: 64)))

        let unblockResult = await withSelectedChannel(.mesh) {
            processor.process("/unblock @carol")
        }
        switch unblockResult {
        case .success(let message):
            #expect(message == "unblocked carol in geohash chats")
        default:
            Issue.record("Expected success result")
        }
        #expect(!identityManager.isNostrBlocked(pubkeyHexLowercased: String(repeating: "d", count: 64)))
    }

    @MainActor
    @Test func favoriteCommandIsRejectedOutsideMesh() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let processor = CommandProcessor(
            contextProvider: MockCommandContextProvider(),
            meshService: MockTransport(),
            identityManager: identityManager
        )
        let channel = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pruy"))

        let result = await withSelectedChannel(channel) {
            processor.process("/fav alice")
        }

        switch result {
        case .error(let message):
            #expect(message == "favorites are only for mesh peers in #mesh")
        default:
            Issue.record("Expected error result")
        }
    }

    @MainActor
    private func withSelectedChannel<T>(_ channel: ChannelID, perform work: @escaping () throws -> T) async rethrows -> T {
        let originalChannel = LocationChannelManager.shared.selectedChannel
        await setSelectedChannel(channel)
        do {
            let result = try work()
            await setSelectedChannel(originalChannel)
            return result
        } catch {
            await setSelectedChannel(originalChannel)
            throw error
        }
    }

    @MainActor
    private func setSelectedChannel(_ channel: ChannelID) async {
        LocationChannelManager.shared.select(channel)
        for _ in 0..<40 {
            if LocationChannelManager.shared.selectedChannel == channel {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeMessage(sender: String, content: String) -> BitchatMessage {
        BitchatMessage(
            sender: sender,
            content: content,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            isRelay: false
        )
    }
}

@MainActor
private final class MockCommandContextProvider: CommandContextProvider {
    var nickname: String
    var selectedPrivateChatPeer: PeerID?
    var blockedUsers: Set<String> = []
    var privateChats: [PeerID: [BitchatMessage]] = [:]
    let idBridge: NostrIdentityBridge

    var nicknameToPeerID: [String: PeerID] = [:]
    var visibleGeoParticipants: [CommandGeoParticipant] = []
    var displayNameToNostrPubkey: [String: String] = [:]

    private(set) var startedPrivateChats: [PeerID] = []
    private(set) var sentPrivateMessages: [(content: String, peerID: PeerID)] = []
    private(set) var clearCurrentPublicTimelineCallCount = 0
    private(set) var sentPublicRawMessages: [String] = []
    private(set) var localPrivateSystemMessages: [(content: String, peerID: PeerID)] = []
    private(set) var publicSystemMessages: [String] = []
    private(set) var toggledFavorites: [PeerID] = []
    private(set) var favoriteNotifications: [(peerID: PeerID, isFavorite: Bool)] = []

    init(nickname: String = "tester", idBridge: NostrIdentityBridge = NostrIdentityBridge(keychain: MockKeychain())) {
        self.nickname = nickname
        self.idBridge = idBridge
    }

    func getPeerIDForNickname(_ nickname: String) -> PeerID? {
        nicknameToPeerID[nickname]
    }

    func getVisibleGeoParticipants() -> [CommandGeoParticipant] {
        visibleGeoParticipants
    }

    func nostrPubkeyForDisplayName(_ displayName: String) -> String? {
        displayNameToNostrPubkey[displayName]
    }

    func startPrivateChat(with peerID: PeerID) {
        startedPrivateChats.append(peerID)
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        sentPrivateMessages.append((content, peerID))
    }

    func clearCurrentPublicTimeline() {
        clearCurrentPublicTimelineCallCount += 1
    }

    func sendPublicRaw(_ content: String) {
        sentPublicRawMessages.append(content)
    }

    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {
        localPrivateSystemMessages.append((content, peerID))
    }

    func addPublicSystemMessage(_ content: String) {
        publicSystemMessages.append(content)
    }

    func toggleFavorite(peerID: PeerID) {
        toggledFavorites.append(peerID)
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        favoriteNotifications.append((peerID, isFavorite))
    }
}
