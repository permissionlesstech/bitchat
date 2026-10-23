//
// BitchatMessageMediaTests.swift
// bitchatTests
//
// Which messages render as local media rows, and which file such a row
// loads. The filename comes from (possibly remote) message text, so it must
// never resolve outside the media directory it names.
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BitchatMessageMediaTests {
    private static let meshPeerID = PeerID(str: "0011223344556677")
    private static let nostrPubkey = String(repeating: "ab", count: 32)

    private func message(_ content: String, sender: String = "alice", senderPeerID: PeerID? = meshPeerID) -> BitchatMessage {
        BitchatMessage(sender: sender, content: content, timestamp: Date(), isRelay: false, senderPeerID: senderPeerID)
    }

    @Test
    func meshMediaResolvesInsideItsCategoryDirectory() {
        guard case .image(let imageURL)? = message("[image] img_1.jpg").mediaAttachment(for: "me"),
              case .voice(let voiceURL)? = message("[voice] note 1.m4a").mediaAttachment(for: "me"),
              case .image(let ownImageURL)? = message("[image] img_2.jpg", sender: "me").mediaAttachment(for: "me")
        else {
            Issue.record("Expected mesh media messages to resolve to media rows")
            return
        }

        #expect(imageURL.lastPathComponent == "img_1.jpg")
        #expect(imageURL.deletingLastPathComponent().path.hasSuffix("/files/images/incoming"))
        #expect(voiceURL.lastPathComponent == "note 1.m4a")
        #expect(voiceURL.deletingLastPathComponent().path.hasSuffix("/files/voicenotes/incoming"))
        #expect(ownImageURL.deletingLastPathComponent().path.hasSuffix("/files/images/outgoing"))
    }

    @Test
    func nostrSendersNeverGetMediaRows() {
        // Geochats, geo DMs and bridged messages carry no files, so a
        // media-looking line from a Nostr sender must stay text instead of
        // loading some local file.
        let geoChatSender = PeerID(nostr: Self.nostrPubkey)
        let geoDMSender = PeerID(nostr_: Self.nostrPubkey)
        let bridgedSender = PeerID(bridge: Self.nostrPubkey)
        #expect(geoChatSender.isGeoChat)
        #expect(geoDMSender.isGeoDM)
        #expect(bridgedSender.isBridge)

        for content in ["[image] img_1.jpg", "[voice] note.m4a"] {
            #expect(message(content, senderPeerID: geoChatSender).mediaAttachment(for: "me") == nil)
            #expect(message(content, senderPeerID: geoDMSender).mediaAttachment(for: "me") == nil)
            #expect(message(content, senderPeerID: bridgedSender).mediaAttachment(for: "me") == nil)
            #expect(message(content, sender: "me", senderPeerID: geoChatSender).mediaAttachment(for: "me") == nil)
        }
        // A message without a sender ID keeps the mesh behavior.
        #expect(message("[image] img_1.jpg", senderPeerID: nil).mediaAttachment(for: "me") != nil)
    }

    @Test
    func filenamesThatAreNotOnePlainComponentAreRejected() {
        let unsafeNames = [
            "../outgoing/x.jpg",
            "../../Library/secret.jpg",
            "a/b.jpg",
            "/etc/hosts",
            "x.jpg/",
            "..",
            ".",
            "a\\b.jpg",
            "..\\outgoing\\x.jpg"
        ]
        for name in unsafeNames {
            #expect(!BitchatMessage.isSafeMediaFilename(name), "\(name)")
            #expect(message("[image] \(name)").mediaAttachment(for: "me") == nil, "\(name)")
            #expect(message("[voice] \(name)").mediaAttachment(for: "me") == nil, "\(name)")
        }
        #expect(!BitchatMessage.isSafeMediaFilename(""))
        #expect(message("[image]  ").mediaAttachment(for: "me") == nil)
    }

    @Test
    func plainFilenamesAreAccepted() {
        for name in ["img_20260101_120000.jpg", "note 1.m4a", "photo...jpg", "...", "émoji-😀.png"] {
            #expect(BitchatMessage.isSafeMediaFilename(name), "\(name)")
        }
    }
}
