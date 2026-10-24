import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// The header commits a nickname draft once — on Return, on focus loss,
/// when a sheet opens — instead of on every keystroke: every rename is a
/// mesh-wide announce and a defaults write.
@MainActor
struct NicknameCommitTests {
    private struct Fixture {
        let transport: MockTransport
        let viewModel: ChatViewModel
        let chrome: AppChromeModel
        let defaults: UserDefaults
    }

    private let nicknameKey = "bitchat.nickname"

    private func makeFixture() throws -> Fixture {
        let suiteName = "NicknameCommitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let keychain = MockKeychain()
        let transport = MockTransport()
        let viewModel = ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            transport: transport,
            locationManager: LocationChannelManager(storage: defaults),
            readReceiptsDefaults: defaults,
            userDefaults: defaults
        )
        let chrome = AppChromeModel(
            chatViewModel: viewModel,
            privateInboxModel: PrivateInboxModel(conversations: ConversationStore())
        )
        return Fixture(transport: transport, viewModel: viewModel, chrome: chrome, defaults: defaults)
    }

    @Test
    func commitSendsOneAnnounceAndOneWrite() throws {
        let fixture = try makeFixture()
        let renamesBefore = fixture.transport.setNicknameCallCount
        let broadcastsBefore = fixture.transport.broadcastAnnounceCallCount

        let committed = fixture.chrome.commitNickname("builder", replacing: fixture.chrome.nickname)

        #expect(committed == "builder")
        // Mirrored synchronously, so the header reseeds from it at once.
        #expect(fixture.chrome.nickname == "builder")
        #expect(fixture.viewModel.nickname == "builder")
        #expect(fixture.transport.setNicknameCallCount == renamesBefore + 1)
        #expect(fixture.transport.broadcastAnnounceCallCount == broadcastsBefore)
        #expect(fixture.defaults.string(forKey: nicknameKey) == "builder")
    }

    @Test
    func committingTheSameNameIsFree() throws {
        let fixture = try makeFixture()
        let current = fixture.chrome.nickname
        let renamesBefore = fixture.transport.setNicknameCallCount
        fixture.defaults.removeObject(forKey: nicknameKey)

        fixture.chrome.commitNickname(current, replacing: current)

        #expect(fixture.transport.setNicknameCallCount == renamesBefore)
        #expect(fixture.defaults.string(forKey: nicknameKey) == nil)
    }

    /// Return commits, then the field loses focus and commits again: one
    /// announce.
    @Test
    func submitThenFocusLossAnnouncesOnce() throws {
        let fixture = try makeFixture()
        let renamesBefore = fixture.transport.setNicknameCallCount

        let submitted = fixture.chrome.commitNickname("builder", replacing: fixture.chrome.nickname)
        fixture.chrome.commitNickname(submitted, replacing: submitted)

        #expect(fixture.transport.setNicknameCallCount == renamesBefore + 1)
    }

    @Test
    func commitCanonicalizes() throws {
        let fixture = try makeFixture()

        #expect(fixture.chrome.commitNickname("  bob  ", replacing: fixture.chrome.nickname) == "bob")
        // Typed decomposed (NFD), committed composed (NFC).
        #expect(fixture.chrome.commitNickname("Jose\u{301}", replacing: fixture.chrome.nickname) == "Jos\u{E9}")
        // Internal spaces are part of the name.
        #expect(fixture.chrome.commitNickname("mary ann", replacing: fixture.chrome.nickname) == "mary ann")
        let anonymous = fixture.chrome.commitNickname("   ", replacing: fixture.chrome.nickname)
        #expect(anonymous.hasPrefix("anon") && anonymous.count == 8)
    }

    /// A panic wipe renames us while the field still holds a draft edited
    /// from the old name: the draft is dropped, never committed onto the
    /// new identity.
    @Test
    func staleDraftAfterExternalRenameIsDropped() throws {
        let fixture = try makeFixture()
        let draftBase = fixture.chrome.nickname
        fixture.viewModel.nickname = "anon4242"
        let renamesBefore = fixture.transport.setNicknameCallCount

        let result = fixture.chrome.commitNickname("builder", replacing: draftBase)

        #expect(result == "anon4242")
        #expect(fixture.viewModel.nickname == "anon4242")
        #expect(fixture.transport.setNicknameCallCount == renamesBefore)
    }
}
