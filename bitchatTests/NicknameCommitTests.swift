import BitFoundation
import Foundation
import SwiftUI
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
        let suiteName: String

        func removeDefaults() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private let nicknameKey = "bitchat.nickname"

    private func makeFixture() throws -> Fixture {
        let suiteName = "NicknameCommitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
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
        return Fixture(transport: transport, viewModel: viewModel, chrome: chrome, defaults: defaults, suiteName: suiteName)
    }

    @Test
    func commitSendsOneAnnounceAndOneWrite() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDefaults() }
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
        defer { fixture.removeDefaults() }
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
        defer { fixture.removeDefaults() }
        let renamesBefore = fixture.transport.setNicknameCallCount

        let submitted = fixture.chrome.commitNickname("builder", replacing: fixture.chrome.nickname)
        fixture.chrome.commitNickname(submitted, replacing: submitted)

        #expect(fixture.transport.setNicknameCallCount == renamesBefore + 1)
    }

    @Test
    func commitCanonicalizes() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDefaults() }

        #expect(fixture.chrome.commitNickname("  bob  ", replacing: fixture.chrome.nickname) == "bob")
        // Typed decomposed (NFD), committed composed (NFC). String == treats
        // the two as equal, so compare scalars: what is announced and saved.
        let composed = Array("Jos\u{E9}".unicodeScalars)
        let committed = fixture.chrome.commitNickname("Jose\u{301}", replacing: fixture.chrome.nickname)
        #expect(Array(committed.unicodeScalars) == composed)
        #expect(Array(fixture.transport.myNickname.unicodeScalars) == composed)
        #expect(fixture.defaults.string(forKey: nicknameKey).map { Array($0.unicodeScalars) } == composed)
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
        defer { fixture.removeDefaults() }
        let draftBase = fixture.chrome.nickname
        fixture.viewModel.nickname = "anon4242"
        let renamesBefore = fixture.transport.setNicknameCallCount

        let result = fixture.chrome.commitNickname("builder", replacing: draftBase)

        #expect(result == "anon4242")
        #expect(fixture.viewModel.nickname == "anon4242")
        #expect(fixture.transport.setNicknameCallCount == renamesBefore)
    }

    /// Leaving the foreground commits the draft. On iOS only `.background`
    /// does: `.inactive` also covers Control Center, the app switcher and
    /// Siri, and committing there would announce a half-typed name.
    @Test
    func draftIsCommittedOnlyWhenTheAppLeavesTheForeground() {
        #expect(!ContentHeaderView.commitsNicknameDraft(on: .active))
        #expect(ContentHeaderView.commitsNicknameDraft(on: .background))
        #if os(iOS)
        #expect(!ContentHeaderView.commitsNicknameDraft(on: .inactive))
        #else
        #expect(ContentHeaderView.commitsNicknameDraft(on: .inactive))
        #endif
    }
}
