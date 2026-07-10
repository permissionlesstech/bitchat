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

        let result = await withSelectedChannel(.mesh, context: context) {
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
        let context = MockCommandContextProvider()
        let transport = MockTransport()
        transport.peerNicknames = [
            PeerID(str: "b"): "bob",
            PeerID(str: "a"): "alice"
        ]
        let processor = CommandProcessor(contextProvider: context, meshService: transport, identityManager: identityManager)

        let result = await withSelectedChannel(.mesh, context: context) {
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

        let result = await withSelectedChannel(channel, context: context) {
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

        let result = await withSelectedChannel(.mesh, context: context) {
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

        let result = await withSelectedChannel(.mesh, context: context) {
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

        let result = await withSelectedChannel(.mesh, context: context) {
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

        let result = await withSelectedChannel(.mesh, context: context) {
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

        let result = await withSelectedChannel(.mesh, context: context) {
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

        let blockResult = await withSelectedChannel(.mesh, context: context) {
            processor.process("/block @bob")
        }
        switch blockResult {
        case .success(let message):
            #expect(message == "blocked bob. you will no longer receive messages from them")
        default:
            Issue.record("Expected success result")
        }
        #expect(identityManager.isBlocked(fingerprint: "fp-bob"))

        let unblockResult = await withSelectedChannel(.mesh, context: context) {
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

        let blockResult = await withSelectedChannel(.mesh, context: context) {
            processor.process("/block carol")
        }
        switch blockResult {
        case .success(let message):
            #expect(message == "blocked carol in geohash chats")
        default:
            Issue.record("Expected success result")
        }
        #expect(identityManager.isNostrBlocked(pubkeyHexLowercased: String(repeating: "d", count: 64)))

        let unblockResult = await withSelectedChannel(.mesh, context: context) {
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

    /// /fav must go through toggleFavorite (which persists by the real noise
    /// key) — not write the hex peer ID into the favorites store, and not
    /// send a second favorite notification.
    @MainActor
    @Test func favoriteCommandTogglesWithoutDirectStoreWrite() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let context = MockCommandContextProvider()
        let processor = CommandProcessor(
            contextProvider: context,
            meshService: MockTransport(),
            identityManager: identityManager
        )
        let peerID = PeerID(str: "00aa00bb00cc00dd")
        context.nicknameToPeerID["alice"] = peerID

        let result = await withSelectedChannel(.mesh, context: context) {
            processor.process("/fav alice")
        }

        switch result {
        case .success(let message):
            #expect(message == "added alice to favorites")
        default:
            Issue.record("Expected success result")
        }
        #expect(context.toggledFavorites == [peerID])
        #expect(context.favoriteNotifications.isEmpty)
        // The 8-byte routing ID must never be stored as a "noise key".
        let bogusKey = Data(hexString: peerID.id)!
        #expect(FavoritesPersistenceService.shared.getFavoriteStatus(for: bogusKey) == nil)

        // Unfavoriting someone who is not a favorite is a no-op.
        let unfavResult = await withSelectedChannel(.mesh, context: context) {
            processor.process("/unfav alice")
        }
        switch unfavResult {
        case .success(let message):
            #expect(message == "alice is not a favorite")
        default:
            Issue.record("Expected success result")
        }
        #expect(context.toggledFavorites == [peerID])
    }

    @MainActor
    @Test func favoriteCommandIsRejectedOutsideMesh() async {
        let identityManager = MockIdentityManager(MockKeychain())
        let context = MockCommandContextProvider()
        let processor = CommandProcessor(
            contextProvider: context,
            meshService: MockTransport(),
            identityManager: identityManager
        )
        let channel = ChannelID.location(GeohashChannel(level: .city, geohash: "u4pruy"))

        let result = await withSelectedChannel(channel, context: context) {
            processor.process("/fav alice")
        }

        switch result {
        case .error(let message):
            #expect(message == "favorites are only for mesh peers in #mesh")
        default:
            Issue.record("Expected error result")
        }
    }

    // MARK: - /pay

    @MainActor
    @Test func payWithoutArgumentsPrintsUsage() {
        let processor = makePayProcessor(context: MockCommandContextProvider())
        switch processor.process("/pay") {
        case .success(let message):
            #expect(message?.contains("usage: /pay") == true)
        default:
            Issue.record("Expected success (usage) result")
        }
    }

    @MainActor
    @Test func payRejectsInvalidToken() {
        let context = MockCommandContextProvider()
        let processor = makePayProcessor(context: context)
        for bad in ["/pay nonsense", "/pay cashuAshort", "/pay cashuA!!!!!!!!!!!!!!!!"] {
            switch processor.process(bad) {
            case .error:
                break
            default:
                Issue.record("Expected error for \(bad)")
            }
        }
        #expect(context.sentPrivateMessages.isEmpty)
        #expect(context.sentPublicMessages.isEmpty)
    }

    @MainActor
    @Test func paySendsBareTokenInPrivateChat() {
        let context = MockCommandContextProvider()
        let peerID = PeerID(str: "abcd1234abcd1234")
        context.selectedPrivateChatPeer = peerID
        let processor = makePayProcessor(context: context)

        // cashu: URI form must be normalized to the bare token before sending
        switch processor.process("/pay cashu:\(Self.validV3Token)") {
        case .success(let message):
            #expect(message?.contains("21 sat") == true)
        default:
            Issue.record("Expected success result")
        }
        #expect(context.sentPrivateMessages.count == 1)
        #expect(context.sentPrivateMessages.first?.content == Self.validV3Token)
        #expect(context.sentPrivateMessages.first?.peerID == peerID)
        #expect(context.sentPublicMessages.isEmpty)
    }

    @MainActor
    @Test func payInPublicChannelRequiresExplicitConfirm() {
        let context = MockCommandContextProvider()
        let processor = makePayProcessor(context: context)

        switch processor.process("/pay \(Self.validV3Token)") {
        case .error(let message):
            #expect(message.contains("public") == true)
        default:
            Issue.record("Expected error without confirm")
        }
        #expect(context.sentPublicMessages.isEmpty)

        switch processor.process("/pay \(Self.validV3Token) public") {
        case .success:
            break
        default:
            Issue.record("Expected success with confirm")
        }
        #expect(context.sentPublicMessages == [Self.validV3Token])
        #expect(context.sentPrivateMessages.isEmpty)
    }

    @MainActor
    @Test func payRejectsTruncatedOrJunkV4Token() {
        let context = MockCommandContextProvider()
        context.selectedPrivateChatPeer = PeerID(str: "abcd1234abcd1234")
        let processor = makePayProcessor(context: context)

        // Truncated V4 (definite-length CBOR can no longer be walked) and
        // pure base64 junk under the cashuB prefix must both be refused.
        let truncatedV4 = String(Self.validV4Token.prefix(Self.validV4Token.count - 12))
        let junkV4 = "cashuB" + String(repeating: "Q", count: 40)
        for bad in ["/pay \(truncatedV4)", "/pay \(junkV4)"] {
            switch processor.process(bad) {
            case .error(let message):
                #expect(message.contains("invalid cashu token") == true)
            default:
                Issue.record("Expected error for \(bad)")
            }
        }
        #expect(context.sentPrivateMessages.isEmpty)
        #expect(context.sentPublicMessages.isEmpty)
    }

    @MainActor
    @Test func paySendsValidDefiniteLengthV4Token() {
        let context = MockCommandContextProvider()
        let peerID = PeerID(str: "abcd1234abcd1234")
        context.selectedPrivateChatPeer = peerID
        let processor = makePayProcessor(context: context)

        switch processor.process("/pay \(Self.validV4Token)") {
        case .success(let message):
            #expect(message?.contains("21 sat") == true)
        default:
            Issue.record("Expected success result for valid V4 token")
        }
        #expect(context.sentPrivateMessages.count == 1)
        #expect(context.sentPrivateMessages.first?.content == Self.validV4Token)
    }

    /// 21-sat single-mint V3 token (proofs of 1+4+16).
    private static let validV3Token: String = {
        let json: [String: Any] = [
            "token": [[
                "mint": "https://mint.example.com",
                "proofs": [1, 4, 16].map { ["amount": $0, "id": "009a1f293253e41e", "secret": "s", "C": "02c"] }
            ]],
            "unit": "sat"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "cashuA" + b64
    }()

    /// 21-sat single-mint definite-length V4 (CBOR) token (proofs of 1+4+16).
    private static let validV4Token: String = {
        func head(_ major: UInt8, _ value: UInt64) -> [UInt8] {
            switch value {
            case 0...23: return [(major << 5) | UInt8(value)]
            case 24...0xFF: return [(major << 5) | 24, UInt8(value)]
            default: return [(major << 5) | 25, UInt8(value >> 8), UInt8(value & 0xFF)]
            }
        }
        func text(_ s: String) -> [UInt8] { head(3, UInt64(s.utf8.count)) + Array(s.utf8) }
        func bytes(_ b: [UInt8]) -> [UInt8] { head(2, UInt64(b.count)) + b }
        func uint(_ v: UInt64) -> [UInt8] { head(0, v) }
        func array(_ items: [[UInt8]]) -> [UInt8] { head(4, UInt64(items.count)) + items.flatMap { $0 } }
        func map(_ pairs: [(String, [UInt8])]) -> [UInt8] { head(5, UInt64(pairs.count)) + pairs.flatMap { text($0.0) + $0.1 } }

        let proofs = [UInt64(1), 4, 16].map { amount in
            map([("a", uint(amount)), ("s", text("secret")), ("c", bytes([0x02, 0xAB, 0xCD]))])
        }
        let cbor = map([
            ("m", text("https://mint.example.com")),
            ("u", text("sat")),
            ("t", array([map([("i", bytes([0x00, 0xAD, 0x26, 0x8C])), ("p", array(proofs))])]))
        ])
        let b64 = Data(cbor).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "cashuB" + b64
    }()

    @MainActor
    private func makePayProcessor(context: MockCommandContextProvider) -> CommandProcessor {
        CommandProcessor(
            contextProvider: context,
            meshService: MockTransport(),
            identityManager: MockIdentityManager(MockKeychain())
        )
    }

    @MainActor
    private func withSelectedChannel<T>(
        _ channel: ChannelID,
        context: MockCommandContextProvider? = nil,
        perform work: @escaping () throws -> T
    ) async rethrows -> T {
        let originalChannel = LocationChannelManager.shared.selectedChannel
        let originalContextChannel = context?.activeChannel
        await setSelectedChannel(channel, context: context)
        do {
            let result = try work()
            await setSelectedChannel(originalChannel, context: context, explicitChannel: originalContextChannel)
            return result
        } catch {
            await setSelectedChannel(originalChannel, context: context, explicitChannel: originalContextChannel)
            throw error
        }
    }

    @MainActor
    private func setSelectedChannel(
        _ channel: ChannelID,
        context: MockCommandContextProvider? = nil,
        explicitChannel: ChannelID? = nil
    ) async {
        context?.activeChannel = explicitChannel ?? channel
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
    var activeChannel: ChannelID = .mesh
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
    private(set) var commandOutputs: [String] = []
    private(set) var commandOutputDestinations: [CommandOutputDestination] = []
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

    private(set) var clearedPrivateChats: [PeerID] = []
    func clearPrivateChat(_ peerID: PeerID) {
        clearedPrivateChats.append(peerID)
        privateChats[peerID] = []
    }

    func sendPublicRaw(_ content: String) {
        sentPublicRawMessages.append(content)
    }

    private(set) var sentPublicMessages: [String] = []
    func sendPublicMessage(_ content: String) {
        sentPublicMessages.append(content)
    }

    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {
        localPrivateSystemMessages.append((content, peerID))
    }

    func addPublicSystemMessage(_ content: String) {
        publicSystemMessages.append(content)
    }

    func currentCommandDestination() -> CommandOutputDestination {
        if let peerID = selectedPrivateChatPeer {
            return .privateChat(peerID)
        }
        return .meshTimeline
    }

    func addCommandOutput(_ content: String, to destination: CommandOutputDestination) {
        commandOutputs.append(content)
        commandOutputDestinations.append(destination)
    }

    func toggleFavorite(peerID: PeerID) {
        toggledFavorites.append(peerID)
    }

    // Groups: record the parsed subcommand + argument the processor forwarded.
    private(set) var groupCommands: [(subcommand: String, argument: String)] = []

    func groupCreate(named name: String) -> CommandResult {
        groupCommands.append(("create", name))
        return .handled
    }

    func groupInvite(nickname: String) -> CommandResult {
        groupCommands.append(("invite", nickname))
        return .handled
    }

    func groupRemove(nickname: String) -> CommandResult {
        groupCommands.append(("remove", nickname))
        return .handled
    }

    func groupLeave() -> CommandResult {
        groupCommands.append(("leave", ""))
        return .handled
    }

    func groupList() -> CommandResult {
        groupCommands.append(("list", ""))
        return .handled
    }
}
