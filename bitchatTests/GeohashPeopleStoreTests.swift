import Foundation
import Testing
@testable import bitchat

@MainActor
private func makeGeohashPeopleHarness() -> (viewModel: ChatViewModel, sessionStore: SessionStore, store: GeohashPeopleStore) {
    TestHelpers.resetSharedApplicationState()
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport
    )
    let sessionStore = viewModel.sessionStore
    let store = viewModel.geohashPeopleStore

    return (viewModel, sessionStore, store)
}

@MainActor
@Suite(.serialized)
struct GeohashPeopleStoreTests {

    @Test
    func chatViewModelCompatibilityAccessorsRouteThroughStore() {
        let (viewModel, _, store) = makeGeohashPeopleHarness()
        let conversationPeerID = PeerID(nostr_: String(repeating: "ab", count: 32))

        viewModel.currentGeohash = "u4pruy"
        viewModel.geoNicknames["abcdef12"] = "alice"
        viewModel.nostrKeyMapping[conversationPeerID] = conversationPeerID.bare

        #expect(store.currentGeohash == "u4pruy")
        #expect(store.geoNicknamesSnapshot["abcdef12"] == "alice")
        #expect(store.fullNostrHex(for: conversationPeerID) == conversationPeerID.bare)
    }

    @Test
    func displayNameUsesSessionNicknameForCurrentGeohashIdentity() async throws {
        let (viewModel, sessionStore, store) = makeGeohashPeopleHarness()
        let channel = GeohashChannel(level: .city, geohash: "u4pruy")

        sessionStore.nickname = "alice"
        viewModel.currentGeohash = channel.geohash

        let identity = try viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash)

        #expect(store.currentIdentityHex() == identity.publicKeyHex.lowercased())
        #expect(store.displayNameForPubkey(identity.publicKeyHex) == "alice#\(identity.publicKeyHex.suffix(4))")
    }

    @Test
    func startDirectMessageRecordsMappingAndSelectsConversation() {
        let (viewModel, _, store) = makeGeohashPeopleHarness()
        let pubkeyHex = String(repeating: "ab", count: 32)
        let conversationPeerID = PeerID(nostr_: pubkeyHex)

        store.startDirectMessage(withPubkeyHex: pubkeyHex)

        #expect(viewModel.nostrKeyMapping[conversationPeerID] == pubkeyHex)
        #expect(viewModel.privateChatManager.selectedPeer == conversationPeerID)
    }

    @Test
    func peerResolutionUsesStoreVisiblePeopleAndNicknameCache() {
        let (viewModel, _, store) = makeGeohashPeopleHarness()
        let channel = GeohashChannel(level: .city, geohash: "u4pruy")
        let pubkeyHex = String(repeating: "ef", count: 32)
        let displayName = "alice#\(pubkeyHex.suffix(4))"

        viewModel.currentGeohash = channel.geohash
        viewModel.participantTracker.setActiveGeohash(channel.geohash)
        viewModel.participantTracker.recordParticipant(pubkeyHex: pubkeyHex, geohash: channel.geohash)
        store.registerNickname("alice", for: pubkeyHex)

        let displayMatch = store.peerID(for: displayName)
        let nicknameMatch = viewModel.getPeerIDForNickname("alice")

        #expect(displayMatch == PeerID(nostr_: pubkeyHex))
        #expect(nicknameMatch == PeerID(nostr_: pubkeyHex))
        #expect(store.fullNostrHex(for: PeerID(nostr_: pubkeyHex)) == pubkeyHex)
    }

    @Test
    func autocompleteTokensExcludeCurrentIdentity() async throws {
        let (viewModel, sessionStore, store) = makeGeohashPeopleHarness()
        let channel = GeohashChannel(level: .city, geohash: "u4pruy")
        let otherPubkeyHex = String(repeating: "12", count: 32)

        sessionStore.nickname = "alice"
        viewModel.currentGeohash = channel.geohash

        let identity = try viewModel.idBridge.deriveIdentity(forGeohash: channel.geohash)
        store.registerNickname("alice", for: identity.publicKeyHex)
        store.registerNickname("bob", for: otherPubkeyHex)

        let tokens = Set(store.autocompleteTokens(excludingSelfNickname: sessionStore.nickname))

        #expect(!tokens.contains("alice#\(identity.publicKeyHex.suffix(4))"))
        #expect(tokens.contains("bob#\(otherPubkeyHex.suffix(4))"))
    }

    @Test
    func blockingParticipantRemovesVisiblePersonAndMarksBlocked() {
        let (viewModel, _, store) = makeGeohashPeopleHarness()
        let channel = GeohashChannel(level: .city, geohash: "u4pruy")
        let pubkeyHex = String(repeating: "cd", count: 32)

        viewModel.currentGeohash = channel.geohash
        viewModel.participantTracker.setActiveGeohash(channel.geohash)
        viewModel.participantTracker.recordParticipant(pubkeyHex: pubkeyHex, geohash: channel.geohash)

        #expect(viewModel.participantTracker.visiblePeople.count == 1)

        store.block(pubkeyHexLowercased: pubkeyHex, displayName: "anon#\(pubkeyHex.suffix(4))")

        #expect(store.isBlocked(pubkeyHex))
        #expect(viewModel.participantTracker.visiblePeople.isEmpty)
    }
}
