//
// ChatMessageFormatterTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import SwiftUI
import Testing
@testable import bitchat

/// Counts full roster scans: `GeohashParticipantTracker.getVisiblePeople()`
/// asks its context whether each participant is blocked exactly once.
@MainActor
private final class RosterScanCountingContext: GeohashParticipantContext {
    private weak var base: ChatViewModel?
    private(set) var isBlockedCalls = 0

    init(base: ChatViewModel) {
        self.base = base
    }

    func displayNameForPubkey(_ pubkeyHex: String) -> String {
        base?.displayNameForPubkey(pubkeyHex) ?? "anon#\(pubkeyHex.suffix(4))"
    }

    func isBlocked(_ pubkeyHexLowercased: String) -> Bool {
        isBlockedCalls += 1
        return base?.isBlocked(pubkeyHexLowercased) ?? false
    }
}

@MainActor
struct ChatMessageFormatterTests {
    private let geohash = "u4pruyd"

    /// One people-sheet render asks for a color per row. Each lookup used to
    /// rebuild the palette from a fresh roster scan, making the sheet O(N²):
    /// 60 rows cost 3,600 block checks before a single row was laid out.
    @Test func geohashColorLookupsDoNotRescanTheRoster() {
        let viewModel = makeViewModel()
        let pubkeys = seedParticipants(60, in: viewModel)
        let counter = RosterScanCountingContext(base: viewModel)
        viewModel.participantTracker.configure(context: counter)
        defer { viewModel.participantTracker.configure(context: viewModel) }

        let first = pubkeys.map { viewModel.colorForNostrPubkey($0, isDark: true) }
        let second = pubkeys.map { viewModel.colorForNostrPubkey($0, isDark: true) }

        #expect(counter.isBlockedCalls == 0)
        #expect(first == second)
    }

    /// The palette follows roster membership: a newcomer gets a palette slot
    /// (not the hash fallback) and people already on screen keep theirs.
    @Test func paletteTracksMembershipChangesWithoutRecoloringExistingRows() {
        let viewModel = makeViewModel()
        let pubkeys = seedParticipants(10, in: viewModel)
        let before = pubkeys.map { viewModel.colorForNostrPubkey($0, isDark: true) }

        let newcomer = String(format: "%064x", 0xfeed)
        viewModel.participantTracker.recordParticipant(pubkeyHex: newcomer, geohash: geohash)

        // Palette colors use the configured saturation, which the hash
        // fallback can never produce exactly, so inequality proves a slot.
        #expect(viewModel.colorForNostrPubkey(newcomer, isDark: true) != Color(peerSeed: "nostr:" + newcomer, isDark: true))
        #expect(pubkeys.map { viewModel.colorForNostrPubkey($0, isDark: true) } == before)
    }

    // MARK: - Mentions of me

    // Which of my names a mention must carry to count as "mentions me"
    // depends on who sent it, not on what is selected: the split layout shows
    // a #mesh row beside a selected geohash, and a formatted row is cached
    // whatever channel it was first drawn under.

    /// The split layout's #mesh pane while the trailing pane shows a geohash:
    /// a mesh peer addresses me by my mesh peer ID.
    @Test func meshMentionOfMyMeshNameIsMineWhileGeohashIsSelected() throws {
        let (viewModel, transport) = makeMentionViewModel()
        viewModel.activeChannel = .location(selectedGeohash)

        let row = makeRow(content: "hi @alice#\(meshSuffix(of: transport))", senderPeerID: meshSender)
        let formatted = viewModel.formatMessageAsText(row, colorScheme: .light)

        #expect(try #require(mentionColor(in: formatted, base: "alice")) == .orange)
    }

    /// A row first drawn while a geohash is selected stays right once #mesh
    /// is selected again: the formatted-text cache ignores the channel.
    @Test func meshMentionOfMyMeshNameStaysMineAcrossSelectionChanges() throws {
        let (viewModel, transport) = makeMentionViewModel()
        viewModel.activeChannel = .location(selectedGeohash)
        let row = makeRow(content: "hi @alice#\(meshSuffix(of: transport))", senderPeerID: meshSender)
        _ = viewModel.formatMessageAsText(row, colorScheme: .light)

        viewModel.activeChannel = .mesh
        let formatted = viewModel.formatMessageAsText(row, colorScheme: .light)

        #expect(try #require(mentionColor(in: formatted, base: "alice")) == .orange)
    }

