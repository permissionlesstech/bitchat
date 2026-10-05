//
// MessageDeepLinkTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct MessageDeepLinkTests {
    @Test func meshLinkIncludesMessageID() throws {
        let url = try #require(MessageDeepLink.url(for: "msg-1", scope: .mesh))
        #expect(url.host == "mesh")
        #expect(url.query?.contains("mid=msg-1") == true)
    }

    @Test func geohashLinkLowercasesPath() throws {
        let url = try #require(MessageDeepLink.url(for: "abc", scope: .geohash("U4PRU")))
        #expect(url.path == "/u4pru")
    }

    @Test func directLinkUsesPeerPath() throws {
        let peer = PeerID(str: "deadbeef")
        let url = try #require(MessageDeepLink.url(for: "x", scope: .direct(peerID: peer)))
        #expect(url.host == "dm")
        #expect(url.path.contains("deadbeef"))
    }

    @Test func plainTextWrapsURL() {
        let text = MessageDeepLink.plainText(for: "mid", scope: .mesh)
        #expect(text.contains("bitchat://"))
        #expect(text.contains("mid=mid"))
    }

    @Test func meshURLUsesMeshHostAndMessageQuery() throws {
        let url = try #require(MessageDeepLink.url(for: "msg-42", scope: .mesh))
        #expect(url.host == "mesh")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "mid" })?.value == "msg-42")
    }

    // MARK: - Opening links

    /// The `dm` path arrives from any app or webpage. Before this gate it went
    /// straight into `openConversation(for:)`, so an arbitrary string opened a
    /// conversation against an identity that never existed.
    @Test("A bare 16-hex mesh peer is accepted")
    func acceptsMeshPeerPath() throws {
        let peerID = try #require(MessageDeepLink.directConversationTarget(fromPath: "/a1b2c3d4e5f60718"))
        #expect(peerID.id == "a1b2c3d4e5f60718")
    }

    @Test("Geo DM and group conversation shapes are accepted")
    func acceptsGeoDMAndGroupPaths() {
        #expect(MessageDeepLink.directConversationTarget(fromPath: "/nostr_0123456789abcdef") != nil)
        #expect(MessageDeepLink.directConversationTarget(fromPath: "/group_" + String(repeating: "a", count: 32)) != nil)
    }

    @Test("Malformed and hostile paths are rejected")
    func rejectsMalformedPaths() {
        let rejected = [
            "/",                                  // empty
            "/../../etc/passwd",                  // traversal-ish junk
            "/zzzzzzzzzzzzzzzz",                  // 16 chars, not hex
            "/a1b2c3",                            // too short
            "/a1b2c3d4e5f607189",                 // 17 hex, wrong length
            "/nostr_0123",                        // geo DM, wrong length
            "/group_abc",                         // group, wrong length
            "/noise:" + String(repeating: "a", count: 64),  // routing-only prefix
            "/name:alice",                        // routing-only prefix
            "/bridge:0123456789abcdef",           // not a routable conversation
            "/nostr:01234567",                    // geohash chat, not a DM
            "/" + String(repeating: "a", count: 128)        // over-length
        ]
        for path in rejected {
            #expect(
                MessageDeepLink.directConversationTarget(fromPath: path) == nil,
                "should have rejected \(path)"
            )
        }
    }

    @Test("Percent-encoded paths decode before validation")
    func decodesPercentEncoding() {
        #expect(MessageDeepLink.directConversationTarget(fromPath: "/nostr%5F0123456789abcdef") != nil)
    }

    @Test("The message ID is read back off a link we built")
    func readsMessageIDBack() throws {
        let url = try #require(MessageDeepLink.url(for: "msg-42", scope: .mesh))
        #expect(MessageDeepLink.messageID(from: url) == "msg-42")
    }

    @Test("A link with no usable mid yields nil")
    func missingMessageIDIsNil() throws {
        #expect(MessageDeepLink.messageID(from: try #require(URL(string: "bitchat://mesh/"))) == nil)
        #expect(MessageDeepLink.messageID(from: try #require(URL(string: "bitchat://mesh/?mid="))) == nil)
        #expect(MessageDeepLink.messageID(from: try #require(URL(string: "bitchat://mesh/?mid=%20"))) == nil)
    }

    /// The row must be addressed exactly as `MessageDisplayItem.id` composes it,
    /// or `scrollTo` silently finds nothing.
    @Test("Row identity matches the display item composition")
    func rowIDMatchesDisplayItemComposition() {
        #expect(MessageDeepLink.rowID(contextKey: "dm:peer1", messageID: "m1") == "dm:peer1|m1")
    }

    /// A link can point behind the render window; without growing it the row is
    /// not in the hierarchy and the scroll is a no-op.
    @Test("The window grows just enough to reveal an older message")
    func windowGrowsToRevealTarget() {
        // 100 messages, target at index 10 -> needs the last 90 rendered.
        #expect(MessageDeepLink.windowCount(toReveal: 10, inTotal: 100, current: 50) == 90)
    }

    @Test("An already-visible target never shrinks the window")
    func windowNeverShrinks() {
        #expect(MessageDeepLink.windowCount(toReveal: 95, inTotal: 100, current: 50) == 50)
        #expect(MessageDeepLink.windowCount(toReveal: 99, inTotal: 100, current: 50) == 50)
    }

    @Test("An out-of-range index leaves the window alone")
    func windowIgnoresBadIndex() {
        #expect(MessageDeepLink.windowCount(toReveal: -1, inTotal: 100, current: 50) == 50)
        #expect(MessageDeepLink.windowCount(toReveal: 100, inTotal: 100, current: 50) == 50)
        #expect(MessageDeepLink.windowCount(toReveal: 0, inTotal: 0, current: 50) == 50)
    }
}
