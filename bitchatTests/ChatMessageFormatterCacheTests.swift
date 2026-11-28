//
// ChatMessageFormatterCacheTests.swift
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

/// A formatted row is cached on its message. Its key must cover what the
/// row shows that can change after the row is first drawn.
@MainActor
struct ChatMessageFormatterCacheTests {
    private let geohash = "u4pruyd"

    /// History older than the roster's 5-minute window does not put its
    /// sender in the roster, so their rows get the hash fallback color. Once
    /// they post live they get a palette slot, and their earlier rows (text
    /// and header) must show it too, as the people list does.
    @Test func earlierRowsTakeTheSlotASenderGetsOnJoining() {
        let viewModel = makeViewModel()
        viewModel.participantTracker.setActiveGeohash(geohash)
        let pubkey = String(format: "%064x", 0xabcdef1)
        viewModel.registerNostrKeyMapping(pubkey, for: PeerID(nostr: pubkey))
        let tenMinutesAgo = Date().addingTimeInterval(-600)
        #expect(!viewModel.participantTracker.recordParticipant(
            pubkeyHex: pubkey,
            geohash: geohash,
            seenAt: tenMinutesAgo
        ))

        let row = BitchatMessage(
            id: "replayed",
            sender: "pat#" + String(pubkey.suffix(4)),
            content: "hello",
            timestamp: tenMinutesAgo,
            isRelay: false,
            senderPeerID: PeerID(nostr: pubkey)
        )
        let fallback = Color(peerSeed: "nostr:" + pubkey, isDark: true)
        #expect(senderColor(in: viewModel.formatMessageAsText(row, colorScheme: .dark)) == fallback)
        #expect(senderColor(in: viewModel.formatMessageHeader(row, colorScheme: .dark)) == fallback)

        viewModel.participantTracker.recordParticipant(pubkeyHex: pubkey, geohash: geohash)
        let slot = viewModel.colorForNostrPubkey(pubkey, isDark: true)

        #expect(slot != fallback)
        #expect(senderColor(in: viewModel.formatMessageAsText(row, colorScheme: .dark)) == slot)
        #expect(senderColor(in: viewModel.formatMessageHeader(row, colorScheme: .dark)) == slot)
    }

    /// Mention highlighting reads my nickname, so after a rename an earlier
    /// row must render as a row first drawn under the new name does.
    @Test func earlierRowsFollowARename() throws {
        let viewModel = makeViewModel()
        viewModel.nickname = "alice"
        let row = BitchatMessage(
            id: "mention",
            sender: "bob",
            content: "hey @alice",
            timestamp: Date(),
            isRelay: false,
            senderPeerID: PeerID(str: "00000000000000b2"),
            mentions: ["alice"]
        )
        let selfColor = PeerColorContrast.selfColor(isDark: false)
        let asAlice = viewModel.formatMessageAsText(row, colorScheme: .light)
        #expect(try #require(mentionColor(in: asAlice)) == selfColor)

        viewModel.nickname = "carol"
        let asCarol = viewModel.formatMessageAsText(row, colorScheme: .light)

        #expect(try #require(mentionColor(in: asCarol)) != selfColor)
        #expect(asCarol == viewModel.formatMessageAsText(freshCopy(of: row), colorScheme: .light))
    }

    // MARK: - Helpers

    private func makeViewModel() -> ChatViewModel {
        let keychain = MockKeychain()
        // A private location manager: the shared one is switched by other
        // suites running in parallel, and a switch resets the roster.
        let locationSuite = "ChatMessageFormatterCacheTests.\(UUID().uuidString)"
        let locationStorage = UserDefaults(suiteName: locationSuite) ?? .standard
        locationStorage.removePersistentDomain(forName: locationSuite)
        return ChatViewModel(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain),
            transport: MockTransport(),
            locationManager: LocationChannelManager(storage: locationStorage)
        )
    }

    /// The same message as a new instance, so nothing is cached on it.
    private func freshCopy(of message: BitchatMessage) -> BitchatMessage {
        BitchatMessage(
            id: message.id,
            sender: message.sender,
            content: message.content,
            timestamp: message.timestamp,
            isRelay: message.isRelay,
            senderPeerID: message.senderPeerID,
            mentions: message.mentions
        )
    }

    /// The color of the first run, which renders `<@sender`.
    private func senderColor(in text: AttributedString) -> Color? {
        text.runs.first?.attributes[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self]
    }

    /// The color of the run that renders `@alice`.
    private func mentionColor(in text: AttributedString) -> Color? {
        for run in text.runs where String(text[run.range].characters) == "@alice" {
            return run.attributes[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self]
        }
        return nil
    }
}