    /// A mesh peer cannot know my geohash identity, so a mesh row carrying
    /// its suffix names someone else.
    @Test func meshMentionOfMyGeohashNameIsNotMine() throws {
        let (viewModel, _) = makeMentionViewModel()
        viewModel.activeChannel = .location(selectedGeohash)
        let geoSuffix = try geohashSuffix(in: viewModel)

        let row = makeRow(content: "hi @alice#\(geoSuffix)", senderPeerID: meshSender)
        let formatted = viewModel.formatMessageAsText(row, colorScheme: .light)

        #expect(try #require(mentionColor(in: formatted, base: "alice")) != .orange)
    }

    /// A geohash sender addresses me by my identity in the selected geohash.
    @Test func geohashMentionOfMyGeohashNameIsMine() throws {
        let (viewModel, _) = makeMentionViewModel()
        viewModel.activeChannel = .location(selectedGeohash)
        let geoSuffix = try geohashSuffix(in: viewModel)

        let row = makeRow(content: "hi @alice#\(geoSuffix)", senderPeerID: geohashSender)
        let formatted = viewModel.formatMessageAsText(row, colorScheme: .light)

        #expect(try #require(mentionColor(in: formatted, base: "alice")) == .orange)
    }

    /// Compact #mesh is unchanged.
    @Test func meshMentionOfMyMeshNameIsMineOnMesh() throws {
        let (viewModel, transport) = makeMentionViewModel()

        let row = makeRow(content: "hi @alice#\(meshSuffix(of: transport))", senderPeerID: meshSender)
        let formatted = viewModel.formatMessageAsText(row, colorScheme: .light)

        #expect(try #require(mentionColor(in: formatted, base: "alice")) == .orange)
    }

    // MARK: - Helpers

    private let selectedGeohash = GeohashChannel(level: .city, geohash: "u4pru")
    private let meshSender = PeerID(str: "00000000000000b1")
    private let geohashSender = PeerID(nostr: String(repeating: "cd", count: 32))

    private func makeViewModel() -> ChatViewModel {
        makeViewModel(transport: MockTransport())
    }

    private func makeViewModel(transport: MockTransport) -> ChatViewModel {
        let keychain = MockKeychain()
        // A private location manager: the shared one is switched by other
        // suites running in parallel, and a switch resets the roster.
        let locationSuite = "ChatMessageFormatterTests.\(UUID().uuidString)"
        let locationStorage = UserDefaults(suiteName: locationSuite) ?? .standard
        locationStorage.removePersistentDomain(forName: locationSuite)
        return ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            transport: transport,
            locationManager: LocationChannelManager(storage: locationStorage)
        )
    }

    /// A view model named "alice" whose mesh peer ID is hex, so its prefix
    /// is a valid mention suffix (`#xxxx`).
    private func makeMentionViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
        let transport = MockTransport()
        transport.myPeerID = PeerID(str: "a1b2c3d4e5f60718")
        let viewModel = makeViewModel(transport: transport)
        viewModel.nickname = "alice"
        return (viewModel, transport)
    }

    private func meshSuffix(of transport: MockTransport) -> String {
        String(transport.myPeerID.id.prefix(4))
    }

    private func geohashSuffix(in viewModel: ChatViewModel) throws -> String {
        let identity = try viewModel.idBridge.deriveIdentity(forGeohash: selectedGeohash.geohash)
        return String(identity.publicKeyHex.suffix(4))
    }

    private func makeRow(content: String, senderPeerID: PeerID) -> BitchatMessage {
        BitchatMessage(
            id: UUID().uuidString,
            sender: "bob",
            content: content,
            timestamp: Date(),
            isRelay: false,
            senderPeerID: senderPeerID
        )
    }

    /// The foreground color of the run that renders `@<base>` of a mention.
    private func mentionColor(in text: AttributedString, base: String) -> Color? {
        for run in text.runs where String(text[run.range].characters) == "@\(base)" {
            return run.attributes[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self]
        }
        return nil
    }

    private func seedParticipants(_ count: Int, in viewModel: ChatViewModel) -> [String] {
        let tracker = viewModel.participantTracker
        tracker.setActiveGeohash(geohash)
        let pubkeys = (1...count).map { String(format: "%064x", $0) }
        for pubkey in pubkeys {
            tracker.recordParticipant(pubkeyHex: pubkey, geohash: geohash)
        }
        return pubkeys
    }
}
