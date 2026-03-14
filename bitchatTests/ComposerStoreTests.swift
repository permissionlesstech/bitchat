import Foundation
import Testing
@testable import bitchat

@MainActor
struct ComposerStoreTests {

    @Test
    func updateAutocomplete_usesMeshCandidatesWithoutMirroringChatViewModelState() {
        let sessionStore = SessionStore()
        sessionStore.nickname = "alice"

        let geohashStore = GeohashPeopleStore(
            sessionStore: sessionStore,
            participantStore: GeohashParticipantTracker(activityCutoff: -TransportConfig.uiRecentCutoffFiveMinutesSeconds),
            privateConversationsStore: PrivateConversationsStore(),
            timelineStore: PublicTimelineStore(
                meshCap: TransportConfig.meshTimelineCap,
                geohashCap: TransportConfig.geoTimelineCap
            ),
            identityManager: MockIdentityManager(MockKeychain()),
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper())
        )

        let store = ComposerStore(
            sessionStore: sessionStore,
            geohashPeopleStore: geohashStore,
            channelProvider: { .mesh },
            meshPeerCandidatesProvider: { ["bob", "alice", "bob"] }
        )

        store.updateAutocomplete(for: "@b", cursorPosition: 2)

        #expect(store.showAutocomplete)
        #expect(store.autocompleteSuggestions == ["@bob"])
    }

    @Test
    func completeNickname_appliesSuggestionAndClearsAutocompleteState() {
        let sessionStore = SessionStore()

        let geohashStore = GeohashPeopleStore(
            sessionStore: sessionStore,
            participantStore: GeohashParticipantTracker(activityCutoff: -TransportConfig.uiRecentCutoffFiveMinutesSeconds),
            privateConversationsStore: PrivateConversationsStore(),
            timelineStore: PublicTimelineStore(
                meshCap: TransportConfig.meshTimelineCap,
                geohashCap: TransportConfig.geoTimelineCap
            ),
            identityManager: MockIdentityManager(MockKeychain()),
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper())
        )

        let store = ComposerStore(
            sessionStore: sessionStore,
            geohashPeopleStore: geohashStore,
            channelProvider: { .mesh },
            meshPeerCandidatesProvider: { ["bob"] }
        )
        var text = "hi @b"

        store.updateAutocomplete(for: text, cursorPosition: text.count)
        let cursor = store.completeNickname("@bob", in: &text)

        #expect(text == "hi @bob")
        #expect(cursor == text.count + 1)
        #expect(!store.showAutocomplete)
        #expect(store.autocompleteSuggestions.isEmpty)
    }
}
