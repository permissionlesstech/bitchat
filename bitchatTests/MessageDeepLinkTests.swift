//
// MessageDeepLinkTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
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
}
